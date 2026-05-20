// Graphene virtio-blk Service - Block Device Driver
//
// User-space driver for QEMU's legacy/transitional virtio-blk-pci device
// (vendor 0x1AF4, device 0x1001). Uses I/O port BAR (BAR0) — the simpler
// of the two virtio transports — programmed via the io_port_read/write
// syscalls under an I/O port capability granted by the kernel.
//
// Capability slot layout (assigned by driver.registerPciDriver at boot):
//   slot 0 : IRQ capability (the device's INTx line)
//   slot 1 : MMIO BAR cap as MemoryObject (unused by legacy driver)
//   slot 2 : I/O port BAR cap (BAR0)
//   slot 4 : BLK service endpoint (HANDLE) — wired by main.zig
//
// Boot-time init:
//   1. Query BAR0 port base and IRQ number via cap_info.
//   2. dma_alloc one 16 KiB physically-contiguous DMA region.
//   3. Reset device, negotiate (no) features, set up virtqueue 0,
//      raise DRIVER_OK, read 64-bit capacity from config space.
//   4. Enter request loop on BLK_CAP_SLOT, serving read_sector,
//      write_sector, get_capacity, and ping.

const syscall = @import("syscall");
const blk = @import("blk");

// ---------------------------------------------------------------------------
// Capability slots in this process's cap table
// ---------------------------------------------------------------------------
const IRQ_CAP: u32 = 0;
const IOPORT_CAP: u32 = 2;
// BLK service endpoint slot from the shared blk module = 4.

// ---------------------------------------------------------------------------
// virtio-pci legacy I/O port register offsets (relative to BAR0 base)
// ---------------------------------------------------------------------------
const REG_DEVICE_FEATURES: u16 = 0x00;
const REG_DRIVER_FEATURES: u16 = 0x04;
const REG_QUEUE_ADDRESS: u16 = 0x08; // physical page number (paddr >> 12)
const REG_QUEUE_SIZE: u16 = 0x0C;
const REG_QUEUE_SELECT: u16 = 0x0E;
const REG_QUEUE_NOTIFY: u16 = 0x10;
const REG_DEVICE_STATUS: u16 = 0x12;
const REG_ISR_STATUS: u16 = 0x13;
const REG_CONFIG_CAPACITY_LO: u16 = 0x14; // device-specific: u64 capacity in 512-byte sectors
const REG_CONFIG_CAPACITY_HI: u16 = 0x18;

// Device status bits.
const STATUS_ACK: u8 = 0x01;
const STATUS_DRIVER: u8 = 0x02;
const STATUS_DRIVER_OK: u8 = 0x04;
const STATUS_FAILED: u8 = 0x80;

// Descriptor flags.
const DESC_NEXT: u16 = 0x1;
const DESC_WRITE: u16 = 0x2; // device writes to this buffer (host -> guest)

// virtio-blk request types.
const VIRTIO_BLK_T_IN: u32 = 0;
const VIRTIO_BLK_T_OUT: u32 = 1;

// ---------------------------------------------------------------------------
// Virtqueue layout. Legacy virtio mandates 4096-byte alignment between
// the avail and used rings. The exact offsets depend on the device-
// reported queue_size, so they are computed at init time (initDevice).
// We support any queue_size up to MAX_QSIZE.
// ---------------------------------------------------------------------------
const MAX_QSIZE: u16 = 256;

const DMA_VADDR: u64 = 0x20000000;
// 5 pages: 3 for the queue (worst case at MAX_QSIZE=256: 10246 bytes),
// plus room for the request header, status byte, and one-sector data buffer.
const DMA_SIZE: u64 = 5 * 4096;

// Virtqueue descriptor.
const Desc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};

// virtio_blk request header (16 bytes).
const BlkReqHeader = extern struct {
    typ: u32,
    reserved: u32,
    sector: u64,
};

// ---------------------------------------------------------------------------
// Driver state
// ---------------------------------------------------------------------------
var bar0_base: u16 = 0;
var dma_phys: u64 = 0;
var capacity_sectors: u64 = 0;
var last_used_idx: u16 = 0;
var qsize: u16 = 0;

// Runtime-computed layout offsets within the DMA region.
var desc_offset: u64 = 0;
var avail_offset: u64 = 0;
var used_offset: u64 = 0;
var req_hdr_offset: u64 = 0;
var status_offset: u64 = 0;
var data_offset: u64 = 0;

fn desc_at(i: u16) *Desc {
    return @ptrFromInt(DMA_VADDR + desc_offset + @as(u64, i) * @sizeOf(Desc));
}
fn avail_flags_ptr() *u16 {
    return @ptrFromInt(DMA_VADDR + avail_offset);
}
fn avail_idx_ptr() *u16 {
    return @ptrFromInt(DMA_VADDR + avail_offset + 2);
}
fn avail_ring_ptr(i: u16) *u16 {
    return @ptrFromInt(DMA_VADDR + avail_offset + 4 + @as(u64, i) * 2);
}
fn used_flags_ptr() *u16 {
    return @ptrFromInt(DMA_VADDR + used_offset);
}
fn used_idx_ptr() *u16 {
    return @ptrFromInt(DMA_VADDR + used_offset + 2);
}
fn req_hdr_ptr() *BlkReqHeader {
    return @ptrFromInt(DMA_VADDR + req_hdr_offset);
}
fn status_ptr() *u8 {
    return @ptrFromInt(DMA_VADDR + status_offset);
}
fn data_ptr() *[blk.SECTOR_SIZE]u8 {
    return @ptrFromInt(DMA_VADDR + data_offset);
}

// ---------------------------------------------------------------------------
// I/O port helpers (work in BAR-relative offsets)
// ---------------------------------------------------------------------------
fn ioRead8(off: u16) u8 {
    const r = syscall.ioPortRead(IOPORT_CAP, bar0_base + off, 1);
    return @truncate(@as(u64, @bitCast(r)));
}
fn ioRead16(off: u16) u16 {
    const r = syscall.ioPortRead(IOPORT_CAP, bar0_base + off, 2);
    return @truncate(@as(u64, @bitCast(r)));
}
fn ioRead32(off: u16) u32 {
    const r = syscall.ioPortRead(IOPORT_CAP, bar0_base + off, 4);
    return @truncate(@as(u64, @bitCast(r)));
}
fn ioWrite8(off: u16, v: u8) void {
    _ = syscall.ioPortWrite(IOPORT_CAP, bar0_base + off, v, 1);
}
fn ioWrite16(off: u16, v: u16) void {
    _ = syscall.ioPortWrite(IOPORT_CAP, bar0_base + off, v, 2);
}
fn ioWrite32(off: u16, v: u32) void {
    _ = syscall.ioPortWrite(IOPORT_CAP, bar0_base + off, v, 4);
}

// ---------------------------------------------------------------------------
// Initialisation
// ---------------------------------------------------------------------------
fn initDevice() bool {
    var info: syscall.CapInfoResult = undefined;

    if (syscall.capInfo(IOPORT_CAP, &info) != 0) {
        _ = syscall.debugPrint("[virtioblk] cap_info(IOPORT) failed\n");
        return false;
    }
    bar0_base = @truncate(info.addr);

    const phys = syscall.dmaAlloc(DMA_VADDR, DMA_SIZE);
    if (phys < 0) {
        _ = syscall.debugPrint("[virtioblk] dma_alloc failed\n");
        return false;
    }
    dma_phys = @intCast(phys);

    // Reset + negotiate. (1) status=0  (2) ACK  (3) ACK|DRIVER  (4) write 0
    // features  (5) program queue 0  (6) DRIVER_OK.
    ioWrite8(REG_DEVICE_STATUS, 0);
    ioWrite8(REG_DEVICE_STATUS, STATUS_ACK);
    ioWrite8(REG_DEVICE_STATUS, STATUS_ACK | STATUS_DRIVER);
    _ = ioRead32(REG_DEVICE_FEATURES); // ack but accept nothing
    ioWrite32(REG_DRIVER_FEATURES, 0);

    ioWrite16(REG_QUEUE_SELECT, 0);
    qsize = ioRead16(REG_QUEUE_SIZE);
    if (qsize == 0 or qsize > MAX_QSIZE) {
        _ = syscall.debugPrint("[virtioblk] unsupported queue size\n");
        ioWrite8(REG_DEVICE_STATUS, STATUS_FAILED);
        return false;
    }

    // Compute virtqueue layout from the device-reported queue size.
    // Legacy virtio: avail and used rings are separated by 4096-byte alignment.
    const desc_bytes: u64 = @as(u64, qsize) * 16;
    const avail_bytes: u64 = 6 + 2 * @as(u64, qsize);
    const used_bytes: u64 = 6 + 8 * @as(u64, qsize);

    desc_offset = 0;
    avail_offset = desc_bytes;
    used_offset = (desc_bytes + avail_bytes + 4095) & ~@as(u64, 4095);
    const queue_end = used_offset + used_bytes;

    req_hdr_offset = (queue_end + 15) & ~@as(u64, 15);
    status_offset = req_hdr_offset + 16;
    data_offset = (status_offset + 1 + 15) & ~@as(u64, 15);
    if (data_offset + blk.SECTOR_SIZE > DMA_SIZE) {
        _ = syscall.debugPrint("[virtioblk] DMA region too small\n");
        ioWrite8(REG_DEVICE_STATUS, STATUS_FAILED);
        return false;
    }

    // Program the queue's physical page number.
    const queue_phys = dma_phys + desc_offset;
    ioWrite32(REG_QUEUE_ADDRESS, @truncate(queue_phys >> 12));

    ioWrite8(REG_DEVICE_STATUS, STATUS_ACK | STATUS_DRIVER | STATUS_DRIVER_OK);

    // Read 64-bit capacity (sector count).
    const lo: u64 = ioRead32(REG_CONFIG_CAPACITY_LO);
    const hi: u64 = ioRead32(REG_CONFIG_CAPACITY_HI);
    capacity_sectors = (hi << 32) | lo;

    last_used_idx = used_idx_ptr().*;
    return true;
}

// ---------------------------------------------------------------------------
// Single in-flight request: build a 3-descriptor chain at slots 0/1/2,
// publish into avail ring, notify device, then wait on IRQ.
// ---------------------------------------------------------------------------
fn submitAndWait(req_type: u32, sector: u64, is_read: bool) bool {
    req_hdr_ptr().* = .{ .typ = req_type, .reserved = 0, .sector = sector };
    status_ptr().* = 0xFF; // sentinel — device should overwrite

    desc_at(0).* = .{
        .addr = dma_phys + req_hdr_offset,
        .len = @sizeOf(BlkReqHeader),
        .flags = DESC_NEXT,
        .next = 1,
    };
    var data_flags: u16 = DESC_NEXT;
    if (is_read) data_flags |= DESC_WRITE; // device writes the sector for us
    desc_at(1).* = .{
        .addr = dma_phys + data_offset,
        .len = blk.SECTOR_SIZE,
        .flags = data_flags,
        .next = 2,
    };
    desc_at(2).* = .{
        .addr = dma_phys + status_offset,
        .len = 1,
        .flags = DESC_WRITE,
        .next = 0,
    };

    // Publish desc index 0 into the avail ring.
    const avail_idx = avail_idx_ptr().*;
    avail_ring_ptr(avail_idx % qsize).* = 0;
    // x86 has strong store ordering; no fence needed before idx bump.
    avail_idx_ptr().* = avail_idx +% 1;

    // Kick the device. Queue index 0.
    ioWrite16(REG_QUEUE_NOTIFY, 0);

    // Wait for completion via IRQ. Drain ISR + advance used_idx.
    while (true) {
        _ = syscall.irqWait(IRQ_CAP);
        // Reading ISR clears the device's interrupt assertion.
        _ = ioRead8(REG_ISR_STATUS);
        _ = syscall.irqAck(IRQ_CAP);

        const cur = used_idx_ptr().*;
        if (cur != last_used_idx) {
            last_used_idx = cur;
            break;
        }
        // Spurious wakeup — keep waiting.
    }

    return status_ptr().* == 0;
}

// ---------------------------------------------------------------------------
// IPC request handling
// ---------------------------------------------------------------------------
fn handleRequest(req_data: []const u8, resp_data: []u8) usize {
    const hdr_sz = @sizeOf(blk.BlkResponse);
    const resp: *blk.BlkResponse = @ptrCast(@alignCast(resp_data.ptr));

    if (req_data.len < @sizeOf(blk.BlkRequest)) {
        resp.* = .{ .error_code = @intFromEnum(blk.BlkError.bad_request), .size = 0 };
        return hdr_sz;
    }
    const req: *const blk.BlkRequest = @ptrCast(@alignCast(req_data.ptr));
    const op: blk.BlkOp = @enumFromInt(req.op);

    switch (op) {
        .ping => {
            resp.* = .{ .error_code = 0, .size = 0 };
            return hdr_sz;
        },
        .get_capacity => {
            if (resp_data.len < hdr_sz + 8) {
                resp.* = .{ .error_code = @intFromEnum(blk.BlkError.bad_request), .size = 0 };
                return hdr_sz;
            }
            const out: *u64 = @ptrCast(@alignCast(resp_data[hdr_sz..].ptr));
            out.* = capacity_sectors;
            resp.* = .{ .error_code = 0, .size = 8 };
            return hdr_sz + 8;
        },
        .read_chunk => {
            if (req.sector >= capacity_sectors or
                req.byte_offset >= blk.SECTOR_SIZE or
                req.count == 0 or
                req.byte_offset + req.count > blk.SECTOR_SIZE or
                req.count > blk.MAX_CHUNK)
            {
                resp.* = .{ .error_code = @intFromEnum(blk.BlkError.out_of_range), .size = 0 };
                return hdr_sz;
            }
            if (!submitAndWait(VIRTIO_BLK_T_IN, req.sector, true)) {
                resp.* = .{ .error_code = @intFromEnum(blk.BlkError.io_error), .size = 0 };
                return hdr_sz;
            }
            const data = data_ptr();
            const out = resp_data[hdr_sz..];
            const n: u32 = @min(req.count, @as(u32, @intCast(out.len)));
            for (0..n) |i| out[i] = data[req.byte_offset + i];
            resp.* = .{ .error_code = 0, .size = n };
            return hdr_sz + n;
        },
        .write_chunk => {
            if (req.sector >= capacity_sectors or
                req.byte_offset >= blk.SECTOR_SIZE or
                req.count == 0 or
                req.byte_offset + req.count > blk.SECTOR_SIZE or
                req.count > blk.MAX_CHUNK)
            {
                resp.* = .{ .error_code = @intFromEnum(blk.BlkError.out_of_range), .size = 0 };
                return hdr_sz;
            }
            if (req_data.len < @sizeOf(blk.BlkRequest) + req.count) {
                resp.* = .{ .error_code = @intFromEnum(blk.BlkError.bad_request), .size = 0 };
                return hdr_sz;
            }

            // Read-modify-write the sector.
            if (!submitAndWait(VIRTIO_BLK_T_IN, req.sector, true)) {
                resp.* = .{ .error_code = @intFromEnum(blk.BlkError.io_error), .size = 0 };
                return hdr_sz;
            }
            const data = data_ptr();
            const payload = req_data[@sizeOf(blk.BlkRequest)..];
            for (0..req.count) |i| data[req.byte_offset + i] = payload[i];
            if (!submitAndWait(VIRTIO_BLK_T_OUT, req.sector, false)) {
                resp.* = .{ .error_code = @intFromEnum(blk.BlkError.io_error), .size = 0 };
                return hdr_sz;
            }
            resp.* = .{ .error_code = 0, .size = req.count };
            return hdr_sz;
        },
    }
}

// ---------------------------------------------------------------------------
// Entry
// ---------------------------------------------------------------------------
pub fn main() i32 {
    _ = syscall.debugPrint("[virtioblk] starting...\n");

    if (!initDevice()) {
        _ = syscall.debugPrint("[virtioblk] init failed\n");
        return 1;
    }
    _ = syscall.debugPrint("[virtioblk] device ready\n");

    var req_buf: [blk.SECTOR_SIZE + 64]u8 = undefined;
    var resp_buf: [blk.SECTOR_SIZE + 64]u8 = undefined;

    while (true) {
        const recv_len = syscall.capRecv(4, &req_buf, req_buf.len);
        if (recv_len < 0) {
            syscall.threadYield();
            continue;
        }
        const req_slice = req_buf[0..@intCast(recv_len)];
        const resp_len = handleRequest(req_slice, &resp_buf);
        _ = syscall.capSend(4, &resp_buf, resp_len);
    }
    return 0;
}
