// Graphene Kernel - Thread Management
// Thread Control Block and thread operations

const object = @import("object.zig");
const pmm = @import("pmm.zig");
const gdt = @import("gdt.zig");
const usermode = @import("usermode.zig");
const vmm = @import("vmm.zig");

/// Thread states
pub const ThreadState = enum(u8) {
    ready, // Ready to run
    running, // Currently executing
    blocked, // Waiting for something (IPC, timer, etc.)
    zombie, // Terminated, waiting for cleanup
};

/// Thread context saved/restored on context switch
/// Only callee-saved registers need to be saved
pub const ThreadContext = extern struct {
    // Callee-saved registers (System V AMD64 ABI)
    r15: u64 = 0,
    r14: u64 = 0,
    r13: u64 = 0,
    r12: u64 = 0,
    rbp: u64 = 0,
    rbx: u64 = 0,
    // Return address (set to entry point for new threads)
    rip: u64 = 0,
};

/// Kernel stack size (16KB)
pub const KERNEL_STACK_SIZE: u64 = 16 * 1024;

/// Thread Control Block
pub const Thread = struct {
    /// Object header for capability system
    base: object.Object = object.Object.init(.thread),

    /// Thread ID (unique across all threads)
    tid: u32 = 0,

    /// Current state
    state: ThreadState = .ready,

    /// Owning process (set during initialization)
    process: ?*anyopaque = null, // *Process, forward reference

    /// Saved context (stack pointer when not running)
    /// Points to top of saved context on kernel stack
    context: *ThreadContext = undefined,

    /// Kernel stack base (low address)
    kernel_stack: u64 = 0,

    /// Kernel stack top (high address, initial RSP)
    kernel_stack_top: u64 = 0,

    /// User stack (if user thread)
    user_stack: u64 = 0,

    // ========================================
    // Scheduler fields
    // ========================================

    /// Virtual runtime for CFS (nanoseconds * weight)
    vruntime: u64 = 0,

    /// Nice value (-20 to +19, 0 = default)
    priority: i8 = 0,

    /// Remaining time slice in ticks
    time_slice: u32 = 0,

    /// Time slice quantum (reset value)
    quantum: u32 = DEFAULT_QUANTUM,

    // ========================================
    // Queue links (intrusive linked list)
    // ========================================

    /// Next in scheduler run queue
    sched_next: ?*Thread = null,

    /// Previous in scheduler run queue
    sched_prev: ?*Thread = null,

    /// Next in wait queue (for blocking operations)
    wait_next: ?*Thread = null,

    // ========================================
    // Thread flags
    // ========================================

    flags: ThreadFlags = .{},

    /// Entry point (for new threads)
    entry: u64 = 0,

    /// Entry argument
    arg: u64 = 0,
};

/// Default time slice quantum (ticks)
pub const DEFAULT_QUANTUM: u32 = 10;

/// Thread flags
pub const ThreadFlags = packed struct(u8) {
    kernel_thread: bool = false, // Running in kernel mode only
    idle_thread: bool = false, // Idle thread (never in run queue)
    needs_resched: bool = false, // Should yield at next opportunity
    in_syscall: bool = false, // Currently executing syscall
    _reserved: u4 = 0,
};

/// Wait queue for blocking operations
pub const WaitQueue = struct {
    head: ?*Thread = null,
    tail: ?*Thread = null,
    count: u32 = 0,

    /// Add thread to wait queue
    pub fn enqueue(self: *WaitQueue, thread: *Thread) void {
        thread.wait_next = null;

        if (self.tail) |t| {
            t.wait_next = thread;
        } else {
            self.head = thread;
        }
        self.tail = thread;
        self.count += 1;
    }

    /// Remove and return first thread from queue
    pub fn dequeue(self: *WaitQueue) ?*Thread {
        if (self.head) |h| {
            self.head = h.wait_next;
            if (self.head == null) {
                self.tail = null;
            }
            self.count -= 1;
            h.wait_next = null;
            return h;
        }
        return null;
    }

    /// Check if queue is empty
    pub fn isEmpty(self: *const WaitQueue) bool {
        return self.head == null;
    }

    /// Remove specific thread from queue
    pub fn remove(self: *WaitQueue, thread: *Thread) bool {
        var prev: ?*Thread = null;
        var current = self.head;

        while (current) |curr| {
            if (curr == thread) {
                if (prev) |p| {
                    p.wait_next = curr.wait_next;
                } else {
                    self.head = curr.wait_next;
                }

                if (self.tail == curr) {
                    self.tail = prev;
                }

                curr.wait_next = null;
                self.count -= 1;
                return true;
            }
            prev = curr;
            current = curr.wait_next;
        }
        return false;
    }
};

/// Thread pool for Phase 1 (fixed allocation)
const MAX_THREADS: usize = 256;
var thread_pool: [MAX_THREADS]Thread = undefined;
var thread_used: [MAX_THREADS]bool = [_]bool{false} ** MAX_THREADS;
var next_tid: u32 = 1;

/// Allocate a new thread
pub fn allocThread() ?*Thread {
    for (&thread_used, 0..) |*used, i| {
        if (!used.*) {
            used.* = true;
            thread_pool[i] = Thread{};
            thread_pool[i].tid = next_tid;
            next_tid += 1;
            return &thread_pool[i];
        }
    }
    return null;
}

/// Free a thread
pub fn freeThread(thread: *Thread) void {
    // Free kernel stack
    if (thread.kernel_stack != 0) {
        const pages = KERNEL_STACK_SIZE / pmm.PAGE_SIZE;
        pmm.freeFrames(pmm.virtToPhys(thread.kernel_stack), pages);
    }

    // Return to pool
    const index = (@intFromPtr(thread) - @intFromPtr(&thread_pool)) / @sizeOf(Thread);
    if (index < MAX_THREADS) {
        thread_used[index] = false;
    }
}

/// Create a kernel thread
pub fn createKernel(entry_fn: *const fn (u64) void, arg: u64) ?*Thread {
    const thread = allocThread() orelse return null;

    // Allocate kernel stack
    const stack_pages = KERNEL_STACK_SIZE / pmm.PAGE_SIZE;
    const stack_phys = pmm.allocFrames(stack_pages) orelse {
        freeThread(thread);
        return null;
    };

    const stack_virt = pmm.physToVirt(stack_phys);
    thread.kernel_stack = stack_virt;
    thread.kernel_stack_top = stack_virt + KERNEL_STACK_SIZE;

    // Set up initial context on stack
    // Stack grows down, so context is at top minus context size
    const context_addr = thread.kernel_stack_top - @sizeOf(ThreadContext);
    thread.context = @ptrFromInt(context_addr);

    // Initialize context
    thread.context.* = ThreadContext{
        .rip = @intFromPtr(&threadEntryTrampoline),
        .rbp = 0,
    };

    // Store entry point and arg for trampoline
    thread.entry = @intFromPtr(entry_fn);
    thread.arg = arg;

    thread.flags.kernel_thread = true;
    thread.state = .ready;

    return thread;
}

/// Thread entry trampoline
/// Sets up argument and calls actual entry function
fn threadEntryTrampoline() callconv(.c) noreturn {
    // Get current thread (will be implemented with per-CPU data)
    // For now, this is a placeholder
    const thread = getCurrentThreadUnsafe();

    if (thread) |t| {
        // Call the actual entry function
        const entry: *const fn (u64) void = @ptrFromInt(t.entry);
        entry(t.arg);
    }

    // Thread returned - exit
    exitCurrent(0);
}

/// Exit current thread
pub fn exitCurrent(code: i32) noreturn {
    _ = code;

    // Mark thread as zombie
    if (getCurrentThreadUnsafe()) |t| {
        t.state = .zombie;
    }

    // Yield to scheduler (will never return to this thread)
    // For Phase 1, just halt
    asm volatile ("cli");
    while (true) {
        asm volatile ("hlt");
    }
}

/// Get current thread (unsafe - no per-CPU data yet)
/// This will be properly implemented with per-CPU data
var current_thread: ?*Thread = null;

pub fn getCurrentThreadUnsafe() ?*Thread {
    return current_thread;
}

pub fn setCurrentThread(thread: ?*Thread) void {
    current_thread = thread;
}

/// Yield current thread
pub fn yield() void {
    if (current_thread) |t| {
        t.flags.needs_resched = true;
    }
    // Scheduler will handle the actual switch
}

/// Block current thread on wait queue
pub fn blockOn(queue: *WaitQueue) void {
    if (current_thread) |t| {
        t.state = .blocked;
        queue.enqueue(t);
        // Trigger reschedule
        t.flags.needs_resched = true;
    }
}

/// Wake thread from wait queue
pub fn wake(thread: *Thread) void {
    thread.state = .ready;
    // Scheduler will add to run queue
}

/// Get thread by TID
pub fn getByTid(tid: u32) ?*Thread {
    for (&thread_pool, thread_used) |*thread, used| {
        if (used and thread.tid == tid) {
            return thread;
        }
    }
    return null;
}

/// Count active threads
pub fn countActive() u32 {
    var count: u32 = 0;
    for (thread_used) |used| {
        if (used) count += 1;
    }
    return count;
}

/// Create a user thread
/// process: The owning process (must have address space set up)
/// entry: User-space entry point
/// user_stack: User-space stack pointer
pub fn createUser(process: *anyopaque, entry: u64, user_stack: u64) ?*Thread {
    const t = allocThread() orelse return null;

    // Allocate kernel stack (for syscall handling)
    const stack_pages = KERNEL_STACK_SIZE / pmm.PAGE_SIZE;
    const stack_phys = pmm.allocFrames(stack_pages) orelse {
        freeThread(t);
        return null;
    };

    const stack_virt = pmm.physToVirt(stack_phys);
    t.kernel_stack = stack_virt;
    t.kernel_stack_top = stack_virt + KERNEL_STACK_SIZE;

    // Set up initial context on kernel stack
    const context_addr = t.kernel_stack_top - @sizeOf(ThreadContext);
    t.context = @ptrFromInt(context_addr);

    // Initialize context - entry point is the user thread trampoline
    t.context.* = ThreadContext{
        .rip = @intFromPtr(&userThreadEntry),
        .rbp = 0,
    };

    // Store user entry point and stack for the trampoline
    t.entry = entry;
    t.user_stack = user_stack;
    t.process = process;

    // User thread flags
    t.flags.kernel_thread = false;
    t.state = .ready;

    return t;
}

/// User thread entry point (runs in kernel mode, switches to user mode)
fn userThreadEntry() callconv(.c) noreturn {
    const t = getCurrentThreadUnsafe() orelse {
        // No thread - halt
        asm volatile ("cli");
        while (true) {
            asm volatile ("hlt");
        }
    };

    // Switch to process address space
    // Get the process and switch to its address space
    const proc_ptr = t.process orelse {
        asm volatile ("cli");
        while (true) {
            asm volatile ("hlt");
        }
    };

    // Access process address space (Process type defined elsewhere)
    // For now, we assume the address space is already active or we use a simpler approach
    const proc = @as(*const struct {
        base: object.Object,
        pid: u32,
        name: [32]u8,
        address_space: ?*vmm.AddressSpace,
    }, @ptrCast(@alignCast(proc_ptr)));

    if (proc.address_space) |space| {
        // Switch to process address space
        vmm.switchAddressSpace(space);
    }

    // Set TSS kernel stack for returns from user mode
    gdt.setKernelStack(t.kernel_stack_top);

    // Jump to user mode
    usermode.jumpToUser(t.entry, t.user_stack, 0);
}
