// Graphene Kernel - PCI Bus Enumeration
// Scans the PCI configuration space via the legacy 0xCF8/0xCFC ports.
// Bus 0 only for now; that covers everything QEMU exposes by default,
// including virtio devices (vendor 0x1AF4).

const serial = @import("serial.zig");

/// Configuration space access ports.
const CONFIG_ADDRESS: u16 = 0xCF8;
const CONFIG_DATA: u16 = 0xCFC;

/// PCI configuration space register offsets.
const REG_VENDOR_ID: u8 = 0x00;
const REG_DEVICE_ID: u8 = 0x02;
const REG_COMMAND: u8 = 0x04;
const REG_REVISION: u8 = 0x08;
const REG_PROG_IF: u8 = 0x09;
const REG_SUBCLASS: u8 = 0x0A;
const REG_CLASS: u8 = 0x0B;
const REG_HEADER_TYPE: u8 = 0x0E;
const REG_BAR0: u8 = 0x10;
const REG_INTERRUPT_LINE: u8 = 0x3C;

/// Vendor/device IDs of interest.
pub const VIRTIO_VENDOR: u16 = 0x1AF4;
pub const VIRTIO_BLK_DEVICE_LEGACY: u16 = 0x1001;
pub const VIRTIO_BLK_DEVICE_MODERN: u16 = 0x1042;

/// Single Base Address Register.
pub const Bar = struct {
    /// Physical base address (for memory BARs) or I/O port base (for I/O BARs).
    base: u64 = 0,
    /// Size in bytes (0 if BAR slot unused).
    size: u64 = 0,
    /// True if this is a memory-mapped BAR; false for I/O port BAR.
    is_mmio: bool = false,
    /// True for 64-bit MMIO BAR (consumes two consecutive BAR slots).
    is_64bit: bool = false,
    /// True if MMIO region is marked prefetchable.
    prefetchable: bool = false,
};

/// A discovered PCI device on bus 0.
pub const Device = struct {
    bus: u8 = 0,
    slot: u8 = 0,
    func: u8 = 0,
    vendor_id: u16 = 0,
    device_id: u16 = 0,
    class: u8 = 0,
    subclass: u8 = 0,
    prog_if: u8 = 0,
    header_type: u8 = 0,
    irq_line: u8 = 0,
    bars: [6]Bar = [_]Bar{.{}} ** 6,

    pub fn isValid(self: *const Device) bool {
        return self.vendor_id != 0 and self.vendor_id != 0xFFFF;
    }

    /// First MMIO BAR (or null if none).
    pub fn mmioBar(self: *const Device) ?*const Bar {
        for (&self.bars) |*b| {
            if (b.size != 0 and b.is_mmio) return b;
        }
        return null;
    }

    /// First I/O port BAR (or null if none).
    pub fn ioBar(self: *const Device) ?*const Bar {
        for (&self.bars) |*b| {
            if (b.size != 0 and !b.is_mmio) return b;
        }
        return null;
    }
};

const MAX_DEVICES: usize = 32;
var devices: [MAX_DEVICES]Device = [_]Device{.{}} ** MAX_DEVICES;
var device_count: usize = 0;
var initialized: bool = false;

// ---------------------------------------------------------------------------
// Low-level I/O
// ---------------------------------------------------------------------------

fn outl(port: u16, value: u32) void {
    asm volatile ("outl %[value], %[port]"
        :
        : [value] "{eax}" (value),
          [port] "{dx}" (port),
    );
}

fn inl(port: u16) u32 {
    return asm volatile ("inl %[port], %[result]"
        : [result] "={eax}" (-> u32),
        : [port] "{dx}" (port),
    );
}

fn makeAddress(bus: u8, slot: u8, func: u8, offset: u8) u32 {
    // Bit 31 = enable; offset is aligned to 4 bytes.
    return 0x80000000 |
        (@as(u32, bus) << 16) |
        (@as(u32, slot) << 11) |
        (@as(u32, func) << 8) |
        (@as(u32, offset) & 0xFC);
}

/// Read 32 bits from configuration space.
pub fn configRead32(bus: u8, slot: u8, func: u8, offset: u8) u32 {
    outl(CONFIG_ADDRESS, makeAddress(bus, slot, func, offset));
    return inl(CONFIG_DATA);
}

/// Write 32 bits to configuration space.
pub fn configWrite32(bus: u8, slot: u8, func: u8, offset: u8, value: u32) void {
    outl(CONFIG_ADDRESS, makeAddress(bus, slot, func, offset));
    outl(CONFIG_DATA, value);
}

pub fn configRead16(bus: u8, slot: u8, func: u8, offset: u8) u16 {
    const word = configRead32(bus, slot, func, offset & 0xFC);
    const shift: u5 = @intCast((offset & 0x2) * 8);
    return @truncate(word >> shift);
}

pub fn configRead8(bus: u8, slot: u8, func: u8, offset: u8) u8 {
    const word = configRead32(bus, slot, func, offset & 0xFC);
    const shift: u5 = @intCast((offset & 0x3) * 8);
    return @truncate(word >> shift);
}

// ---------------------------------------------------------------------------
// Enumeration
// ---------------------------------------------------------------------------

/// Probe and size BARs for a type-0 header device. Reads up to 6 BARs;
/// 64-bit MMIO BARs consume two slots, with the second left zeroed.
fn probeBars(dev: *Device) void {
    var i: u8 = 0;
    while (i < 6) : (i += 1) {
        const offset: u8 = REG_BAR0 + i * 4;
        const original = configRead32(dev.bus, dev.slot, dev.func, offset);
        if (original == 0) continue;

        // Size: write all 1s, read back, restore.
        configWrite32(dev.bus, dev.slot, dev.func, offset, 0xFFFFFFFF);
        const probed = configRead32(dev.bus, dev.slot, dev.func, offset);
        configWrite32(dev.bus, dev.slot, dev.func, offset, original);

        if (probed == 0) continue;

        const is_io = (original & 0x1) != 0;
        var bar = &dev.bars[i];

        if (is_io) {
            const mask: u32 = 0xFFFFFFFC;
            const base: u32 = original & mask;
            const size_bits: u32 = probed & mask;
            bar.base = base;
            bar.size = (~@as(u64, size_bits) + 1) & 0xFFFFFFFF;
            bar.is_mmio = false;
            bar.is_64bit = false;
            bar.prefetchable = false;
        } else {
            const mem_type: u8 = @truncate((original >> 1) & 0x3);
            const prefetchable = (original & 0x8) != 0;
            const mask: u32 = 0xFFFFFFF0;
            const lo_base: u32 = original & mask;
            const lo_size_bits: u32 = probed & mask;

            bar.is_mmio = true;
            bar.prefetchable = prefetchable;

            if (mem_type == 0x2 and i < 5) {
                // 64-bit BAR: high half lives in BAR[i+1].
                const hi_offset: u8 = offset + 4;
                const hi_original = configRead32(dev.bus, dev.slot, dev.func, hi_offset);
                configWrite32(dev.bus, dev.slot, dev.func, hi_offset, 0xFFFFFFFF);
                const hi_probed = configRead32(dev.bus, dev.slot, dev.func, hi_offset);
                configWrite32(dev.bus, dev.slot, dev.func, hi_offset, hi_original);

                bar.base = (@as(u64, hi_original) << 32) | lo_base;
                const size64 = (@as(u64, hi_probed) << 32) | lo_size_bits;
                bar.size = (~size64) + 1;
                bar.is_64bit = true;

                // Skip the high half slot.
                i += 1;
            } else {
                bar.base = lo_base;
                bar.size = (~@as(u64, lo_size_bits) + 1) & 0xFFFFFFFF;
                bar.is_64bit = false;
            }
        }
    }
}

/// Read a single function and, if valid, record it. Returns true on record.
fn recordFunction(bus: u8, slot: u8, func: u8) bool {
    const vendor = configRead16(bus, slot, func, REG_VENDOR_ID);
    if (vendor == 0xFFFF or vendor == 0) return false;
    if (device_count >= MAX_DEVICES) return false;

    var dev = &devices[device_count];
    dev.* = .{};
    dev.bus = bus;
    dev.slot = slot;
    dev.func = func;
    dev.vendor_id = vendor;
    dev.device_id = configRead16(bus, slot, func, REG_DEVICE_ID);
    dev.prog_if = configRead8(bus, slot, func, REG_PROG_IF);
    dev.subclass = configRead8(bus, slot, func, REG_SUBCLASS);
    dev.class = configRead8(bus, slot, func, REG_CLASS);
    dev.header_type = configRead8(bus, slot, func, REG_HEADER_TYPE);
    dev.irq_line = configRead8(bus, slot, func, REG_INTERRUPT_LINE);

    // Only type-0 headers carry the 6 BARs we care about.
    if ((dev.header_type & 0x7F) == 0) {
        probeBars(dev);
    }

    device_count += 1;
    return true;
}

/// Walk every function on every slot of bus 0.
fn scanBus(bus: u8) void {
    var slot: u8 = 0;
    while (slot < 32) : (slot += 1) {
        // Slot probe is via function 0.
        const vendor0 = configRead16(bus, slot, 0, REG_VENDOR_ID);
        if (vendor0 == 0xFFFF or vendor0 == 0) continue;

        _ = recordFunction(bus, slot, 0);

        const header0 = configRead8(bus, slot, 0, REG_HEADER_TYPE);
        if ((header0 & 0x80) == 0) continue; // single-function device

        var func: u8 = 1;
        while (func < 8) : (func += 1) {
            _ = recordFunction(bus, slot, func);
        }
    }
}

/// Enumerate PCI bus 0 and log a summary to the serial console.
pub fn init() void {
    device_count = 0;
    scanBus(0);
    initialized = true;
    dumpDevices();
}

// ---------------------------------------------------------------------------
// Public lookup helpers
// ---------------------------------------------------------------------------

/// Find the first device matching vendor + device ID.
pub fn findByVendor(vendor: u16, device: u16) ?*const Device {
    var i: usize = 0;
    while (i < device_count) : (i += 1) {
        const d = &devices[i];
        if (d.vendor_id == vendor and d.device_id == device) return d;
    }
    return null;
}

/// Find the first device matching class + subclass.
pub fn findByClass(class: u8, subclass: u8) ?*const Device {
    var i: usize = 0;
    while (i < device_count) : (i += 1) {
        const d = &devices[i];
        if (d.class == class and d.subclass == subclass) return d;
    }
    return null;
}

/// Convenience: locate the QEMU virtio-blk device (legacy or modern).
pub fn findVirtioBlk() ?*const Device {
    if (findByVendor(VIRTIO_VENDOR, VIRTIO_BLK_DEVICE_LEGACY)) |d| return d;
    return findByVendor(VIRTIO_VENDOR, VIRTIO_BLK_DEVICE_MODERN);
}

/// Slice over all recorded devices.
pub fn list() []const Device {
    return devices[0..device_count];
}

pub fn count() usize {
    return device_count;
}

pub fn isInitialized() bool {
    return initialized;
}

// ---------------------------------------------------------------------------
// Debug printing
// ---------------------------------------------------------------------------

fn dumpDevices() void {
    serial.puts("[pci] enumeration complete, ");
    serial.putDec(device_count);
    serial.println(" device(s) found on bus 0");

    var i: usize = 0;
    while (i < device_count) : (i += 1) {
        const d = &devices[i];
        serial.puts("[pci]   ");
        serial.putHex(d.bus);
        serial.puts(":");
        serial.putHex(d.slot);
        serial.puts(".");
        serial.putHex(d.func);
        serial.puts("  vendor=");
        serial.putHex(d.vendor_id);
        serial.puts(" device=");
        serial.putHex(d.device_id);
        serial.puts(" class=");
        serial.putHex(d.class);
        serial.puts("/");
        serial.putHex(d.subclass);
        serial.puts(" irq=");
        serial.putDec(d.irq_line);
        serial.println("");

        var b: usize = 0;
        while (b < 6) : (b += 1) {
            const bar = d.bars[b];
            if (bar.size == 0) continue;
            serial.puts("[pci]       BAR");
            serial.putDec(b);
            if (bar.is_mmio) {
                if (bar.is_64bit) {
                    serial.puts(" mmio64 base=");
                } else {
                    serial.puts(" mmio32 base=");
                }
            } else {
                serial.puts(" io     base=");
            }
            serial.putHex(bar.base);
            serial.puts(" size=");
            serial.putHex(bar.size);
            serial.println("");
        }
    }

    if (findVirtioBlk()) |d| {
        serial.puts("[pci] virtio-blk found at ");
        serial.putHex(d.bus);
        serial.puts(":");
        serial.putHex(d.slot);
        serial.puts(".");
        serial.putHex(d.func);
        serial.println("");
    } else {
        serial.println("[pci] virtio-blk not present (QEMU needs -drive ...,if=virtio)");
    }
}
