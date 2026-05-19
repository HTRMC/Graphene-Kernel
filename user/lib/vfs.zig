// Graphene VFS Protocol - Shared between ramfs service and clients
// Wire format for filesystem requests/replies over IPC

const syscall = @import("syscall");

/// Well-known capability slot where kernel injects the VFS endpoint cap.
/// Server (ramfs) gets HANDLE rights; clients (shell, etc.) get SEND rights.
pub const VFS_CAP_SLOT: u32 = 1;

/// Well-known capability slot for the device filesystem (devfs) endpoint.
pub const DEVFS_CAP_SLOT: u32 = 3;

/// Maximum filename length on the wire
pub const MAX_NAME_LEN: usize = 64;

/// Maximum inline data per message (matches kernel ipc.MAX_INLINE_DATA = 256)
pub const MAX_MSG_DATA: usize = 256;

/// Filesystem operation codes
pub const FsOp = enum(u8) {
    open = 1,
    close = 2,
    read = 3,
    write = 4,
    stat = 5,
    readdir = 6,
    create = 7,
    delete = 8,
    mkdir = 9,
    ping = 255,
};

/// Filesystem error codes
pub const FsError = enum(i32) {
    success = 0,
    not_found = -1,
    exists = -2,
    no_space = -3,
    invalid_arg = -4,
    is_directory = -5,
    not_directory = -6,
    not_empty = -7,
    io_error = -8,
    permission = -9,
};

/// File type
pub const FileType = enum(u8) {
    regular = 1,
    directory = 2,
};

/// Request header. Wire layout: [RequestHeader][name (name_len bytes)][data (rest)]
pub const RequestHeader = extern struct {
    op: u8,
    flags: u8 = 0,
    name_len: u8 = 0,
    _pad: u8 = 0,
    offset: u32 = 0,
    size: u32 = 0,
};

/// Response header. Wire layout: [ResponseHeader][payload (size bytes)]
pub const ResponseHeader = extern struct {
    error_code: i32 = 0,
    size: u32 = 0,
};

/// File stat payload
pub const FileStat = extern struct {
    size: u32,
    file_type: u8,
    _pad: [3]u8 = .{ 0, 0, 0 },
};

// ============================================================================
// Client helpers
// ============================================================================

/// Build a request into buf. Returns total byte count written.
pub fn buildRequest(
    buf: []u8,
    op: FsOp,
    name: []const u8,
    offset: u32,
    size: u32,
    data: []const u8,
) usize {
    const hdr_sz = @sizeOf(RequestHeader);
    if (buf.len < hdr_sz) return 0;
    if (name.len > MAX_NAME_LEN) return 0;

    const total = hdr_sz + name.len + data.len;
    if (buf.len < total) return 0;

    const hdr: *RequestHeader = @ptrCast(@alignCast(buf.ptr));
    hdr.* = .{
        .op = @intFromEnum(op),
        .flags = 0,
        .name_len = @intCast(name.len),
        ._pad = 0,
        .offset = offset,
        .size = size,
    };

    var pos: usize = hdr_sz;
    for (name) |c| {
        buf[pos] = c;
        pos += 1;
    }
    for (data) |c| {
        buf[pos] = c;
        pos += 1;
    }
    return pos;
}

/// Result of a VFS call
pub const CallResult = struct {
    err: FsError,
    payload: []const u8,
};

/// Send a VFS request to a specific capability slot and wait for reply.
pub fn callSlot(
    slot: u32,
    op: FsOp,
    name: []const u8,
    offset: u32,
    size: u32,
    data: []const u8,
    reply_buf: []u8,
) CallResult {
    var req_buf: [MAX_MSG_DATA]u8 = undefined;
    const req_len = buildRequest(&req_buf, op, name, offset, size, data);
    if (req_len == 0) {
        return .{ .err = .invalid_arg, .payload = &.{} };
    }

    const ret = syscall.capCall(slot, req_buf[0..req_len], reply_buf);
    if (ret < 0) {
        return .{ .err = .io_error, .payload = &.{} };
    }

    const reply_len: usize = @intCast(ret);
    const hdr_sz = @sizeOf(ResponseHeader);
    if (reply_len < hdr_sz) {
        return .{ .err = .io_error, .payload = &.{} };
    }

    const hdr: *const ResponseHeader = @ptrCast(@alignCast(reply_buf.ptr));
    const payload_end = @min(reply_len, hdr_sz + hdr.size);
    const payload = reply_buf[hdr_sz..payload_end];

    // For readdir, error_code holds the entry count, not an error
    if (op == .readdir) {
        return .{ .err = .success, .payload = payload };
    }

    const err: FsError = @enumFromInt(hdr.error_code);
    return .{ .err = err, .payload = payload };
}

/// Backwards-compatible wrapper that targets VFS_CAP_SLOT (ramfs).
pub fn call(
    op: FsOp,
    name: []const u8,
    offset: u32,
    size: u32,
    data: []const u8,
    reply_buf: []u8,
) CallResult {
    return callSlot(VFS_CAP_SLOT, op, name, offset, size, data, reply_buf);
}

/// Get readdir entry count from a readdir reply
pub fn readdirCount(reply_buf: []const u8) i32 {
    if (reply_buf.len < @sizeOf(ResponseHeader)) return 0;
    const hdr: *const ResponseHeader = @ptrCast(@alignCast(reply_buf.ptr));
    return hdr.error_code;
}
