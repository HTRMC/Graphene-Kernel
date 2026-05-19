// Graphene Devfs Service - Device Filesystem Server
// User-space VFS server exposing virtual device files. Speaks the same
// VFS protocol as ramfs but on the DEVFS capability slot.
//
//   null    - writes discarded, reads return EOF
//   zero    - reads return zero bytes, writes discarded
//   console - writes forwarded to the kernel debug console

const syscall = @import("syscall");
const vfs = @import("vfs");

const DevKind = enum(u8) {
    null_dev = 1,
    zero_dev = 2,
    console_dev = 3,
};

const DevFile = struct {
    name: []const u8,
    kind: DevKind,
};

const devices = [_]DevFile{
    .{ .name = "null", .kind = .null_dev },
    .{ .name = "zero", .kind = .zero_dev },
    .{ .name = "console", .kind = .console_dev },
};

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (ac != bc) return false;
    }
    return true;
}

fn findDev(name: []const u8) ?DevKind {
    for (devices) |d| {
        if (strEql(d.name, name)) return d.kind;
    }
    return null;
}

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
        .create, .mkdir, .delete => {
            // Devfs is read-only in terms of namespace.
            resp.* = .{ .error_code = @intFromEnum(vfs.FsError.permission), .size = 0 };
            return hdr_sz;
        },
        .stat => {
            if (findDev(name) != null) {
                resp.* = .{ .error_code = 0, .size = @sizeOf(vfs.FileStat) };
                if (resp_payload.len >= @sizeOf(vfs.FileStat)) {
                    const stat: *vfs.FileStat = @ptrCast(@alignCast(resp_payload.ptr));
                    stat.size = 0;
                    stat.file_type = @intFromEnum(vfs.FileType.regular);
                    stat._pad = .{ 0, 0, 0 };
                }
                return hdr_sz + @sizeOf(vfs.FileStat);
            }
            resp.* = .{ .error_code = @intFromEnum(vfs.FsError.not_found), .size = 0 };
            return hdr_sz;
        },
        .open => {
            if (findDev(name)) |kind| {
                resp.* = .{ .error_code = 0, .size = 4 };
                if (resp_payload.len >= 4) {
                    resp_payload[0] = @intFromEnum(kind);
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
            resp.* = .{ .error_code = 0, .size = 0 };
            return hdr_sz;
        },
        .read => {
            const kind = findDev(name) orelse {
                resp.* = .{ .error_code = @intFromEnum(vfs.FsError.not_found), .size = 0 };
                return hdr_sz;
            };
            switch (kind) {
                .null_dev, .console_dev => {
                    // EOF
                    resp.* = .{ .error_code = 0, .size = 0 };
                    return hdr_sz;
                },
                .zero_dev => {
                    const max_read = @min(req.size, @as(u32, @intCast(resp_payload.len)));
                    for (0..max_read) |i| resp_payload[i] = 0;
                    resp.* = .{ .error_code = 0, .size = max_read };
                    return hdr_sz + max_read;
                },
            }
        },
        .write => {
            const kind = findDev(name) orelse {
                resp.* = .{ .error_code = @intFromEnum(vfs.FsError.not_found), .size = 0 };
                return hdr_sz;
            };
            switch (kind) {
                .null_dev, .zero_dev => {
                    // Discard
                    resp.* = .{ .error_code = 0, .size = @intCast(data.len) };
                    return hdr_sz;
                },
                .console_dev => {
                    if (data.len > 0) {
                        _ = syscall.debugPrint(data);
                    }
                    resp.* = .{ .error_code = 0, .size = @intCast(data.len) };
                    return hdr_sz;
                },
            }
        },
        .readdir => {
            var count: i32 = 0;
            var pos: usize = 0;
            for (devices) |d| {
                const name_len: u8 = @intCast(d.name.len);
                if (pos + 2 + name_len <= resp_payload.len) {
                    resp_payload[pos] = name_len;
                    resp_payload[pos + 1] = @intFromEnum(vfs.FileType.regular);
                    for (0..name_len) |k| resp_payload[pos + 2 + k] = d.name[k];
                    pos += 2 + name_len;
                    count += 1;
                }
            }
            resp.* = .{ .error_code = count, .size = @intCast(pos) };
            return hdr_sz + pos;
        },
    }
}

pub fn main() i32 {
    _ = syscall.debugPrint("[devfs] Device filesystem service starting...\n");
    _ = syscall.debugPrint("[devfs] Listening on DEVFS endpoint (slot 3)...\n");

    var req_buf: [vfs.MAX_MSG_DATA]u8 = undefined;
    var resp_buf: [vfs.MAX_MSG_DATA]u8 = undefined;

    while (true) {
        const recv_len = syscall.capRecv(vfs.DEVFS_CAP_SLOT, &req_buf, req_buf.len);
        if (recv_len < 0) {
            syscall.threadYield();
            continue;
        }

        const req_slice = req_buf[0..@intCast(recv_len)];
        const resp_len = handleRequest(req_slice, &resp_buf);

        _ = syscall.capSend(vfs.DEVFS_CAP_SLOT, &resp_buf, resp_len);
    }

    return 0;
}
