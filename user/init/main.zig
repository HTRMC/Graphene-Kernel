// Graphene Init Process
// First user-space process, spawns system services

const syscall = @import("syscall");

/// Main entry point for init
pub fn main() i32 {
    // Print startup message
    syscall.klogStr("Graphene init started\n");
    syscall.klogStr("Running in user mode!\n");

    // Print version info
    syscall.klogStr("Init process v0.1.0\n"); // TODO: make sure this text doesnt overlap. the text [Ok] Loaded: init

    // In a full implementation, init would:
    // 1. Mount filesystems
    // 2. Start system services
    // 3. Spawn login/shell

    // For Phase 2, we just demonstrate user mode works
    syscall.klogStr("User space operational.\n");

    // Loop forever (init should never exit)
    while (true) {
        syscall.threadYield();
    }

    return 0;
}
