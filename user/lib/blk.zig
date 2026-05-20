// Graphene Block-Device IPC Protocol
// Wire format for read_sector / write_sector / get_capacity requests
// between the virtio-blk service and its clients (e.g. devfs).
//
// One message per request, one reply. Sector size is fixed at 512 bytes.

const syscall = @import("syscall");

/// Sector size in bytes.
pub const SECTOR_SIZE: usize = 512;

/// Maximum chunk payload per BLK message. The IPC inline limit is 256
/// bytes; we leave headroom for both request and response headers so
/// the same value can be used on either side.
pub const MAX_CHUNK: usize = 224;

/// Operation codes. read_chunk / write_chunk transfer sub-sector
/// slices keyed by (sector, byte_offset, count) so a full 512-byte
/// sector takes ~3 round trips.
pub const BlkOp = enum(u8) {
    read_chunk = 1,
    write_chunk = 2,
    get_capacity = 3,
    ping = 255,
};

/// Block error codes (returned in BlkResponse.error_code).
pub const BlkError = enum(i32) {
    success = 0,
    bad_request = -1,
    io_error = -2,
    out_of_range = -3,
    not_ready = -4,
};

/// Request wire layout: [BlkRequest][optional write payload, ≤ MAX_CHUNK].
pub const BlkRequest = extern struct {
    op: u8,
    _pad: [3]u8 = .{ 0, 0, 0 },
    byte_offset: u32 = 0,
    count: u32 = 0,
    _pad2: u32 = 0,
    sector: u64 = 0,
};

/// Response wire layout: [BlkResponse][optional read payload, ≤ MAX_CHUNK].
pub const BlkResponse = extern struct {
    error_code: i32 = 0,
    size: u32 = 0,
};

/// Build a read_chunk request into `buf`.
pub fn buildReadRequest(buf: []u8, sector: u64, byte_offset: u32, count: u32) usize {
    const sz = @sizeOf(BlkRequest);
    if (buf.len < sz) return 0;
    const req: *BlkRequest = @ptrCast(@alignCast(buf.ptr));
    req.* = .{
        .op = @intFromEnum(BlkOp.read_chunk),
        .sector = sector,
        .byte_offset = byte_offset,
        .count = count,
    };
    return sz;
}

/// Build a write_chunk request (payload appended after header).
pub fn buildWriteRequest(buf: []u8, sector: u64, byte_offset: u32, data: []const u8) usize {
    const sz = @sizeOf(BlkRequest);
    if (data.len > MAX_CHUNK) return 0;
    if (buf.len < sz + data.len) return 0;
    const req: *BlkRequest = @ptrCast(@alignCast(buf.ptr));
    req.* = .{
        .op = @intFromEnum(BlkOp.write_chunk),
        .sector = sector,
        .byte_offset = byte_offset,
        .count = @intCast(data.len),
    };
    for (data, 0..) |b, i| buf[sz + i] = b;
    return sz + data.len;
}

/// Build a get_capacity request.
pub fn buildCapacityRequest(buf: []u8) usize {
    const sz = @sizeOf(BlkRequest);
    if (buf.len < sz) return 0;
    const req: *BlkRequest = @ptrCast(@alignCast(buf.ptr));
    req.* = .{ .op = @intFromEnum(BlkOp.get_capacity) };
    return sz;
}

/// Result of a block call.
pub const CallResult = struct {
    err: BlkError,
    payload: []const u8,
};

/// Send a block request to `slot` and wait for the reply.
pub fn callSlot(slot: u32, req: []const u8, reply_buf: []u8) CallResult {
    const ret = syscall.capCall(slot, req, reply_buf);
    if (ret < 0) return .{ .err = .io_error, .payload = &.{} };

    const reply_len: usize = @intCast(ret);
    const hdr_sz = @sizeOf(BlkResponse);
    if (reply_len < hdr_sz) return .{ .err = .io_error, .payload = &.{} };

    const hdr: *const BlkResponse = @ptrCast(@alignCast(reply_buf.ptr));
    const payload_end = @min(reply_len, hdr_sz + hdr.size);
    const payload = reply_buf[hdr_sz..payload_end];
    const err: BlkError = @enumFromInt(hdr.error_code);
    return .{ .err = err, .payload = payload };
}
