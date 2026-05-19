// Graphene Shell
// Interactive command-line shell

const syscall = @import("syscall");
const vfs = @import("vfs");
const logsvc = @import("log");

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

const DEV_PREFIX = "/dev/";
const DEV_ROOT = "/dev";

/// Route a path to (capability slot, server-relative name).
/// `/dev/foo` -> (devfs, "foo"); everything else -> (ramfs, path as-is).
fn routePath(path: []const u8) struct { slot: u32, name: []const u8 } {
    if (startsWith(path, DEV_PREFIX)) {
        return .{ .slot = vfs.DEVFS_CAP_SLOT, .name = path[DEV_PREFIX.len..] };
    }
    return .{ .slot = vfs.VFS_CAP_SLOT, .name = path };
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
    syscall.print("  sysinfo  - Show comprehensive system status\n");
    syscall.print("  echo     - Echo text back\n");
    syscall.print("  yield    - Yield CPU time slice\n");
    syscall.print("  caps     - Show capability types\n");
    syscall.print("  ipc-test - Test IPC functionality\n");
    syscall.print("  ps       - List running processes\n");
    syscall.print("  mem      - Show memory statistics\n");
    syscall.print("  uptime   - Show system uptime\n");
    syscall.print("  ls       - List files (ls [/dev])\n");
    syscall.print("  cat      - Print file contents\n");
    syscall.print("  stat     - Show file metadata\n");
    syscall.print("  touch    - Create empty file\n");
    syscall.print("  write    - Write text to file\n");
    syscall.print("  rm       - Delete file\n");
    syscall.print("  mount    - List active filesystems\n");
}

// ============================================================================
// VFS commands
// ============================================================================

fn printFsError(err: vfs.FsError) void {
    switch (err) {
        .success => syscall.print("success"),
        .not_found => syscall.print("not found"),
        .exists => syscall.print("already exists"),
        .no_space => syscall.print("no space"),
        .invalid_arg => syscall.print("invalid argument"),
        .is_directory => syscall.print("is a directory"),
        .not_directory => syscall.print("not a directory"),
        .not_empty => syscall.print("not empty"),
        .io_error => syscall.print("io error"),
        .permission => syscall.print("permission denied"),
    }
}

fn cmdLs(args: []const u8) void {
    // Default to ramfs root; `/dev` or `/dev/` routes to devfs root.
    var slot: u32 = vfs.VFS_CAP_SLOT;
    if (args.len > 0) {
        if (strEql(args, DEV_ROOT) or strEql(args, DEV_PREFIX)) {
            slot = vfs.DEVFS_CAP_SLOT;
        } else if (startsWith(args, DEV_PREFIX)) {
            // Subdirs of /dev not supported (flat devfs).
            slot = vfs.DEVFS_CAP_SLOT;
        }
    }

    var reply_buf: [vfs.MAX_MSG_DATA]u8 = undefined;
    const result = vfs.callSlot(slot, .readdir, "", 0, 0, &.{}, &reply_buf);
    const count = vfs.readdirCount(&reply_buf);
    if (count < 0) {
        syscall.print("ls: ");
        printFsError(result.err);
        syscall.print("\n");
        return;
    }

    var pos: usize = 0;
    var n: i32 = 0;
    while (n < count and pos + 2 <= result.payload.len) : (n += 1) {
        const name_len: usize = result.payload[pos];
        const ftype = result.payload[pos + 1];
        if (pos + 2 + name_len > result.payload.len) break;
        const name = result.payload[pos + 2 ..][0..name_len];
        if (ftype == @intFromEnum(vfs.FileType.directory)) syscall.print("d ") else syscall.print("- ");
        _ = syscall.debugPrint(name);
        syscall.print("\n");
        pos += 2 + name_len;
    }
}

fn cmdCat(args: []const u8) void {
    if (args.len == 0) {
        syscall.print("usage: cat <file>\n");
        return;
    }
    const route = routePath(args);
    var reply_buf: [vfs.MAX_MSG_DATA]u8 = undefined;
    var offset: u32 = 0;
    // Cap total bytes to avoid runaway reads from infinite sources like /dev/zero.
    const MAX_TOTAL: u32 = 4096;
    while (offset < MAX_TOTAL) {
        const max_chunk: u32 = @intCast(reply_buf.len - @sizeOf(vfs.ResponseHeader));
        const result = vfs.callSlot(route.slot, .read, route.name, offset, max_chunk, &.{}, &reply_buf);
        if (result.err != .success) {
            syscall.print("cat: ");
            printFsError(result.err);
            syscall.print("\n");
            return;
        }
        if (result.payload.len == 0) break;
        _ = syscall.debugPrint(result.payload);
        offset += @intCast(result.payload.len);
        if (result.payload.len < max_chunk) break;
    }
}

fn cmdStat(args: []const u8) void {
    if (args.len == 0) {
        syscall.print("usage: stat <file>\n");
        return;
    }
    const route = routePath(args);
    var reply_buf: [vfs.MAX_MSG_DATA]u8 = undefined;
    const result = vfs.callSlot(route.slot, .stat, route.name, 0, 0, &.{}, &reply_buf);
    if (result.err != .success) {
        syscall.print("stat: ");
        printFsError(result.err);
        syscall.print("\n");
        return;
    }
    if (result.payload.len < @sizeOf(vfs.FileStat)) {
        syscall.print("stat: short reply\n");
        return;
    }
    const st: *const vfs.FileStat = @ptrCast(@alignCast(result.payload.ptr));
    syscall.print("  type: ");
    if (st.file_type == @intFromEnum(vfs.FileType.directory)) {
        syscall.print("directory\n");
    } else {
        syscall.print("regular\n");
    }
    syscall.print("  size: ");
    printNum(st.size);
    syscall.print(" bytes\n");
}

fn cmdTouch(args: []const u8) void {
    if (args.len == 0) {
        syscall.print("usage: touch <file>\n");
        return;
    }
    const route = routePath(args);
    var reply_buf: [vfs.MAX_MSG_DATA]u8 = undefined;
    const result = vfs.callSlot(route.slot, .create, route.name, 0, 0, &.{}, &reply_buf);
    if (result.err != .success) {
        syscall.print("touch: ");
        printFsError(result.err);
        syscall.print("\n");
    }
}

fn cmdWrite(args: []const u8) void {
    // usage: write <name> <text...>
    var i: usize = 0;
    while (i < args.len and args[i] != ' ') : (i += 1) {}
    if (i == 0 or i == args.len) {
        syscall.print("usage: write <file> <text>\n");
        return;
    }
    const path = args[0..i];
    while (i < args.len and args[i] == ' ') : (i += 1) {}
    const text = args[i..];

    const route = routePath(path);
    var reply_buf: [vfs.MAX_MSG_DATA]u8 = undefined;
    // Ensure file exists on writable filesystems (ramfs). Skip for devfs
    // since its namespace is read-only and create would return .permission.
    if (route.slot == vfs.VFS_CAP_SLOT) {
        _ = vfs.callSlot(route.slot, .create, route.name, 0, 0, &.{}, &reply_buf);
    }
    const result = vfs.callSlot(route.slot, .write, route.name, 0, 0, text, &reply_buf);
    if (result.err != .success) {
        syscall.print("write: ");
        printFsError(result.err);
        syscall.print("\n");
    }
}

fn cmdLog(args: []const u8) void {
    if (args.len == 0) {
        syscall.print("usage: log <text>\n");
        return;
    }
    const ret = logsvc.log(args);
    if (ret < 0) {
        syscall.print("log: error\n");
    }
}

fn cmdRm(args: []const u8) void {
    if (args.len == 0) {
        syscall.print("usage: rm <file>\n");
        return;
    }
    const route = routePath(args);
    var reply_buf: [vfs.MAX_MSG_DATA]u8 = undefined;
    const result = vfs.callSlot(route.slot, .delete, route.name, 0, 0, &.{}, &reply_buf);
    if (result.err != .success) {
        syscall.print("rm: ");
        printFsError(result.err);
        syscall.print("\n");
    }
}

fn cmdMount() void {
    syscall.print("FILESYSTEM   SLOT  MOUNT     SERVER\n");
    syscall.print("-----------  ----  --------  --------\n");
    // Probe each known filesystem with a ping; report status.
    var reply_buf: [vfs.MAX_MSG_DATA]u8 = undefined;
    const ramfs_res = vfs.callSlot(vfs.VFS_CAP_SLOT, .ping, "", 0, 0, &.{}, &reply_buf);
    syscall.print("ramfs        1     /         ");
    if (ramfs_res.err == .success) syscall.print("ok\n") else syscall.print("unavailable\n");

    const devfs_res = vfs.callSlot(vfs.DEVFS_CAP_SLOT, .ping, "", 0, 0, &.{}, &reply_buf);
    syscall.print("devfs        3     /dev      ");
    if (devfs_res.err == .success) syscall.print("ok\n") else syscall.print("unavailable\n");
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

fn cmdMem() void {
    syscall.print("Memory Statistics:\n");
    syscall.print("------------------\n");

    var mem_result: syscall.MemInfoResult = undefined;
    const result = syscall.memInfo(&mem_result);

    if (result < 0) {
        syscall.print("Error getting memory info\n");
        return;
    }

    // Convert to KB and MB for readability
    const total_kb = mem_result.total_bytes / 1024;
    const free_kb = mem_result.free_bytes / 1024;
    const used_kb = mem_result.used_bytes / 1024;

    const total_mb = total_kb / 1024;
    const free_mb = free_kb / 1024;
    const used_mb = used_kb / 1024;

    syscall.print("Total:  ");
    printNum64(total_mb);
    syscall.print(" MB (");
    printNum64(total_kb);
    syscall.print(" KB)\n");

    syscall.print("Used:   ");
    printNum64(used_mb);
    syscall.print(" MB (");
    printNum64(used_kb);
    syscall.print(" KB)\n");

    syscall.print("Free:   ");
    printNum64(free_mb);
    syscall.print(" MB (");
    printNum64(free_kb);
    syscall.print(" KB)\n");

    // Calculate percentage
    if (mem_result.total_bytes > 0) {
        const used_percent = (mem_result.used_bytes * 100) / mem_result.total_bytes;
        syscall.print("Usage:  ");
        printNum64(used_percent);
        syscall.print("%\n");
    }
}

fn cmdUptime() void {
    const ticks = syscall.uptime();

    if (ticks < 0) {
        syscall.print("Error getting uptime\n");
        return;
    }

    // Convert ticks to seconds (assuming 100 Hz timer = 100 ticks/sec)
    const ticks_u: u64 = @intCast(ticks);
    const seconds = ticks_u / 100;
    const minutes = seconds / 60;
    const hours = minutes / 60;

    syscall.print("System Uptime:\n");
    syscall.print("--------------\n");

    syscall.print("Ticks:   ");
    printNum64(ticks_u);
    syscall.print("\n");

    if (hours > 0) {
        syscall.print("Time:    ");
        printNum64(hours);
        syscall.print("h ");
        printNum64(minutes % 60);
        syscall.print("m ");
        printNum64(seconds % 60);
        syscall.print("s\n");
    } else if (minutes > 0) {
        syscall.print("Time:    ");
        printNum64(minutes);
        syscall.print("m ");
        printNum64(seconds % 60);
        syscall.print("s\n");
    } else {
        syscall.print("Time:    ");
        printNum64(seconds);
        syscall.print("s\n");
    }
}

fn cmdSysinfo() void {
    syscall.print("=======================================\n");
    syscall.print("       GRAPHENE SYSTEM STATUS\n");
    syscall.print("=======================================\n\n");

    // Kernel info
    syscall.print("[Kernel]\n");
    syscall.print("  Name:      Graphene Kernel\n");
    syscall.print("  Version:   0.1.0\n");
    syscall.print("  Arch:      x86_64\n");
    syscall.print("  Type:      Hybrid Microkernel\n");
    syscall.print("  Security:  Capability-based\n\n");

    // Memory info
    syscall.print("[Memory]\n");
    var mem_result: syscall.MemInfoResult = undefined;
    const mem_status = syscall.memInfo(&mem_result);
    if (mem_status >= 0) {
        const total_mb = mem_result.total_bytes / (1024 * 1024);
        const free_mb = mem_result.free_bytes / (1024 * 1024);
        const used_mb = mem_result.used_bytes / (1024 * 1024);
        const usage_percent = if (mem_result.total_bytes > 0)
            (mem_result.used_bytes * 100) / mem_result.total_bytes
        else
            0;

        syscall.print("  Total:     ");
        printNum64(total_mb);
        syscall.print(" MB\n");
        syscall.print("  Used:      ");
        printNum64(used_mb);
        syscall.print(" MB (");
        printNum64(usage_percent);
        syscall.print("%)\n");
        syscall.print("  Free:      ");
        printNum64(free_mb);
        syscall.print(" MB\n\n");
    } else {
        syscall.print("  (unavailable)\n\n");
    }

    // Uptime
    syscall.print("[Uptime]\n");
    const ticks = syscall.uptime();
    if (ticks >= 0) {
        const ticks_u: u64 = @intCast(ticks);
        const seconds = ticks_u / 100;
        const minutes = seconds / 60;
        const hours = minutes / 60;

        syscall.print("  Time:      ");
        if (hours > 0) {
            printNum64(hours);
            syscall.print("h ");
            printNum64(minutes % 60);
            syscall.print("m ");
        } else if (minutes > 0) {
            printNum64(minutes);
            syscall.print("m ");
        }
        printNum64(seconds % 60);
        syscall.print("s\n");
        syscall.print("  Ticks:     ");
        printNum64(ticks_u);
        syscall.print("\n\n");
    } else {
        syscall.print("  (unavailable)\n\n");
    }

    // Process info
    syscall.print("[Processes]\n");
    const count_result = syscall.processCount();
    if (count_result >= 0) {
        syscall.print("  Running:   ");
        printNum(@intCast(@as(u64, @bitCast(count_result))));
        syscall.print(" processes\n");

        // List process names
        var entries: [16]syscall.ProcessInfoEntry = undefined;
        const max_entries: usize = @min(@as(usize, @intCast(@as(u64, @bitCast(count_result)))), 16);
        const list_result = syscall.processList(&entries, max_entries);
        if (list_result >= 0) {
            const actual_count: usize = @intCast(@as(u64, @bitCast(list_result)));
            syscall.print("  Services:  ");
            for (0..actual_count) |i| {
                if (i > 0) syscall.print(", ");
                printProcessName(&entries[i].name);
            }
            syscall.print("\n");
        }
    } else {
        syscall.print("  (unavailable)\n");
    }

    syscall.print("\n=======================================\n");
}

/// Print a 64-bit number
fn printNum64(num: u64) void {
    var buf: [20]u8 = undefined;
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
    } else if (strEql(command, "sysinfo")) {
        cmdSysinfo();
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
    } else if (strEql(command, "mem")) {
        cmdMem();
    } else if (strEql(command, "uptime")) {
        cmdUptime();
    } else if (strEql(command, "ls")) {
        cmdLs(args);
    } else if (strEql(command, "mount")) {
        cmdMount();
    } else if (strEql(command, "cat")) {
        cmdCat(args);
    } else if (strEql(command, "stat")) {
        cmdStat(args);
    } else if (strEql(command, "touch")) {
        cmdTouch(args);
    } else if (strEql(command, "write")) {
        cmdWrite(args);
    } else if (strEql(command, "rm")) {
        cmdRm(args);
    } else if (strEql(command, "log")) {
        cmdLog(args);
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
