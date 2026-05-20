// Graphene Logger Service — user-space text-logging server.
// Receives raw byte payloads on the well-known log endpoint and forwards
// them to the kernel debug console. Demonstrates a second user-space
// service running alongside ramfs, talking to clients purely via IPC.

const syscall = @import("syscall");
const log = @import("log");

const PREFIX = "[log] ";

pub fn main() i32 {
    _ = syscall.klog("[logger] service starting on slot 2\n");

    var req_buf: [log.MAX_LOG_MSG + 16]u8 = undefined;
    var reply_buf: [8]u8 = undefined;
    const reply_payload: *i32 = @ptrCast(@alignCast(&reply_buf));

    while (true) {
        const recv_len = syscall.capRecv(log.LOG_CAP_SLOT, &req_buf, req_buf.len);
        if (recv_len < 0) {
            syscall.threadYield();
            continue;
        }

        const len: usize = @intCast(recv_len);
        if (len > 0) {
            _ = syscall.klog(PREFIX);
            _ = syscall.klog(req_buf[0..len]);
            // Newline if caller didn't include one
            if (req_buf[len - 1] != '\n') {
                _ = syscall.klog("\n");
            }
        }

        reply_payload.* = @intCast(len);
        _ = syscall.capSend(log.LOG_CAP_SLOT, &reply_buf, @sizeOf(i32));
    }
}
