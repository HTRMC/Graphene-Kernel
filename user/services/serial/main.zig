// Graphene serial service — user-space 16550 UART driver
//
// Owns COM1 (IRQ 4, ports 0x3F8..0x3FF) and bridges it to the rest of
// the system:
//
//   UART RX  --capSend(.tty_input)-->  tty.inq  --read-->  shell
//   shell    --write--> tty  --capSend(.write)-->  serial  --UART TX
//
// The kernel's serial.zig is still alive for early boot klog before
// this service is scheduled; once user space is up, all UART traffic
// flows through here.
//
// Cap slot layout:
//   slot 0  IRQ 4 (HANDLE)         — granted by registerDriver
//   slot 1  IOPORTs 0x3F8..0x3FF   — granted by registerDriver
//   slot 6  TTY endpoint (SEND)    — granted by boot wiring
//   slot 9  SERIAL endpoint (HANDLE, async) — granted by boot wiring
//
// Main loop is poll-driven because we cannot block on both an IRQ and
// an IPC endpoint simultaneously (no thread_create yet). UART RX is
// fast enough (115200 baud) that a yield-when-idle poll keeps the FIFO
// drained, and TX is non-blocking from tty's side anyway.

const syscall = @import("syscall");
const vfs = @import("vfs");

pub const proc_name: []const u8 = "serial";

// Capability slots
const IRQ_CAP: u32 = 0; // IRQ 4
const IOPORT_CAP: u32 = 1; // 0x3F8..0x3FF
const TTY_INPUT_CAP: u32 = vfs.TTY_INPUT_SLOT; // SEND on async tty-input endpoint
const SERIAL_CAP: u32 = vfs.SERIAL_CAP_SLOT; // HANDLE for incoming .write

// 16550 UART register offsets from COM1 base
const COM1_BASE: u16 = 0x3F8;
const DATA_REG: u16 = COM1_BASE + 0;
const INT_ENABLE: u16 = COM1_BASE + 1;
const LINE_STATUS: u16 = COM1_BASE + 5;

const LSR_DATA_READY: u8 = 0x01;
const LSR_THRE: u8 = 0x20; // Transmitter Holding Register Empty

// IER bits (we only care about ERBFI = "Enable Received Data Available
// Interrupt"). The kernel UART init disabled all UART IRQs; we re-enable
// just RX so the IRQ object becomes useful for future thread-aware
// designs. For now we still poll, so this is harmless.
const IER_ERBFI: u8 = 0x01;

inline fn portRead(port: u16) u8 {
    const r = syscall.ioPortRead(IOPORT_CAP, port, 1);
    if (r < 0) return 0;
    return @truncate(@as(u64, @bitCast(r)));
}

inline fn portWrite(port: u16, value: u8) void {
    _ = syscall.ioPortWrite(IOPORT_CAP, port, value, 1);
}

/// Push a batch of received bytes to the tty input queue as a single
/// `.tty_input` VFS request. Batching matters because the async input
/// endpoint's pending ring is bounded at MAX_PENDING_MESSAGES; one
/// byte per message would let a 43-byte fixture overflow the ring.
fn pushBatchToTty(bytes: []const u8) void {
    if (bytes.len == 0) return;
    var buf: [vfs.MAX_MSG_DATA]u8 = undefined;
    const hdr: *vfs.RequestHeader = @ptrCast(@alignCast(&buf));
    hdr.* = .{
        .op = @intFromEnum(vfs.FsOp.tty_input),
        .flags = 0,
        .name_len = 0,
        ._pad = 0,
        .offset = 0,
        .size = @intCast(bytes.len),
    };
    for (bytes, 0..) |b, i| buf[@sizeOf(vfs.RequestHeader) + i] = b;
    _ = syscall.capSend(TTY_INPUT_CAP, &buf, @sizeOf(vfs.RequestHeader) + bytes.len);
}

/// Drain whatever bytes the UART RX FIFO currently holds. Translates
/// terminal-shaped input so the shell's existing readLine works without
/// changes: CR -> LF, DEL -> BS. Coalesces into a single capSend.
fn drainRx() void {
    var batch: [128]u8 = undefined;
    var n: usize = 0;
    while (n < batch.len) {
        const lsr = portRead(LINE_STATUS);
        if ((lsr & LSR_DATA_READY) == 0) break;
        var b = portRead(DATA_REG);
        if (b == '\r') b = '\n';
        if (b == 0x7F) b = 0x08;
        batch[n] = b;
        n += 1;
    }
    if (n > 0) pushBatchToTty(batch[0..n]);
}

/// Write a single byte to the UART TX (polled). At 115200 baud one byte
/// takes ~87us; the LSR_THRE wait is bounded.
fn uartPutByte(b: u8) void {
    var guard: u32 = 0;
    while (guard < 100_000) : (guard += 1) {
        const lsr = portRead(LINE_STATUS);
        if ((lsr & LSR_THRE) != 0) break;
    }
    portWrite(DATA_REG, b);
}

/// Handle one .write request: dump bytes onto the UART TX.
fn handleWrite(req: []const u8) void {
    if (req.len < @sizeOf(vfs.RequestHeader)) return;
    const hdr: *const vfs.RequestHeader = @ptrCast(@alignCast(req.ptr));
    const data_off = @sizeOf(vfs.RequestHeader) + hdr.name_len;
    if (req.len <= data_off) return;
    const data = req[data_off..];
    for (data) |c| uartPutByte(c);
}

/// Drain any queued .write requests from the SERIAL endpoint. Returns
/// true if at least one message was processed.
fn drainTx() bool {
    var any = false;
    var msg_buf: [vfs.MAX_MSG_DATA]u8 = undefined;
    while (true) {
        const n = syscall.capTryRecv(SERIAL_CAP, &msg_buf, msg_buf.len);
        if (n < 0) break; // would_block or error -> stop draining
        any = true;
        if (n == 0) continue;
        const ulen: usize = @intCast(n);
        if (ulen <= msg_buf.len and ulen >= @sizeOf(vfs.RequestHeader)) {
            // Match the op byte directly so an unexpected value can't
            // panic via @enumFromInt.
            if (msg_buf[0] == @intFromEnum(vfs.FsOp.write)) {
                handleWrite(msg_buf[0..ulen]);
            }
        }
    }
    return any;
}

pub fn main() i32 {
    syscall.klogStr("[serial] starting...\n");

    // Re-enable UART RX IRQ so future IRQ-aware designs can use IRQ_CAP.
    // Polling still drives the data path today.
    portWrite(INT_ENABLE, IER_ERBFI);
    _ = syscall.irqAck(IRQ_CAP); // unmask in PIC

    syscall.klogStr("[serial] COM1 ready, polling\n");

    while (true) {
        const tx_did = drainTx();
        const lsr = portRead(LINE_STATUS);
        const rx_did = (lsr & LSR_DATA_READY) != 0;
        if (rx_did) drainRx();
        if (!tx_did and !rx_did) {
            syscall.threadYield();
        }
    }
}
