// Graphene Kernel - Process Management
// Process Control Block and process operations

const object = @import("object.zig");
const capability = @import("capability.zig");
const vmm = @import("vmm.zig");
const thread = @import("thread.zig");

/// Maximum threads per process
const MAX_THREADS_PER_PROCESS: usize = 64;

/// Process Control Block
pub const Process = struct {
    /// Object header for capability system
    base: object.Object = object.Object.init(.process),

    /// Process ID (unique)
    pid: u32 = 0,

    /// Process name (for debugging)
    name: [32]u8 = [_]u8{0} ** 32,

    /// Address space
    address_space: ?*vmm.AddressSpace = null,

    /// Capability table
    cap_table: ?*capability.CapTable = null,

    /// Thread list
    threads: [MAX_THREADS_PER_PROCESS]?*thread.Thread = [_]?*thread.Thread{null} ** MAX_THREADS_PER_PROCESS,
    thread_count: u32 = 0,

    /// Parent process
    parent: ?*Process = null,

    /// Children list (simple for Phase 1)
    children: [16]?*Process = [_]?*Process{null} ** 16,
    child_count: u32 = 0,

    /// Process state
    state: ProcessState = .running,

    /// Exit code
    exit_code: i32 = 0,

    /// Process flags
    flags: ProcessFlags = .{},

    /// Add thread to process
    pub fn addThread(self: *Process, t: *thread.Thread) bool {
        for (&self.threads) |*slot| {
            if (slot.* == null) {
                slot.* = t;
                t.process = self;
                self.thread_count += 1;
                return true;
            }
        }
        return false;
    }

    /// Remove thread from process
    pub fn removeThread(self: *Process, t: *thread.Thread) void {
        for (&self.threads) |*slot| {
            if (slot.* == t) {
                slot.* = null;
                if (self.thread_count > 0) {
                    self.thread_count -= 1;
                }
                return;
            }
        }
    }

    /// Set process name
    pub fn setName(self: *Process, name: []const u8) void {
        const len = @min(name.len, self.name.len - 1);
        for (0..len) |i| {
            self.name[i] = name[i];
        }
        self.name[len] = 0;
    }

    /// Get process name as slice
    pub fn getName(self: *const Process) []const u8 {
        var len: usize = 0;
        while (len < self.name.len and self.name[len] != 0) {
            len += 1;
        }
        return self.name[0..len];
    }
};

/// Process states
pub const ProcessState = enum(u8) {
    running, // Has at least one runnable thread
    stopped, // Stopped (e.g., by signal)
    zombie, // Terminated, waiting for parent to collect
};

/// Process flags
pub const ProcessFlags = packed struct(u8) {
    kernel_process: bool = false, // Kernel-only process
    init_process: bool = false, // Init (PID 1)
    driver_process: bool = false, // User-space driver
    _reserved: u5 = 0,
};

/// Process pool for Phase 1
const MAX_PROCESSES: usize = 64;
var process_pool: [MAX_PROCESSES]Process = undefined;
var process_used: [MAX_PROCESSES]bool = [_]bool{false} ** MAX_PROCESSES;
var next_pid: u32 = 1;

/// Kernel process (PID 0)
var kernel_process: Process = undefined;
var kernel_process_initialized: bool = false;

/// Initialize process subsystem
pub fn init() void {
    // Initialize kernel process
    kernel_process = Process{};
    kernel_process.pid = 0;
    kernel_process.setName("kernel");
    kernel_process.flags.kernel_process = true;

    // Use kernel address space
    kernel_process.address_space = vmm.getKernelSpace();

    // Create kernel capability table
    kernel_process.cap_table = capability.createTable();

    kernel_process_initialized = true;
}

/// Get kernel process
pub fn getKernelProcess() *Process {
    return &kernel_process;
}

/// Allocate a new process
fn allocProcess() ?*Process {
    for (&process_used, 0..) |*used, i| {
        if (!used.*) {
            used.* = true;
            process_pool[i] = Process{};
            process_pool[i].pid = next_pid;
            next_pid += 1;
            return &process_pool[i];
        }
    }
    return null;
}

/// Free a process
fn freeProcess(proc: *Process) void {
    const index = (@intFromPtr(proc) - @intFromPtr(&process_pool)) / @sizeOf(Process);
    if (index < MAX_PROCESSES) {
        process_used[index] = false;
    }
}

/// Create a new process
pub fn create(parent: ?*Process) ?*Process {
    const proc = allocProcess() orelse return null;

    // Create address space
    proc.address_space = vmm.createAddressSpace() catch {
        freeProcess(proc);
        return null;
    };

    // Create capability table
    proc.cap_table = capability.createTable() orelse {
        if (proc.address_space) |space| {
            vmm.destroyAddressSpace(space);
        }
        freeProcess(proc);
        return null;
    };

    // Set parent
    proc.parent = parent orelse &kernel_process;

    // Add to parent's children
    if (proc.parent) |p| {
        for (&p.children) |*slot| {
            if (slot.* == null) {
                slot.* = proc;
                p.child_count += 1;
                break;
            }
        }
    }

    return proc;
}

/// Destroy a process
pub fn destroy(proc: *Process) void {
    // Can't destroy kernel process
    if (proc.pid == 0) return;

    // Terminate all threads
    for (proc.threads) |maybe_thread| {
        if (maybe_thread) |t| {
            t.state = .zombie;
            // In full implementation, would clean up thread properly
        }
    }

    // Remove from parent's children
    if (proc.parent) |parent| {
        for (&parent.children) |*slot| {
            if (slot.* == proc) {
                slot.* = null;
                if (parent.child_count > 0) {
                    parent.child_count -= 1;
                }
                break;
            }
        }
    }

    // Reparent children to init (or kernel)
    for (proc.children) |maybe_child| {
        if (maybe_child) |child| {
            child.parent = &kernel_process;
        }
    }

    // Destroy capability table
    if (proc.cap_table) |cap_tab| {
        capability.destroyTable(cap_tab);
    }

    // Destroy address space
    if (proc.address_space) |space| {
        vmm.destroyAddressSpace(space);
    }

    // Free process
    freeProcess(proc);
}

/// Exit current process
pub fn exitCurrent(code: i32) noreturn {
    if (getCurrentProcess()) |proc| {
        proc.exit_code = code;
        proc.state = .zombie;

        // Mark all threads as zombie
        for (proc.threads) |maybe_thread| {
            if (maybe_thread) |t| {
                t.state = .zombie;
            }
        }
    }

    // Halt (scheduler would handle this properly)
    asm volatile ("cli");
    while (true) {
        asm volatile ("hlt");
    }
}

/// Get current process (from current thread)
var current_process: ?*Process = null;

pub fn getCurrentProcess() ?*Process {
    if (thread.getCurrentThreadUnsafe()) |t| {
        if (t.process) |p| {
            return @ptrCast(@alignCast(p));
        }
    }
    return current_process;
}

pub fn setCurrentProcess(proc: ?*Process) void {
    current_process = proc;
}

/// Get process by PID
pub fn getByPid(pid: u32) ?*Process {
    if (pid == 0) return &kernel_process;

    for (&process_pool, process_used) |*proc, used| {
        if (used and proc.pid == pid) {
            return proc;
        }
    }
    return null;
}

/// Count active processes
pub fn countActive() u32 {
    var count: u32 = 1; // Kernel process
    for (process_used) |used| {
        if (used) count += 1;
    }
    return count;
}

/// Get list of active processes
/// Fills buffer with process pointers, returns count written
/// Includes kernel process (PID 0) first
pub fn getActiveList(buf: []*Process, max: usize) usize {
    var count: usize = 0;

    // First add kernel process
    if (count < max and kernel_process_initialized) {
        buf[count] = &kernel_process;
        count += 1;
    }

    // Then add user processes
    for (&process_pool, process_used) |*proc, used| {
        if (used and count < max) {
            buf[count] = proc;
            count += 1;
        }
    }

    return count;
}

/// Check if process subsystem is initialized
pub fn isInitialized() bool {
    return kernel_process_initialized;
}
