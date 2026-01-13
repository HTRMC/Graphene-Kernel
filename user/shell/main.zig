// Graphene Shell
// Interactive command-line shell

const syscall = @import("syscall");

/// Command buffer
const MAX_CMD_LEN: usize = 128;
var cmd_buffer: [MAX_CMD_LEN]u8 = undefined;
var cmd_len: usize = 0;

/// Shell prompt
fn printPrompt() void {
    syscall.print("\ngraphene> ");
}

/// Compare two strings
fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (ac != bc) return false;
    }
    return true;
}

/// Check if string starts with prefix
fn startsWith(str: []const u8, prefix: []const u8) bool {
    if (str.len < prefix.len) return false;
    for (prefix, 0..) |c, i| {
        if (str[i] != c) return false;
    }
    return true;
}

/// Print a number
fn printNum(num: u32) void {
    var buf: [16]u8 = undefined;
    var n = num;
    var len: usize = 0;

    if (n == 0) {
        syscall.print("0");
        return;
    }

    while (n > 0 and len < buf.len) : (len += 1) {
        buf[buf.len - 1 - len] = @truncate((n % 10) + '0');
        n /= 10;
    }

    _ = syscall.debugPrint(buf[buf.len - len ..]);
}

// ============================================================================
// Commands
// ============================================================================

fn cmdHelp() void {
    syscall.print("Available commands:\n");
    syscall.print("  help     - Show this help message\n");
    syscall.print("  clear    - Clear the screen\n");
    syscall.print("  info     - Show system information\n");
    syscall.print("  echo     - Echo text back\n");
    syscall.print("  yield    - Yield CPU time slice\n");
    syscall.print("  caps     - Show capability types\n");
    syscall.print("  ipc-test - Test IPC functionality\n");
    syscall.print("  ps       - List running processes\n");
}

fn cmdClear() void {
    // Clear by printing many newlines (simple approach)
    var i: u32 = 0;
    while (i < 30) : (i += 1) {
        syscall.print("\n");
    }
}

fn cmdInfo() void {
    syscall.print("Graphene Kernel v0.1.0\n");
    syscall.print("Architecture: x86_64\n");
    syscall.print("Type: Hybrid Microkernel\n");
    syscall.print("Security: Capability-based\n");
}

fn cmdEcho(args: []const u8) void {
    if (args.len > 0) {
        _ = syscall.debugPrint(args);
    }
    syscall.print("\n");
}

fn cmdYield() void {
    syscall.print("Yielding CPU...\n");
    syscall.threadYield();
    syscall.print("Resumed.\n");
}

fn cmdCaps() void {
    syscall.print("Capability Types:\n");
    syscall.print("  memory      - Physical memory regions\n");
    syscall.print("  thread      - Thread control\n");
    syscall.print("  process     - Process control\n");
    syscall.print("  ipc_endpoint- IPC endpoints\n");
    syscall.print("  ipc_channel - IPC channels\n");
    syscall.print("  irq         - Hardware interrupts\n");
    syscall.print("  ioport      - I/O port access\n");
}

fn cmdIpcTest() void {
    syscall.print("=== IPC Test ===\n");

    // Test 1: Create an endpoint
    syscall.print("Creating endpoint... ");
    const ep_result = syscall.endpointCreate();
    if (ep_result < 0) {
        syscall.print("FAILED (error ");
        printSignedNum(ep_result);
        syscall.print(")\n");
        return;
    }
    syscall.print("OK (slot ");
    printNum(@intCast(@as(u64, @bitCast(ep_result))));
    syscall.print(")\n");

    // Test 2: Create a channel (bidirectional)
    syscall.print("Creating channel... ");
    var slot0: u32 = 0;
    var slot1: u32 = 0;
    const ch_result = syscall.channelCreate(&slot0, &slot1);
    if (ch_result < 0) {
        syscall.print("FAILED (error ");
        printSignedNum(ch_result);
        syscall.print(")\n");
        return;
    }
    syscall.print("OK (slots ");
    printNum(slot0);
    syscall.print(", ");
    printNum(slot1);
    syscall.print(")\n");

    syscall.print("\nIPC subsystem working!\n");
    syscall.print("Note: Full send/recv test requires async mode\n");
    syscall.print("or multiple processes.\n");
}

fn cmdPs() void {
    syscall.print("PID   STATE    THREADS  NAME\n");
    syscall.print("----  -------  -------  ----------------\n");

    // Get process count
    const count_result = syscall.processCount();
    if (count_result < 0) {
        syscall.print("Error getting process count\n");
        return;
    }

    // Allocate buffer on stack (max 16 processes)
    var entries: [16]syscall.ProcessInfoEntry = undefined;
    const max_entries: usize = @min(@as(usize, @intCast(@as(u64, @bitCast(count_result)))), 16);

    const list_result = syscall.processList(&entries, max_entries);
    if (list_result < 0) {
        syscall.print("Error getting process list\n");
        return;
    }

    const actual_count: usize = @intCast(@as(u64, @bitCast(list_result)));

    for (0..actual_count) |i| {
        const entry = entries[i];

        // Print PID (right-padded)
        printNumPadded(entry.pid, 4);
        syscall.print("  ");

        // Print state
        switch (entry.state) {
            0 => syscall.print("running"),
            1 => syscall.print("stopped"),
            2 => syscall.print("zombie "),
            else => syscall.print("unknown"),
        }
        syscall.print("  ");

        // Print thread count
        printNumPadded(entry.thread_count, 7);
        syscall.print("  ");

        // Print name (null-terminated)
        printProcessName(&entry.name);
        syscall.print("\n");
    }
}

/// Print a number with padding
fn printNumPadded(num: u32, width: usize) void {
    var buf: [16]u8 = undefined;
    var n = num;
    var len: usize = 0;

    if (n == 0) {
        // Print padding spaces
        for (0..width - 1) |_| {
            syscall.print(" ");
        }
        syscall.print("0");
        return;
    }

    while (n > 0 and len < buf.len) : (len += 1) {
        buf[buf.len - 1 - len] = @truncate((n % 10) + '0');
        n /= 10;
    }

    // Print padding spaces
    if (len < width) {
        for (0..width - len) |_| {
            syscall.print(" ");
        }
    }

    _ = syscall.debugPrint(buf[buf.len - len ..]);
}

/// Print process name (null-terminated from fixed array)
fn printProcessName(name: *const [32]u8) void {
    var len: usize = 0;
    while (len < 32 and name[len] != 0) : (len += 1) {}
    if (len > 0) {
        _ = syscall.debugPrint(name[0..len]);
    }
}

/// Print a signed number
fn printSignedNum(num: i64) void {
    if (num < 0) {
        syscall.print("-");
        printNum(@intCast(@as(u64, @bitCast(-num))));
    } else {
        printNum(@intCast(@as(u64, @bitCast(num))));
    }
}

fn cmdUnknown(cmd: []const u8) void {
    syscall.print("Unknown command: ");
    _ = syscall.debugPrint(cmd);
    syscall.print("\nType 'help' for available commands.\n");
}

/// Execute a command
fn executeCommand(cmd: []const u8) void {
    // Skip empty commands
    if (cmd.len == 0) return;

    // Trim leading spaces
    var start: usize = 0;
    while (start < cmd.len and cmd[start] == ' ') : (start += 1) {}
    const trimmed = cmd[start..];
    if (trimmed.len == 0) return;

    // Parse command and arguments
    var cmd_end: usize = 0;
    while (cmd_end < trimmed.len and trimmed[cmd_end] != ' ') : (cmd_end += 1) {}
    const command = trimmed[0..cmd_end];

    // Get arguments (skip space after command)
    var args_start = cmd_end;
    while (args_start < trimmed.len and trimmed[args_start] == ' ') : (args_start += 1) {}
    const args = trimmed[args_start..];

    // Dispatch command
    if (strEql(command, "help")) {
        cmdHelp();
    } else if (strEql(command, "clear")) {
        cmdClear();
    } else if (strEql(command, "info")) {
        cmdInfo();
    } else if (strEql(command, "echo")) {
        cmdEcho(args);
    } else if (strEql(command, "yield")) {
        cmdYield();
    } else if (strEql(command, "caps")) {
        cmdCaps();
    } else if (strEql(command, "ipc-test")) {
        cmdIpcTest();
    } else if (strEql(command, "ps")) {
        cmdPs();
    } else {
        cmdUnknown(command);
    }
}

/// Read a line of input
fn readLine() []const u8 {
    cmd_len = 0;

    while (true) {
        const result = syscall.getchar();
        if (result < 0) {
            // Error - return what we have
            break;
        }

        const c: u8 = @truncate(@as(u64, @bitCast(result)));

        if (c == '\n') {
            // Enter pressed - return command
            break;
        } else if (c == 8) {
            // Backspace
            if (cmd_len > 0) {
                cmd_len -= 1;
            }
        } else if (c >= 32 and c < 127) {
            // Printable character
            if (cmd_len < MAX_CMD_LEN - 1) {
                cmd_buffer[cmd_len] = c;
                cmd_len += 1;
            }
        }
    }

    return cmd_buffer[0..cmd_len];
}

/// Main entry point
pub fn main() i32 {
    syscall.print("Graphene Shell v0.1.0\n");
    syscall.print("Type 'help' for available commands.\n");

    // Main shell loop
    while (true) {
        printPrompt();
        const cmd = readLine();
        syscall.print("\n"); // Echo newline after Enter
        executeCommand(cmd);
    }

    return 0;
}
