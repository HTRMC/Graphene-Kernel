// Graphene Shell
// Interactive command-line shell

const syscall = @import("syscall");
const vfs = @import("vfs");
const logsvc = @import("log");

pub const proc_name: []const u8 = "shell";

// ---------------------------------------------------------------------------
// Shell I/O goes through the tty service via the shared TTY endpoint.
// Output: a write op renders the bytes onto the framebuffer.
// Input: a read op pulls characters from tty's input queue (filled by
// the kbd driver). Reads are non-blocking — we yield and retry.
// ---------------------------------------------------------------------------
fn ttyWrite(data: []const u8) void {
    if (data.len == 0) return;
    var reply_buf: [@sizeOf(vfs.ResponseHeader) + 4]u8 = undefined;
    _ = vfs.callSlot(vfs.TTY_CAP_SLOT, .write, "", 0, @intCast(data.len), data, &reply_buf);
}

fn ttyPrint(comptime msg: []const u8) void {
    ttyWrite(msg);
}

fn ttyGetc() i64 {
    var buf: [16]u8 = undefined;
    const n = syscall.capRecv(vfs.KBD_INPUT_SLOT, &buf, buf.len);
    if (n <= 0) return -1;
    return @as(i64, buf[0]);
}

/// Command buffer
const MAX_CMD_LEN: usize = 128;
var cmd_buffer: [MAX_CMD_LEN]u8 = undefined;
var cmd_len: usize = 0;

/// Shell prompt
fn printPrompt() void {
    ttyPrint("\ngraphene> ");
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
const MNT_PREFIX = "/mnt/";
const MNT_ROOT = "/mnt";

/// Route a path to (capability slot, server-relative name).
/// `/dev/foo` -> devfs, `/mnt/foo` -> fatfs; everything else -> ramfs.
fn routePath(path: []const u8) struct { slot: u32, name: []const u8 } {
    if (startsWith(path, DEV_PREFIX)) {
        return .{ .slot = vfs.DEVFS_CAP_SLOT, .name = path[DEV_PREFIX.len..] };
    }
    if (startsWith(path, MNT_PREFIX)) {
        return .{ .slot = vfs.FATFS_CAP_SLOT, .name = path[MNT_PREFIX.len..] };
    }
    return .{ .slot = vfs.VFS_CAP_SLOT, .name = path };
}

/// Print a number
fn printNum(num: u32) void {
    var buf: [16]u8 = undefined;
    var n = num;
    var len: usize = 0;

    if (n == 0) {
        ttyPrint("0");
        return;
    }

    while (n > 0 and len < buf.len) : (len += 1) {
        buf[buf.len - 1 - len] = @truncate((n % 10) + '0');
        n /= 10;
    }

    _ = ttyWrite(buf[buf.len - len ..]);
}

// ============================================================================
// Commands
// ============================================================================

fn cmdHelp() void {
    ttyPrint("Available commands:\n");
    ttyPrint("  help     - Show this help message\n");
    ttyPrint("  clear    - Clear the screen\n");
    ttyPrint("  info     - Show system information\n");
    ttyPrint("  sysinfo  - Show comprehensive system status\n");
    ttyPrint("  echo     - Echo text back\n");
    ttyPrint("  yield    - Yield CPU time slice\n");
    ttyPrint("  caps     - Show capability types\n");
    ttyPrint("  ipc-test - Test IPC functionality\n");
    ttyPrint("  ps       - List running processes\n");
    ttyPrint("  mem      - Show memory statistics\n");
    ttyPrint("  uptime   - Show system uptime\n");
    ttyPrint("  ls       - List files (ls [/dev])\n");
    ttyPrint("  cat      - Print file contents\n");
    ttyPrint("  stat     - Show file metadata\n");
    ttyPrint("  touch    - Create empty file\n");
    ttyPrint("  write    - Write text to file\n");
    ttyPrint("  rm       - Delete file\n");
    ttyPrint("  mount    - List active filesystems\n");
}

// ============================================================================
// VFS commands
// ============================================================================

fn printFsError(err: vfs.FsError) void {
    switch (err) {
        .success => ttyPrint("success"),
        .not_found => ttyPrint("not found"),
        .exists => ttyPrint("already exists"),
        .no_space => ttyPrint("no space"),
        .invalid_arg => ttyPrint("invalid argument"),
        .is_directory => ttyPrint("is a directory"),
        .not_directory => ttyPrint("not a directory"),
        .not_empty => ttyPrint("not empty"),
        .io_error => ttyPrint("io error"),
        .permission => ttyPrint("permission denied"),
    }
}

fn cmdLs(args: []const u8) void {
    // Default to ramfs root; /dev routes to devfs, /mnt routes to fatfs.
    var slot: u32 = vfs.VFS_CAP_SLOT;
    if (args.len > 0) {
        if (strEql(args, DEV_ROOT) or strEql(args, DEV_PREFIX) or startsWith(args, DEV_PREFIX)) {
            slot = vfs.DEVFS_CAP_SLOT;
        } else if (strEql(args, MNT_ROOT) or strEql(args, MNT_PREFIX) or startsWith(args, MNT_PREFIX)) {
            slot = vfs.FATFS_CAP_SLOT;
        }
    }

    var reply_buf: [vfs.MAX_MSG_DATA]u8 = undefined;
    const result = vfs.callSlot(slot, .readdir, "", 0, 0, &.{}, &reply_buf);
    const count = vfs.readdirCount(&reply_buf);
    if (count < 0) {
        ttyPrint("ls: ");
        printFsError(result.err);
        ttyPrint("\n");
        return;
    }

    var pos: usize = 0;
    var n: i32 = 0;
    while (n < count and pos + 2 <= result.payload.len) : (n += 1) {
        const name_len: usize = result.payload[pos];
        const ftype = result.payload[pos + 1];
        if (pos + 2 + name_len > result.payload.len) break;
        const name = result.payload[pos + 2 ..][0..name_len];
        if (ftype == @intFromEnum(vfs.FileType.directory)) ttyPrint("d ") else ttyPrint("- ");
        _ = ttyWrite(name);
        ttyPrint("\n");
        pos += 2 + name_len;
    }
}

fn cmdCat(args: []const u8) void {
    if (args.len == 0) {
        ttyPrint("usage: cat <file>\n");
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
            ttyPrint("cat: ");
            printFsError(result.err);
            ttyPrint("\n");
            return;
        }
        if (result.payload.len == 0) break;
        _ = ttyWrite(result.payload);
        offset += @intCast(result.payload.len);
        if (result.payload.len < max_chunk) break;
    }
}

fn cmdStat(args: []const u8) void {
    if (args.len == 0) {
        ttyPrint("usage: stat <file>\n");
        return;
    }
    const route = routePath(args);
    var reply_buf: [vfs.MAX_MSG_DATA]u8 = undefined;
    const result = vfs.callSlot(route.slot, .stat, route.name, 0, 0, &.{}, &reply_buf);
    if (result.err != .success) {
        ttyPrint("stat: ");
        printFsError(result.err);
        ttyPrint("\n");
        return;
    }
    if (result.payload.len < @sizeOf(vfs.FileStat)) {
        ttyPrint("stat: short reply\n");
        return;
    }
    const st: *const vfs.FileStat = @ptrCast(@alignCast(result.payload.ptr));
    ttyPrint("  type: ");
    if (st.file_type == @intFromEnum(vfs.FileType.directory)) {
        ttyPrint("directory\n");
    } else {
        ttyPrint("regular\n");
    }
    ttyPrint("  size: ");
    printNum(st.size);
    ttyPrint(" bytes\n");
}

fn cmdTouch(args: []const u8) void {
    if (args.len == 0) {
        ttyPrint("usage: touch <file>\n");
        return;
    }
    const route = routePath(args);
    var reply_buf: [vfs.MAX_MSG_DATA]u8 = undefined;
    const result = vfs.callSlot(route.slot, .create, route.name, 0, 0, &.{}, &reply_buf);
    if (result.err != .success) {
        ttyPrint("touch: ");
        printFsError(result.err);
        ttyPrint("\n");
    }
}

fn cmdWrite(args: []const u8) void {
    // usage: write <name> <text...>
    var i: usize = 0;
    while (i < args.len and args[i] != ' ') : (i += 1) {}
    if (i == 0 or i == args.len) {
        ttyPrint("usage: write <file> <text>\n");
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
        ttyPrint("write: ");
        printFsError(result.err);
        ttyPrint("\n");
    }
}

fn cmdLog(args: []const u8) void {
    if (args.len == 0) {
        ttyPrint("usage: log <text>\n");
        return;
    }
    const ret = logsvc.log(args);
    if (ret < 0) {
        ttyPrint("log: error\n");
    }
}

fn cmdRm(args: []const u8) void {
    if (args.len == 0) {
        ttyPrint("usage: rm <file>\n");
        return;
    }
    const route = routePath(args);
    var reply_buf: [vfs.MAX_MSG_DATA]u8 = undefined;
    const result = vfs.callSlot(route.slot, .delete, route.name, 0, 0, &.{}, &reply_buf);
    if (result.err != .success) {
        ttyPrint("rm: ");
        printFsError(result.err);
        ttyPrint("\n");
    }
}

fn cmdMount() void {
    ttyPrint("FILESYSTEM   SLOT  MOUNT     SERVER\n");
    ttyPrint("-----------  ----  --------  --------\n");
    // Probe each known filesystem with a ping; report status.
    var reply_buf: [vfs.MAX_MSG_DATA]u8 = undefined;
    const ramfs_res = vfs.callSlot(vfs.VFS_CAP_SLOT, .ping, "", 0, 0, &.{}, &reply_buf);
    ttyPrint("ramfs        1     /         ");
    if (ramfs_res.err == .success) ttyPrint("ok\n") else ttyPrint("unavailable\n");

    const devfs_res = vfs.callSlot(vfs.DEVFS_CAP_SLOT, .ping, "", 0, 0, &.{}, &reply_buf);
    ttyPrint("devfs        3     /dev      ");
    if (devfs_res.err == .success) ttyPrint("ok\n") else ttyPrint("unavailable\n");
}

fn cmdClear() void {
    // Clear by printing many newlines (simple approach)
    var i: u32 = 0;
    while (i < 30) : (i += 1) {
        ttyPrint("\n");
    }
}

fn cmdInfo() void {
    ttyPrint("Graphene Kernel v0.1.0\n");
    ttyPrint("Architecture: x86_64\n");
    ttyPrint("Type: Hybrid Microkernel\n");
    ttyPrint("Security: Capability-based\n");
}

fn cmdEcho(args: []const u8) void {
    if (args.len > 0) {
        _ = ttyWrite(args);
    }
    ttyPrint("\n");
}

fn cmdYield() void {
    ttyPrint("Yielding CPU...\n");
    syscall.threadYield();
    ttyPrint("Resumed.\n");
}

fn cmdCaps() void {
    ttyPrint("Capability Types:\n");
    ttyPrint("  memory      - Physical memory regions\n");
    ttyPrint("  thread      - Thread control\n");
    ttyPrint("  process     - Process control\n");
    ttyPrint("  ipc_endpoint- IPC endpoints\n");
    ttyPrint("  ipc_channel - IPC channels\n");
    ttyPrint("  irq         - Hardware interrupts\n");
    ttyPrint("  ioport      - I/O port access\n");
}

fn cmdIpcTest() void {
    ttyPrint("=== IPC Test ===\n");

    // Test 1: Create an endpoint
    ttyPrint("Creating endpoint... ");
    const ep_result = syscall.endpointCreate();
    if (ep_result < 0) {
        ttyPrint("FAILED (error ");
        printSignedNum(ep_result);
        ttyPrint(")\n");
        return;
    }
    ttyPrint("OK (slot ");
    printNum(@intCast(@as(u64, @bitCast(ep_result))));
    ttyPrint(")\n");

    // Test 2: Create a channel (bidirectional)
    ttyPrint("Creating channel... ");
    var slot0: u32 = 0;
    var slot1: u32 = 0;
    const ch_result = syscall.channelCreate(&slot0, &slot1);
    if (ch_result < 0) {
        ttyPrint("FAILED (error ");
        printSignedNum(ch_result);
        ttyPrint(")\n");
        return;
    }
    ttyPrint("OK (slots ");
    printNum(slot0);
    ttyPrint(", ");
    printNum(slot1);
    ttyPrint(")\n");

    ttyPrint("\nIPC subsystem working!\n");
    ttyPrint("Note: Full send/recv test requires async mode\n");
    ttyPrint("or multiple processes.\n");
}

fn cmdPs() void {
    ttyPrint("PID   STATE    THREADS  NAME\n");
    ttyPrint("----  -------  -------  ----------------\n");

    // Get process count
    const count_result = syscall.processCount();
    if (count_result < 0) {
        ttyPrint("Error getting process count\n");
        return;
    }

    // Allocate buffer on stack (max 16 processes)
    var entries: [16]syscall.ProcessInfoEntry = undefined;
    const max_entries: usize = @min(@as(usize, @intCast(@as(u64, @bitCast(count_result)))), 16);

    const list_result = syscall.processList(&entries, max_entries);
    if (list_result < 0) {
        ttyPrint("Error getting process list\n");
        return;
    }

    const actual_count: usize = @intCast(@as(u64, @bitCast(list_result)));

    for (0..actual_count) |i| {
        const entry = entries[i];

        // Print PID (right-padded)
        printNumPadded(entry.pid, 4);
        ttyPrint("  ");

        // Print state
        switch (entry.state) {
            0 => ttyPrint("running"),
            1 => ttyPrint("stopped"),
            2 => ttyPrint("zombie "),
            else => ttyPrint("unknown"),
        }
        ttyPrint("  ");

        // Print thread count
        printNumPadded(entry.thread_count, 7);
        ttyPrint("  ");

        // Print name (null-terminated)
        printProcessName(&entry.name);
        ttyPrint("\n");
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
            ttyPrint(" ");
        }
        ttyPrint("0");
        return;
    }

    while (n > 0 and len < buf.len) : (len += 1) {
        buf[buf.len - 1 - len] = @truncate((n % 10) + '0');
        n /= 10;
    }

    // Print padding spaces
    if (len < width) {
        for (0..width - len) |_| {
            ttyPrint(" ");
        }
    }

    _ = ttyWrite(buf[buf.len - len ..]);
}

/// Print process name (null-terminated from fixed array)
fn printProcessName(name: *const [32]u8) void {
    var len: usize = 0;
    while (len < 32 and name[len] != 0) : (len += 1) {}
    if (len > 0) {
        _ = ttyWrite(name[0..len]);
    }
}

/// Print a signed number
fn printSignedNum(num: i64) void {
    if (num < 0) {
        ttyPrint("-");
        printNum(@intCast(@as(u64, @bitCast(-num))));
    } else {
        printNum(@intCast(@as(u64, @bitCast(num))));
    }
}

fn cmdMem() void {
    ttyPrint("Memory Statistics:\n");
    ttyPrint("------------------\n");

    var mem_result: syscall.MemInfoResult = undefined;
    const result = syscall.memInfo(&mem_result);

    if (result < 0) {
        ttyPrint("Error getting memory info\n");
        return;
    }

    // Convert to KB and MB for readability
    const total_kb = mem_result.total_bytes / 1024;
    const free_kb = mem_result.free_bytes / 1024;
    const used_kb = mem_result.used_bytes / 1024;

    const total_mb = total_kb / 1024;
    const free_mb = free_kb / 1024;
    const used_mb = used_kb / 1024;

    ttyPrint("Total:  ");
    printNum64(total_mb);
    ttyPrint(" MB (");
    printNum64(total_kb);
    ttyPrint(" KB)\n");

    ttyPrint("Used:   ");
    printNum64(used_mb);
    ttyPrint(" MB (");
    printNum64(used_kb);
    ttyPrint(" KB)\n");

    ttyPrint("Free:   ");
    printNum64(free_mb);
    ttyPrint(" MB (");
    printNum64(free_kb);
    ttyPrint(" KB)\n");

    // Calculate percentage
    if (mem_result.total_bytes > 0) {
        const used_percent = (mem_result.used_bytes * 100) / mem_result.total_bytes;
        ttyPrint("Usage:  ");
        printNum64(used_percent);
        ttyPrint("%\n");
    }
}

fn cmdUptime() void {
    const ticks = syscall.uptime();

    if (ticks < 0) {
        ttyPrint("Error getting uptime\n");
        return;
    }

    // Convert ticks to seconds (assuming 100 Hz timer = 100 ticks/sec)
    const ticks_u: u64 = @intCast(ticks);
    const seconds = ticks_u / 100;
    const minutes = seconds / 60;
    const hours = minutes / 60;

    ttyPrint("System Uptime:\n");
    ttyPrint("--------------\n");

    ttyPrint("Ticks:   ");
    printNum64(ticks_u);
    ttyPrint("\n");

    if (hours > 0) {
        ttyPrint("Time:    ");
        printNum64(hours);
        ttyPrint("h ");
        printNum64(minutes % 60);
        ttyPrint("m ");
        printNum64(seconds % 60);
        ttyPrint("s\n");
    } else if (minutes > 0) {
        ttyPrint("Time:    ");
        printNum64(minutes);
        ttyPrint("m ");
        printNum64(seconds % 60);
        ttyPrint("s\n");
    } else {
        ttyPrint("Time:    ");
        printNum64(seconds);
        ttyPrint("s\n");
    }
}

fn cmdSysinfo() void {
    ttyPrint("=======================================\n");
    ttyPrint("       GRAPHENE SYSTEM STATUS\n");
    ttyPrint("=======================================\n\n");

    // Kernel info
    ttyPrint("[Kernel]\n");
    ttyPrint("  Name:      Graphene Kernel\n");
    ttyPrint("  Version:   0.1.0\n");
    ttyPrint("  Arch:      x86_64\n");
    ttyPrint("  Type:      Hybrid Microkernel\n");
    ttyPrint("  Security:  Capability-based\n\n");

    // Memory info
    ttyPrint("[Memory]\n");
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

        ttyPrint("  Total:     ");
        printNum64(total_mb);
        ttyPrint(" MB\n");
        ttyPrint("  Used:      ");
        printNum64(used_mb);
        ttyPrint(" MB (");
        printNum64(usage_percent);
        ttyPrint("%)\n");
        ttyPrint("  Free:      ");
        printNum64(free_mb);
        ttyPrint(" MB\n\n");
    } else {
        ttyPrint("  (unavailable)\n\n");
    }

    // Uptime
    ttyPrint("[Uptime]\n");
    const ticks = syscall.uptime();
    if (ticks >= 0) {
        const ticks_u: u64 = @intCast(ticks);
        const seconds = ticks_u / 100;
        const minutes = seconds / 60;
        const hours = minutes / 60;

        ttyPrint("  Time:      ");
        if (hours > 0) {
            printNum64(hours);
            ttyPrint("h ");
            printNum64(minutes % 60);
            ttyPrint("m ");
        } else if (minutes > 0) {
            printNum64(minutes);
            ttyPrint("m ");
        }
        printNum64(seconds % 60);
        ttyPrint("s\n");
        ttyPrint("  Ticks:     ");
        printNum64(ticks_u);
        ttyPrint("\n\n");
    } else {
        ttyPrint("  (unavailable)\n\n");
    }

    // Process info
    ttyPrint("[Processes]\n");
    const count_result = syscall.processCount();
    if (count_result >= 0) {
        ttyPrint("  Running:   ");
        printNum(@intCast(@as(u64, @bitCast(count_result))));
        ttyPrint(" processes\n");

        // List process names
        var entries: [16]syscall.ProcessInfoEntry = undefined;
        const max_entries: usize = @min(@as(usize, @intCast(@as(u64, @bitCast(count_result)))), 16);
        const list_result = syscall.processList(&entries, max_entries);
        if (list_result >= 0) {
            const actual_count: usize = @intCast(@as(u64, @bitCast(list_result)));
            ttyPrint("  Services:  ");
            for (0..actual_count) |i| {
                if (i > 0) ttyPrint(", ");
                printProcessName(&entries[i].name);
            }
            ttyPrint("\n");
        }
    } else {
        ttyPrint("  (unavailable)\n");
    }

    ttyPrint("\n=======================================\n");
}

/// Print a 64-bit number
fn printNum64(num: u64) void {
    var buf: [20]u8 = undefined;
    var n = num;
    var len: usize = 0;

    if (n == 0) {
        ttyPrint("0");
        return;
    }

    while (n > 0 and len < buf.len) : (len += 1) {
        buf[buf.len - 1 - len] = @truncate((n % 10) + '0');
        n /= 10;
    }

    _ = ttyWrite(buf[buf.len - len ..]);
}

fn cmdUnknown(cmd: []const u8) void {
    ttyPrint("Unknown command: ");
    _ = ttyWrite(cmd);
    ttyPrint("\nType 'help' for available commands.\n");
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
        const result = ttyGetc();
        if (result < 0) {
            // Error - return what we have
            break;
        }

        const c: u8 = @truncate(@as(u64, @bitCast(result)));

        if (c == '\n') {
            break;
        } else if (c == 8) {
            // Backspace: drop a char from the buffer and visibly erase
            // one cell on the screen.
            if (cmd_len > 0) {
                cmd_len -= 1;
                const bs = [_]u8{8};
                ttyWrite(&bs);
            }
        } else if (c >= 32 and c < 127) {
            if (cmd_len < MAX_CMD_LEN - 1) {
                cmd_buffer[cmd_len] = c;
                cmd_len += 1;
                const echo = [_]u8{c};
                ttyWrite(&echo);
            }
        }
    }

    return cmd_buffer[0..cmd_len];
}

/// Main entry point
pub fn main() i32 {
    ttyPrint("Graphene Shell v0.1.0\n");
    ttyPrint("Type 'help' for available commands.\n");

    // Main shell loop
    while (true) {
        printPrompt();
        const cmd = readLine();
        ttyPrint("\n"); // Echo newline after Enter
        executeCommand(cmd);
    }

    return 0;
}
