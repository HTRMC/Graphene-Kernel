// Graphene Init Process
// First user-space process, spawns system services

const syscall = @import("syscall");

/// Main entry point for init
export fn main() i32 {
    // Print startup message
    syscall.print("Graphene init started\n");
    syscall.print("Running in user mode!\n");

    // Print version info
    syscall.print("Init process v0.1.0\n");

    // In a full implementation, init would:
    // 1. Mount filesystems
    // 2. Start system services
    // 3. Spawn login/shell

    // For Phase 2, we just demonstrate user mode works
    syscall.print("User space operational.\n");

    // Loop forever (init should never exit)
    while (true) {
        syscall.threadYield();
    }

    return 0;
}
