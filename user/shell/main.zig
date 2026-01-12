// Graphene Shell
// Basic command-line shell demonstrating syscall usage

const syscall = @import("syscall");

/// Simple string buffer for output
fn printNum(num: u32) void {
    var buf: [16]u8 = undefined;
    var n = num;
    var len: usize = 0;

    // Handle zero
    if (n == 0) {
        _ = syscall.debugPrint("0");
        return;
    }

    // Build digits backwards
    while (n > 0 and len < buf.len) : (len += 1) {
        buf[buf.len - 1 - len] = @truncate((n % 10) + '0');
        n /= 10;
    }

    // Print the number
    _ = syscall.debugPrint(buf[buf.len - len ..]);
}

/// Print hex number
fn printHex(num: u64) void {
    const hex_chars = "0123456789ABCDEF";
    var buf: [18]u8 = undefined;
    buf[0] = '0';
    buf[1] = 'x';

    var n = num;
    var i: usize = 17;
    while (i > 1) : (i -= 1) {
        buf[i] = hex_chars[@truncate(n & 0xF)];
        n >>= 4;
    }

    _ = syscall.debugPrint(&buf);
}

/// Demo commands
fn cmdHelp() void {
    syscall.print("Available commands:\n");
    syscall.print("  help   - Show this help\n");
    syscall.print("  info   - Show system info\n");
    syscall.print("  caps   - Show capability info\n");
    syscall.print("  yield  - Yield CPU\n");
}

fn cmdInfo() void {
    syscall.print("Graphene Shell v0.1.0\n");
    syscall.print("Running on x86_64\n");
    syscall.print("Capability-based microkernel\n");
}

fn cmdCaps() void {
    syscall.print("Capability System Active\n");
    syscall.print("Rights: R W X S H G\n");
    syscall.print("Types: memory, thread, process,\n");
    syscall.print("       ipc_endpoint, ipc_channel,\n");
    syscall.print("       irq, ioport, device_mmio\n");
}

/// Shell demo - runs a sequence of demo commands
fn runDemo() void {
    syscall.print("=== Graphene Shell Demo ===\n");
    syscall.print("\n");

    // Show help
    syscall.print("> help\n");
    cmdHelp();
    syscall.print("\n");

    // Show info
    syscall.print("> info\n");
    cmdInfo();
    syscall.print("\n");

    // Show caps
    syscall.print("> caps\n");
    cmdCaps();
    syscall.print("\n");

    // Demonstrate yield
    syscall.print("> yield\n");
    syscall.print("Yielding CPU...\n");
    syscall.threadYield();
    syscall.print("Resumed from yield\n");
    syscall.print("\n");

    syscall.print("Demo complete.\n");
}

/// Main entry point
pub fn main() i32 {
    syscall.print("Graphene Shell starting...\n");
    syscall.print("\n");

    // Run the demo
    runDemo();

    syscall.print("\n");
    syscall.print("Shell entering idle loop.\n");
    syscall.print("(No keyboard input in Phase 2)\n");

    // Idle loop - would normally wait for input
    var idle_count: u32 = 0;
    while (true) {
        syscall.threadYield();
        idle_count += 1;

        // Occasional status update (every ~1000 yields)
        if (idle_count % 1000 == 0) {
            syscall.print(".");
        }

        if (idle_count > 10000) {
            idle_count = 0;
        }
    }

    return 0;
}
