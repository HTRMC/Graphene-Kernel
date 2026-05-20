// Graphene tty Service — user-space terminal
//
// Owns the framebuffer (mapped from a kernel-granted MemoryObject cap)
// and the keyboard input queue. Speaks the VFS protocol on
// TTY_CAP_SLOT (slot 6) with one extra op, FsOp.tty_input, used by the
// kbd driver to push scancode-translated characters into the queue.
//
// Cap slot layout in this process's table:
//   slot 6  HANDLE on TTY endpoint  (set up by boot wiring)
//   slot 7  MemoryObject on the framebuffer (granted by boot)
//
// Reads are non-blocking from tty's side: if the input queue is empty
// we reply with size=0 immediately. The shell loops with threadYield
// between empty reads, which is the same shape as a busy-poll select
// on a hosted OS. Avoiding the two-recv "deferred reply" pattern keeps
// the IPC recv_queue uncontested — single-threaded services should
// only ever park inside one capRecv at a time.

const syscall = @import("syscall");
const vfs = @import("vfs");
const font_data = @import("font").font;

pub const proc_name: []const u8 = "tty";

const TTY_CAP: u32 = vfs.TTY_CAP_SLOT;
const FB_CAP: u32 = 7;
const SERIAL_CAP: u32 = vfs.SERIAL_CAP_SLOT;
const INPUT_CAP: u32 = vfs.TTY_INPUT_SLOT;

/// Mirror writes to the serial service. Set false to disable the
/// fan-out for performance-sensitive demos. Default-on per the goal.
var serial_mirror_enabled: bool = true;

const FB_VADDR: u64 = 0x30000000;
const GLYPH_W: u32 = 8;
const GLYPH_H: u32 = 16;
const FG: u32 = 0x00FFFFFF;
const BG: u32 = 0x001A1A2E;
const STATUS_FG: u32 = 0x00808080;

var fb_ptr: [*]u32 = undefined;
var fb_w: u32 = 0;
var fb_h: u32 = 0;
var fb_pitch_px: u32 = 0;
var cols: u32 = 0;
var rows: u32 = 0;
var cur_col: u32 = 0;
var cur_row: u32 = 0;

// Circular input queue. ASCII bytes pushed by kbd's tty_input op.
const INQ_SIZE: usize = 512;
var inq: [INQ_SIZE]u8 = undefined;
var inq_head: usize = 0;
var inq_tail: usize = 0;

inline fn inqEmpty() bool {
    return inq_head == inq_tail;
}
inline fn inqFull() bool {
    return ((inq_tail + 1) % INQ_SIZE) == inq_head;
}
fn inqPush(b: u8) void {
    if (inqFull()) return;
    inq[inq_tail] = b;
    inq_tail = (inq_tail + 1) % INQ_SIZE;
}
fn inqPop() ?u8 {
    if (inqEmpty()) return null;
    const b = inq[inq_head];
    inq_head = (inq_head + 1) % INQ_SIZE;
    return b;
}

// ---------------------------------------------------------------------------
// Framebuffer drawing
// ---------------------------------------------------------------------------
fn putPixel(x: u32, y: u32, color: u32) void {
    if (x >= fb_w or y >= fb_h) return;
    fb_ptr[y * fb_pitch_px + x] = color;
}

fn drawGlyph(c: u8, col: u32, row: u32) void {
    const x0 = col * GLYPH_W;
    const y0 = row * GLYPH_H;
    if (c < 32 or c > 126) {
        // Treat unprintable as space — paint the cell background.
        var ry: u32 = 0;
        while (ry < GLYPH_H) : (ry += 1) {
            var rx: u32 = 0;
            while (rx < GLYPH_W) : (rx += 1) putPixel(x0 + rx, y0 + ry, BG);
        }
        return;
    }
    const glyph = font_data[c - 32];
    var ry: u32 = 0;
    while (ry < GLYPH_H) : (ry += 1) {
        const row_bits = glyph[ry];
        var rx: u32 = 0;
        while (rx < GLYPH_W) : (rx += 1) {
            const on = ((row_bits >> @intCast(7 - rx)) & 1) == 1;
            putPixel(x0 + rx, y0 + ry, if (on) FG else BG);
        }
    }
}

fn clearScreen() void {
    var i: u32 = 0;
    const total = fb_pitch_px * fb_h;
    while (i < total) : (i += 1) fb_ptr[i] = BG;
}

fn scrollOneRow() void {
    const src_off = GLYPH_H * fb_pitch_px;
    const last_row_y = fb_h - GLYPH_H;

    var y: u32 = 0;
    while (y < last_row_y) : (y += 1) {
        var x: u32 = 0;
        while (x < fb_w) : (x += 1) {
            fb_ptr[y * fb_pitch_px + x] = fb_ptr[y * fb_pitch_px + x + src_off];
        }
    }
    // Clear the now-uncovered bottom row.
    while (y < fb_h) : (y += 1) {
        var x: u32 = 0;
        while (x < fb_w) : (x += 1) fb_ptr[y * fb_pitch_px + x] = BG;
    }
}

fn newline() void {
    cur_col = 0;
    cur_row += 1;
    if (cur_row >= rows) {
        scrollOneRow();
        cur_row = rows - 1;
    }
}

fn putc(c: u8) void {
    switch (c) {
        '\n' => newline(),
        '\r' => cur_col = 0,
        8 => { // backspace
            if (cur_col > 0) {
                cur_col -= 1;
                drawGlyph(' ', cur_col, cur_row);
            }
        },
        '\t' => {
            // 4-column tab
            var i: u32 = 0;
            while (i < 4) : (i += 1) putc(' ');
        },
        else => {
            drawGlyph(c, cur_col, cur_row);
            cur_col += 1;
            if (cur_col >= cols) newline();
        },
    }
}

fn writeBytes(data: []const u8) void {
    for (data) |c| putc(c);
    if (serial_mirror_enabled and data.len > 0) mirrorToSerial(data);
}

/// Forward a slice of output bytes to the serial service via a .write
/// VFS op. Best-effort: SERIAL_CAP is async-mode, so capSend just
/// enqueues and never blocks; if the cap is missing (boot order race
/// or testing with serial disabled), capSend returns negative and we
/// disable the mirror so subsequent writes don't keep paying the cost.
fn mirrorToSerial(data: []const u8) void {
    const hdr_sz = @sizeOf(vfs.RequestHeader);
    const max_data = vfs.MAX_MSG_DATA - hdr_sz;
    var off: usize = 0;
    while (off < data.len) {
        const chunk_len = @min(max_data, data.len - off);
        var buf: [vfs.MAX_MSG_DATA]u8 = undefined;
        const hdr: *vfs.RequestHeader = @ptrCast(@alignCast(&buf));
        hdr.* = .{
            .op = @intFromEnum(vfs.FsOp.write),
            .flags = 0,
            .name_len = 0,
            ._pad = 0,
            .offset = 0,
            .size = @intCast(chunk_len),
        };
        for (0..chunk_len) |i| buf[hdr_sz + i] = data[off + i];
        const r = syscall.capSend(SERIAL_CAP, &buf, hdr_sz + chunk_len);
        if (r < 0) {
            // -2 invalid_capability or -7 not_found = mirror not wired
            // yet; permanently disable so we don't spam syscalls.
            if (r == -2 or r == -7) serial_mirror_enabled = false;
            return;
        }
        off += chunk_len;
    }
}

// ---------------------------------------------------------------------------
// Mount: query geometry, map framebuffer, paint background.
// ---------------------------------------------------------------------------
fn mount() bool {
    var info: syscall.FbInfoResult = undefined;
    if (syscall.fbInfo(&info) != 0) {
        _ = syscall.klog("[tty] fb_info failed\n");
        return false;
    }
    fb_w = info.width;
    fb_h = info.height;
    fb_pitch_px = info.pitch_bytes / 4;
    if (fb_pitch_px == 0 or fb_w == 0 or fb_h == 0) {
        _ = syscall.klog("[tty] bad framebuffer geometry\n");
        return false;
    }
    cols = fb_w / GLYPH_W;
    rows = fb_h / GLYPH_H;

    // Map the framebuffer with READ|WRITE rights.
    const MAP_RW: u64 = (1 << 0) | (1 << 1);
    const r = syscall.memMap(FB_CAP, FB_VADDR, info.size, MAP_RW);
    if (r != 0) {
        _ = syscall.klog("[tty] mem_map framebuffer failed\n");
        return false;
    }
    fb_ptr = @ptrFromInt(FB_VADDR);
    clearScreen();
    return true;
}

// ---------------------------------------------------------------------------
// Request handling
// ---------------------------------------------------------------------------
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

    const data_offset = @sizeOf(vfs.RequestHeader) + req.name_len;
    var data: []const u8 = &.{};
    if (req_data.len > data_offset) data = req_data[data_offset..];

    switch (op) {
        .ping => {
            resp.* = .{ .error_code = 0, .size = 0 };
            return hdr_sz;
        },
        .write => {
            writeBytes(data);
            resp.* = .{ .error_code = 0, .size = @intCast(data.len) };
            return hdr_sz;
        },
        .read => {
            // Non-blocking: if queue empty, reply with size=0 and let
            // the caller decide to retry. See deferred-reply note in
            // the file header for why we don't park reads.
            const want = @min(req.size, @as(u32, @intCast(resp_payload.len)));
            var n: u32 = 0;
            while (n < want) {
                const b = inqPop() orelse break;
                resp_payload[n] = b;
                n += 1;
            }
            resp.* = .{ .error_code = 0, .size = n };
            return hdr_sz + n;
        },
        .tty_input => {
            // Fire-and-forget: callers (kbd, serial) use capSend and do
            // not wait for a reply. Return 0 to signal the main loop
            // not to send anything back — keeps the endpoint's send_queue
            // clear and avoids any "stale reply" race vs shell's capCall.
            for (data) |c| inqPush(c);
            return 0;
        },
        .stat => {
            resp.* = .{ .error_code = 0, .size = @sizeOf(vfs.FileStat) };
            if (resp_payload.len >= @sizeOf(vfs.FileStat)) {
                const stat: *vfs.FileStat = @ptrCast(@alignCast(resp_payload.ptr));
                stat.size = 0;
                stat.file_type = @intFromEnum(vfs.FileType.regular);
                stat._pad = .{ 0, 0, 0 };
            }
            return hdr_sz + @sizeOf(vfs.FileStat);
        },
        .open, .close => {
            resp.* = .{ .error_code = 0, .size = 0 };
            return hdr_sz;
        },
        .create, .delete, .mkdir, .readdir => {
            resp.* = .{ .error_code = @intFromEnum(vfs.FsError.permission), .size = 0 };
            return hdr_sz;
        },
    }
}

/// Pull every queued `.tty_input` off the async input endpoint and
/// enqueue the bytes into our input ring. kbd and serial both push
/// here via capSend; we drain on each main-loop iteration so the bytes
/// are visible the next time shell asks for a `.read`.
fn drainInput() void {
    var buf: [vfs.MAX_MSG_DATA]u8 = undefined;
    while (true) {
        const n = syscall.capTryRecv(INPUT_CAP, &buf, buf.len);
        if (n < 0) return;
        if (n == 0) continue;
        const ulen: usize = @intCast(n);
        if (ulen < @sizeOf(vfs.RequestHeader)) continue;
        const hdr: *const vfs.RequestHeader = @ptrCast(@alignCast(&buf));
        // Only honor `.tty_input` requests; ignore any unexpected op
        // rather than panicking via @enumFromInt.
        if (hdr.op != @intFromEnum(vfs.FsOp.tty_input)) continue;
        const data_off = @sizeOf(vfs.RequestHeader) + hdr.name_len;
        if (ulen <= data_off) continue;
        for (buf[data_off..ulen]) |c| inqPush(c);
    }
}

pub fn main() i32 {
    _ = syscall.klog("[tty] starting...\n");
    if (!mount()) return 1;
    _ = syscall.klog("[tty] framebuffer mapped, ready\n");

    var req_buf: [vfs.MAX_MSG_DATA]u8 = undefined;
    var resp_buf: [vfs.MAX_MSG_DATA]u8 = undefined;

    while (true) {
        // Pull any pending input bytes before parking on TTY_CAP so
        // shell's next .read sees fresh data with no extra round-trip.
        drainInput();

        const recv_len = syscall.capRecv(TTY_CAP, &req_buf, req_buf.len);
        if (recv_len < 0) {
            syscall.threadYield();
            continue;
        }
        const req_slice = req_buf[0..@intCast(recv_len)];
        // Drain again after waking — between the previous drain and
        // now, kbd or serial may have queued more bytes that the
        // pending .read should be able to observe.
        drainInput();
        const resp_len = handleRequest(req_slice, &resp_buf);
        if (resp_len > 0) {
            _ = syscall.capSend(TTY_CAP, &resp_buf, resp_len);
        }
    }
}
