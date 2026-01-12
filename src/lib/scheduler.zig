// Graphene Kernel - Scheduler
// CFS-like single-core scheduler

const thread = @import("thread.zig");
const process = @import("process.zig");
const gdt = @import("gdt.zig");
const pic = @import("pic.zig");
const framebuffer = @import("framebuffer.zig");

/// Scheduler tick rate (Hz)
pub const TICK_RATE: u32 = 1000; // 1ms ticks

/// Time quantum per nice level (in ticks)
const BASE_QUANTUM: u32 = 10; // 10ms base

/// Nice weight table (index = nice + 20, range -20 to +19)
/// Higher nice = lower weight = less CPU time
const nice_weights: [40]u32 = [_]u32{
    88761, 71755, 56483, 46273, 36291, // -20 to -16
    29154, 23254, 18705, 14949, 11916, // -15 to -11
    9548,  7620,  6100,  4904,  3906, // -10 to -6
    3121,  2501,  1991,  1586,  1277, // -5 to -1
    1024,  820,   655,   526,   423, // 0 to 4
    335,   272,   215,   172,   137, // 5 to 9
    110,   87,    70,    56,    45, // 10 to 14
    36,    29,    23,    18,    15, // 15 to 19
};

/// Run queue (sorted by vruntime for CFS)
pub const RunQueue = struct {
    head: ?*thread.Thread = null,
    tail: ?*thread.Thread = null,
    count: u32 = 0,

    /// Minimum vruntime (for new thread baseline)
    min_vruntime: u64 = 0,

    /// Insert thread sorted by vruntime (ascending)
    pub fn insert(self: *RunQueue, t: *thread.Thread) void {
        t.sched_prev = null;
        t.sched_next = null;

        if (self.head == null) {
            self.head = t;
            self.tail = t;
            self.count = 1;
            return;
        }

        // Find insertion point (sorted by vruntime)
        var node = self.head;
        var prev: ?*thread.Thread = null;

        while (node) |curr| {
            if (t.vruntime < curr.vruntime) {
                // Insert before curr
                t.sched_next = curr;
                t.sched_prev = prev;
                curr.sched_prev = t;

                if (prev) |p| {
                    p.sched_next = t;
                } else {
                    self.head = t;
                }

                self.count += 1;
                return;
            }
            prev = curr;
            node = curr.sched_next;
        }

        // Insert at end
        t.sched_prev = self.tail;
        if (self.tail) |tail| {
            tail.sched_next = t;
        }
        self.tail = t;
        self.count += 1;
    }

    /// Remove specific thread
    pub fn remove(self: *RunQueue, t: *thread.Thread) void {
        if (t.sched_prev) |prev| {
            prev.sched_next = t.sched_next;
        } else {
            self.head = t.sched_next;
        }

        if (t.sched_next) |next| {
            next.sched_prev = t.sched_prev;
        } else {
            self.tail = t.sched_prev;
        }

        t.sched_prev = null;
        t.sched_next = null;

        if (self.count > 0) {
            self.count -= 1;
        }

        // Update min_vruntime
        if (self.head) |h| {
            self.min_vruntime = h.vruntime;
        }
    }

    /// Get thread with lowest vruntime
    pub fn pickNext(self: *RunQueue) ?*thread.Thread {
        return self.head;
    }

    /// Dequeue thread with lowest vruntime
    pub fn dequeue(self: *RunQueue) ?*thread.Thread {
        if (self.head) |h| {
            self.remove(h);
            return h;
        }
        return null;
    }

    /// Check if empty
    pub fn isEmpty(self: *const RunQueue) bool {
        return self.head == null;
    }
};

/// Scheduler state
var run_queue: RunQueue = .{};
var current: ?*thread.Thread = null;
var idle_thread: ?*thread.Thread = null;
var tick_count: u64 = 0;
var need_resched: bool = false;
var scheduler_running: bool = false;

/// Initialize scheduler
pub fn init() void {
    // Create idle thread
    idle_thread = thread.createKernel(&idleLoop, 0);
    if (idle_thread) |idle| {
        idle.flags.idle_thread = true;
        idle.vruntime = 0xFFFFFFFFFFFFFFFF; // Max vruntime (never scheduled unless queue empty)
    }

    scheduler_running = false;
}

/// Idle thread loop
fn idleLoop(_: u64) void {
    while (true) {
        asm volatile ("hlt");
    }
}

/// Start scheduler (never returns)
pub fn start() noreturn {
    // Enable timer interrupt
    pic.unmaskIrq(0); // PIT timer is IRQ 0

    scheduler_running = true;

    // Pick first thread
    schedule();

    // Should never reach here
    while (true) {
        asm volatile ("hlt");
    }
}

/// Get nice weight for priority
fn getNiceWeight(priority: i8) u32 {
    const index: usize = @intCast(@as(i32, priority) + 20);
    if (index >= 40) return nice_weights[39];
    return nice_weights[index];
}

/// Add thread to run queue
pub fn enqueue(t: *thread.Thread) void {
    if (t.flags.idle_thread) return; // Never enqueue idle thread

    // Set initial vruntime to min_vruntime (fair start)
    if (t.vruntime == 0) {
        t.vruntime = run_queue.min_vruntime;
    }

    // Reset time slice
    t.time_slice = t.quantum;

    t.state = .ready;
    run_queue.insert(t);
}

/// Remove thread from run queue
pub fn dequeue(t: *thread.Thread) void {
    run_queue.remove(t);
}

/// Timer tick handler (called from IRQ 0)
pub fn tick() void {
    tick_count += 1;

    if (current) |curr| {
        // Update vruntime
        // vruntime += delta * (NICE_0_WEIGHT / weight)
        const weight = getNiceWeight(curr.priority);
        const vruntime_delta = (1024 * 1000000) / weight; // Scaled by 1024 (NICE_0_WEIGHT)
        curr.vruntime +%= vruntime_delta;

        // Decrement time slice
        if (curr.time_slice > 0) {
            curr.time_slice -= 1;
        }

        // Check if need reschedule
        if (curr.time_slice == 0 or curr.flags.needs_resched) {
            need_resched = true;
        }

        // Check if another thread has lower vruntime
        if (run_queue.head) |next| {
            if (next.vruntime < curr.vruntime) {
                need_resched = true;
            }
        }
    } else {
        need_resched = true;
    }
}

/// Schedule (pick next thread)
pub fn schedule() void {
    need_resched = false;

    // Save current thread if any
    if (current) |curr| {
        if (curr.state == .running) {
            curr.state = .ready;
            if (!curr.flags.idle_thread) {
                // Reset time slice
                curr.time_slice = curr.quantum;
                run_queue.insert(curr);
            }
        }
    }

    // Pick next thread
    const next = run_queue.dequeue() orelse idle_thread orelse {
        // No thread to run - halt
        asm volatile ("cli");
        while (true) {
            asm volatile ("hlt");
        }
    };

    if (next == current) {
        // Same thread, no switch needed
        next.state = .running;
        return;
    }

    // Context switch
    const old = current;
    current = next;
    next.state = .running;

    // Update per-CPU data
    thread.setCurrentThread(next);

    // Update TSS kernel stack for user space returns
    gdt.setKernelStack(next.kernel_stack_top);

    // Perform context switch
    if (old) |o| {
        contextSwitch(&o.context, next.context);
    } else {
        // First thread - just load context
        loadContext(next.context);
    }
}

/// Context switch (assembly)
fn contextSwitch(old_ctx: **thread.ThreadContext, new_ctx: *thread.ThreadContext) void {
    asm volatile (
    // Save callee-saved registers
        \\push %%rbx
        \\push %%rbp
        \\push %%r12
        \\push %%r13
        \\push %%r14
        \\push %%r15
        // Save current RSP to old context
        \\mov %%rsp, (%[old])
        // Load new RSP from new context
        \\mov %[new], %%rsp
        // Restore callee-saved registers
        \\pop %%r15
        \\pop %%r14
        \\pop %%r13
        \\pop %%r12
        \\pop %%rbp
        \\pop %%rbx
        // Return (pops RIP from stack)
        \\ret
        :
        : [old] "r" (old_ctx),
          [new] "r" (new_ctx),
        : "~{memory}"
    );
}

/// Load context (for first thread)
fn loadContext(ctx: *thread.ThreadContext) noreturn {
    asm volatile (
        \\mov %[ctx], %%rsp
        \\pop %%r15
        \\pop %%r14
        \\pop %%r13
        \\pop %%r12
        \\pop %%rbp
        \\pop %%rbx
        \\ret
        :
        : [ctx] "r" (ctx),
    );
    unreachable;
}

/// Yield current time slice
pub fn yield() void {
    if (current) |curr| {
        curr.flags.needs_resched = true;
        curr.time_slice = 0;
    }
    // Actual switch happens on next tick or explicit schedule() call

    // In a preemptive kernel with software interrupts, we'd trigger schedule here
    // For Phase 1, just set the flag
    if (scheduler_running) {
        schedule();
    }
}

/// Block current thread
pub fn blockCurrent(queue: *thread.WaitQueue) void {
    if (current) |curr| {
        curr.state = .blocked;
        queue.enqueue(curr);
        schedule();
    }
}

/// Wake thread (add to run queue)
pub fn wake(t: *thread.Thread) void {
    if (t.state == .blocked) {
        t.state = .ready;
        enqueue(t);

        // Check if should preempt current
        if (current) |curr| {
            if (t.vruntime < curr.vruntime) {
                need_resched = true;
            }
        }
    }
}

/// Get current thread
pub fn getCurrent() ?*thread.Thread {
    return current;
}

/// Check if scheduler needs to run
pub fn needsReschedule() bool {
    return need_resched;
}

/// Get tick count
pub fn getTicks() u64 {
    return tick_count;
}

/// Get run queue length
pub fn getRunQueueLength() u32 {
    return run_queue.count;
}

/// Check if scheduler is running
pub fn isRunning() bool {
    return scheduler_running;
}

/// Set thread priority (nice value)
pub fn setPriority(t: *thread.Thread, priority: i8) void {
    // Clamp to valid range
    var p = priority;
    if (p < -20) p = -20;
    if (p > 19) p = 19;

    t.priority = p;

    // Adjust quantum based on priority
    // Higher priority = longer quantum
    const weight = getNiceWeight(p);
    t.quantum = @truncate((BASE_QUANTUM * weight) / 1024);
    if (t.quantum < 1) t.quantum = 1;
}
