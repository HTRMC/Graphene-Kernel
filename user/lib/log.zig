// Graphene Logger Protocol — minimal text-logging service over IPC.
// Wire format: request body is the raw bytes to log. Reply is one
// little-endian i32 (bytes written, or negative error).

const syscall = @import("syscall");

/// Well-known capability slot where the kernel injects the logger
/// endpoint. Server (logger service) gets HANDLE, clients get SEND.
pub const LOG_CAP_SLOT: u32 = 2;

/// Maximum bytes a client can log in a single call.
pub const MAX_LOG_MSG: usize = 240;

/// Log a string. Returns bytes written on success, or a negative
/// syscall error.
pub fn log(msg: []const u8) i64 {
    if (msg.len > MAX_LOG_MSG) return -1;
    var reply: [8]u8 = undefined;
    const ret = syscall.capCall(LOG_CAP_SLOT, msg, reply[0..]);
    if (ret < @as(i64, @sizeOf(i32))) return ret;
    const payload: *const i32 = @ptrCast(@alignCast(&reply));
    return @as(i64, payload.*);
}
