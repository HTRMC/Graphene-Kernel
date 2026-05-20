// Graphene Ramfs Service - RAM Filesystem Server
// User-space filesystem. Stores files in memory. Speaks the VFS IPC protocol.

const syscall = @import("syscall");
const vfs = @import("vfs");

const MAX_NAME_LEN: usize = vfs.MAX_NAME_LEN;
const MAX_FILE_SIZE: usize = 64 * 1024;
const MAX_FILES: usize = 64;

/// File entry in ramfs
const FileEntry = struct {
    name: [MAX_NAME_LEN]u8 = [_]u8{0} ** MAX_NAME_LEN,
    name_len: u8 = 0,
    file_type: vfs.FileType = .regular,
    parent: u8 = 0,
    size: u32 = 0,
    data: [MAX_FILE_SIZE]u8 = undefined,
    in_use: bool = false,
};

var files: [MAX_FILES]FileEntry = undefined;
var fs_initialized: bool = false;

fn initFs() void {
    for (&files) |*f| {
        f.* = FileEntry{};
    }
    files[0].in_use = true;
    files[0].file_type = .directory;
    files[0].name[0] = '/';
    files[0].name_len = 1;
    files[0].parent = 0;
    fs_initialized = true;
    _ = syscall.klog("[ramfs] Filesystem initialized\n");
}

fn findFile(name: []const u8, parent: u8) ?u8 {
    for (&files, 0..) |*f, i| {
        if (f.in_use and f.parent == parent) {
            if (strEql(f.name[0..f.name_len], name)) {
                return @intCast(i);
            }
        }
    }
    return null;
}

fn allocFile() ?u8 {
    for (1..MAX_FILES) |i| {
        if (!files[i].in_use) {
            return @intCast(i);
        }
    }
    return null;
}

fn createFile(name: []const u8, parent: u8, file_type: vfs.FileType) vfs.FsError {
    if (name.len == 0 or name.len > MAX_NAME_LEN) return .invalid_arg;
    if (!files[parent].in_use or files[parent].file_type != .directory) return .not_directory;
    if (findFile(name, parent) != null) return .exists;

    const idx = allocFile() orelse return .no_space;
    files[idx].in_use = true;
    files[idx].file_type = file_type;
    files[idx].parent = parent;
    files[idx].size = 0;
    for (0..name.len) |i| files[idx].name[i] = name[i];
    files[idx].name_len = @intCast(name.len);
    return .success;
}

fn deleteFile(idx: u8) vfs.FsError {
    if (idx == 0) return .permission;
    if (!files[idx].in_use) return .not_found;
    if (files[idx].file_type == .directory) {
        for (&files) |*f| {
            if (f.in_use and f.parent == idx) return .not_empty;
        }
    }
    files[idx].in_use = false;
    return .success;
}

fn readFile(idx: u8, offset: u32, buf: []u8) struct { err: vfs.FsError, count: u32 } {
    if (!files[idx].in_use) return .{ .err = .not_found, .count = 0 };
    if (files[idx].file_type != .regular) return .{ .err = .is_directory, .count = 0 };
    if (offset >= files[idx].size) return .{ .err = .success, .count = 0 };

    const available = files[idx].size - offset;
    const to_read = @min(buf.len, available);
    for (0..to_read) |i| buf[i] = files[idx].data[offset + i];
    return .{ .err = .success, .count = @intCast(to_read) };
}

fn writeFile(idx: u8, offset: u32, data: []const u8) vfs.FsError {
    if (!files[idx].in_use) return .not_found;
    if (files[idx].file_type != .regular) return .is_directory;

    const end_pos = offset + @as(u32, @intCast(data.len));
    if (end_pos > MAX_FILE_SIZE) return .no_space;
    for (0..data.len) |i| files[idx].data[offset + i] = data[i];
    if (end_pos > files[idx].size) files[idx].size = end_pos;
    return .success;
}

// ============================================================================
// Request dispatcher
// ============================================================================

fn handleRequest(req_data: []const u8, resp_data: []u8) usize {
    const hdr_sz = @sizeOf(vfs.ResponseHeader);
    const resp: *vfs.ResponseHeader = @ptrCast(@alignCast(resp_data.ptr));
    const resp_payload = resp_data[hdr_sz..];

    if (req_data.len < @sizeOf(vfs.RequestHeader)) {
        resp.* = .{ .error_code = @intFromEnum(vfs.FsError.invalid_arg), .size = 0 };
        return hdr_sz;
    }

    const req: *const vfs.RequestHeader = @ptrCast(@alignCast(req_data.ptr));
    const op: vfs.FsOp = @enumFromInt(req.op);

    var name: []const u8 = &.{};
    if (req.name_len > 0 and req_data.len >= @sizeOf(vfs.RequestHeader) + req.name_len) {
        name = req_data[@sizeOf(vfs.RequestHeader)..][0..req.name_len];
    }

    const data_offset = @sizeOf(vfs.RequestHeader) + req.name_len;
    var data: []const u8 = &.{};
    if (req_data.len > data_offset) data = req_data[data_offset..];

    switch (op) {
        .tty_input => {
            resp.* = .{ .error_code = @intFromEnum(vfs.FsError.invalid_arg), .size = 0 };
            return hdr_sz;
        },
        .ping => {
            resp.* = .{ .error_code = 0, .size = 4 };
            if (resp_payload.len >= 4) {
                resp_payload[0] = 'P';
                resp_payload[1] = 'O';
                resp_payload[2] = 'N';
                resp_payload[3] = 'G';
            }
            return hdr_sz + 4;
        },
        .create => {
            const result = createFile(name, 0, .regular);
            resp.* = .{ .error_code = @intFromEnum(result), .size = 0 };
            return hdr_sz;
        },
        .mkdir => {
            const result = createFile(name, 0, .directory);
            resp.* = .{ .error_code = @intFromEnum(result), .size = 0 };
            return hdr_sz;
        },
        .delete => {
            const code: i32 = if (findFile(name, 0)) |idx|
                @intFromEnum(deleteFile(idx))
            else
                @intFromEnum(vfs.FsError.not_found);
            resp.* = .{ .error_code = code, .size = 0 };
            return hdr_sz;
        },
        .stat => {
            if (findFile(name, 0)) |idx| {
                resp.* = .{ .error_code = 0, .size = @sizeOf(vfs.FileStat) };
                if (resp_payload.len >= @sizeOf(vfs.FileStat)) {
                    const stat: *vfs.FileStat = @ptrCast(@alignCast(resp_payload.ptr));
                    stat.size = files[idx].size;
                    stat.file_type = @intFromEnum(files[idx].file_type);
                    stat._pad = .{ 0, 0, 0 };
                }
                return hdr_sz + @sizeOf(vfs.FileStat);
            }
            resp.* = .{ .error_code = @intFromEnum(vfs.FsError.not_found), .size = 0 };
            return hdr_sz;
        },
        .open => {
            // Stateless open: return file_id (entry index) as payload, or error
            if (findFile(name, 0)) |idx| {
                resp.* = .{ .error_code = 0, .size = 4 };
                if (resp_payload.len >= 4) {
                    resp_payload[0] = idx;
                    resp_payload[1] = 0;
                    resp_payload[2] = 0;
                    resp_payload[3] = 0;
                }
                return hdr_sz + 4;
            }
            resp.* = .{ .error_code = @intFromEnum(vfs.FsError.not_found), .size = 0 };
            return hdr_sz;
        },
        .close => {
            // Stateless: nothing to do
            resp.* = .{ .error_code = 0, .size = 0 };
            return hdr_sz;
        },
        .read => {
            if (findFile(name, 0)) |idx| {
                const max_read = @min(req.size, @as(u32, @intCast(resp_payload.len)));
                const result = readFile(idx, req.offset, resp_payload[0..max_read]);
                resp.* = .{ .error_code = @intFromEnum(result.err), .size = result.count };
                return hdr_sz + result.count;
            }
            resp.* = .{ .error_code = @intFromEnum(vfs.FsError.not_found), .size = 0 };
            return hdr_sz;
        },
        .write => {
            if (findFile(name, 0)) |idx| {
                const result = writeFile(idx, req.offset, data);
                const written: u32 = if (result == .success) @intCast(data.len) else 0;
                resp.* = .{ .error_code = @intFromEnum(result), .size = written };
            } else {
                resp.* = .{ .error_code = @intFromEnum(vfs.FsError.not_found), .size = 0 };
            }
            return hdr_sz;
        },
        .readdir => {
            var count: i32 = 0;
            var pos: usize = 0;
            for (&files, 0..) |*f, i| {
                if (i == 0) continue;
                if (f.in_use and f.parent == 0) {
                    if (pos + 2 + f.name_len <= resp_payload.len) {
                        resp_payload[pos] = f.name_len;
                        resp_payload[pos + 1] = @intFromEnum(f.file_type);
                        for (0..f.name_len) |k| resp_payload[pos + 2 + k] = f.name[k];
                        pos += 2 + f.name_len;
                        count += 1;
                    }
                }
            }
            // readdir overloads error_code to mean count
            resp.* = .{ .error_code = count, .size = @intCast(pos) };
            return hdr_sz + pos;
        },
    }
}

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (ac != bc) return false;
    }
    return true;
}

// ============================================================================
// Main service loop
// ============================================================================

pub fn main() i32 {
    _ = syscall.klog("[ramfs] RAM Filesystem service starting...\n");
    initFs();

    // Seed test files
    _ = createFile("hello.txt", 0, .regular);
    if (findFile("hello.txt", 0)) |idx| {
        _ = writeFile(idx, 0, "Hello from ramfs!\n");
    }
    _ = createFile("readme.txt", 0, .regular);
    if (findFile("readme.txt", 0)) |idx| {
        _ = writeFile(idx, 0, "Graphene Ramfs v0.1\nA simple RAM filesystem.\n");
    }
    _ = createFile("test", 0, .directory);

    _ = syscall.klog("[ramfs] Test files seeded\n");
    _ = syscall.klog("[ramfs] Listening on VFS endpoint...\n");

    var req_buf: [vfs.MAX_MSG_DATA]u8 = undefined;
    var resp_buf: [vfs.MAX_MSG_DATA]u8 = undefined;

    while (true) {
        const recv_len = syscall.capRecv(vfs.VFS_CAP_SLOT, &req_buf, req_buf.len);
        if (recv_len < 0) {
            // Cap not available yet or transient error - yield and retry
            syscall.threadYield();
            continue;
        }

        const req_slice = req_buf[0..@intCast(recv_len)];
        const resp_len = handleRequest(req_slice, &resp_buf);

        _ = syscall.capSend(vfs.VFS_CAP_SLOT, &resp_buf, resp_len);
    }

    return 0;
}
