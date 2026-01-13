// Graphene Kernel - User-Space Driver Framework
// Manages driver processes and their hardware capabilities

const object = @import("object.zig");
const capability = @import("capability.zig");
const process = @import("process.zig");
const thread = @import("thread.zig");
const pic = @import("pic.zig");
const framebuffer = @import("framebuffer.zig");

/// Maximum number of registered drivers
const MAX_DRIVERS: usize = 32;

/// Driver types
pub const DriverType = enum(u8) {
    keyboard,
    mouse,
    storage,
    network,
    serial,
    display,
    audio,
    other,
};

/// Driver registration entry
pub const DriverEntry = struct {
    /// Driver name
    name: [32]u8 = [_]u8{0} ** 32,

    /// Driver type
    driver_type: DriverType = .other,

    /// Associated process
    proc: ?*process.Process = null,

    /// IRQ number (if applicable)
    irq: ?u8 = null,

    /// I/O port range start (if applicable)
    io_port_start: ?u16 = null,

    /// I/O port count
    io_port_count: u16 = 0,

    /// IRQ capability slot in driver's cap table
    irq_cap_slot: ?capability.CapSlot = null,

    /// I/O port capability slot in driver's cap table
    ioport_cap_slot: ?capability.CapSlot = null,

    /// Is this entry in use?
    in_use: bool = false,

    /// Set driver name
    pub fn setName(self: *DriverEntry, name: []const u8) void {
        const len = @min(name.len, self.name.len - 1);
        for (0..len) |i| {
            self.name[i] = name[i];
        }
        self.name[len] = 0;
    }

    /// Get driver name
    pub fn getName(self: *const DriverEntry) []const u8 {
        var len: usize = 0;
        while (len < self.name.len and self.name[len] != 0) {
            len += 1;
        }
        return self.name[0..len];
    }
};

/// Driver registry
var drivers: [MAX_DRIVERS]DriverEntry = [_]DriverEntry{.{}} ** MAX_DRIVERS;
var driver_count: usize = 0;
var initialized: bool = false;

/// Initialize driver framework
pub fn init() void {
    // Clear driver registry
    for (&drivers) |*entry| {
        entry.* = .{};
    }
    driver_count = 0;
    initialized = true;
}

/// Register a new driver
/// Returns the driver entry on success, null on failure
pub fn registerDriver(
    name: []const u8,
    driver_type: DriverType,
    proc: *process.Process,
    irq: ?u8,
    io_port_start: ?u16,
    io_port_count: u16,
) ?*DriverEntry {
    if (!initialized) return null;

    // Find free slot
    for (&drivers) |*entry| {
        if (!entry.in_use) {
            entry.setName(name);
            entry.driver_type = driver_type;
            entry.proc = proc;
            entry.irq = irq;
            entry.io_port_start = io_port_start;
            entry.io_port_count = io_port_count;
            entry.in_use = true;
            driver_count += 1;

            // Grant hardware capabilities to driver
            if (grantHardwareCapabilities(entry)) {
                return entry;
            } else {
                // Failed to grant caps, clean up
                entry.in_use = false;
                driver_count -= 1;
                return null;
            }
        }
    }

    return null;
}

/// Grant IRQ and I/O port capabilities to a driver
fn grantHardwareCapabilities(entry: *DriverEntry) bool {
    const proc = entry.proc orelse return false;
    const cap_table = proc.cap_table orelse return false;

    // Grant IRQ capability if requested
    if (entry.irq) |irq_num| {
        // Create IRQ object
        const irq_obj = object.createIrqObject(irq_num) orelse return false;

        // Find free capability slot
        const slot = cap_table.findFreeSlot() orelse {
            object.freeIrqObject(irq_obj);
            return false;
        };

        // Insert capability with full rights
        capability.insertAt(cap_table, slot, &irq_obj.base, capability.Rights.ALL) catch {
            object.freeIrqObject(irq_obj);
            return false;
        };

        entry.irq_cap_slot = slot;

        // Unmask the IRQ in PIC so it can fire
        pic.unmaskIrq(irq_num);
    }

    // Grant I/O port capability if requested
    if (entry.io_port_start) |port_start| {
        if (entry.io_port_count > 0) {
            // Create I/O port object
            const ioport_obj = object.createIoPortObject(port_start, entry.io_port_count) orelse {
                // Clean up IRQ cap if we created one
                if (entry.irq_cap_slot) |slot| {
                    capability.delete(cap_table, slot);
                }
                return false;
            };

            // Find free capability slot
            const slot = cap_table.findFreeSlot() orelse {
                object.freeIoPortObject(ioport_obj);
                if (entry.irq_cap_slot) |irq_slot| {
                    capability.delete(cap_table, irq_slot);
                }
                return false;
            };

            // Insert capability with read/write rights
            capability.insertAt(cap_table, slot, &ioport_obj.base, capability.Rights.RW) catch {
                object.freeIoPortObject(ioport_obj);
                if (entry.irq_cap_slot) |irq_slot| {
                    capability.delete(cap_table, irq_slot);
                }
                return false;
            };

            entry.ioport_cap_slot = slot;
        }
    }

    return true;
}

/// Unregister a driver
pub fn unregisterDriver(entry: *DriverEntry) void {
    if (!entry.in_use) return;

    // Revoke capabilities
    if (entry.proc) |proc| {
        if (proc.cap_table) |cap_table| {
            if (entry.irq_cap_slot) |slot| {
                capability.delete(cap_table, slot);
            }
            if (entry.ioport_cap_slot) |slot| {
                capability.delete(cap_table, slot);
            }
        }
    }

    // Mask IRQ if we unmasked it
    if (entry.irq) |irq_num| {
        pic.maskIrq(irq_num);
    }

    // Clear entry
    entry.* = .{};
    if (driver_count > 0) {
        driver_count -= 1;
    }
}

/// Find driver by name
pub fn findDriverByName(name: []const u8) ?*DriverEntry {
    for (&drivers) |*entry| {
        if (entry.in_use) {
            const entry_name = entry.getName();
            if (entry_name.len == name.len) {
                var match = true;
                for (0..name.len) |i| {
                    if (entry_name[i] != name[i]) {
                        match = false;
                        break;
                    }
                }
                if (match) return entry;
            }
        }
    }
    return null;
}

/// Find driver by IRQ
pub fn findDriverByIrq(irq: u8) ?*DriverEntry {
    for (&drivers) |*entry| {
        if (entry.in_use and entry.irq == irq) {
            return entry;
        }
    }
    return null;
}

/// Find driver by type
pub fn findDriverByType(driver_type: DriverType) ?*DriverEntry {
    for (&drivers) |*entry| {
        if (entry.in_use and entry.driver_type == driver_type) {
            return entry;
        }
    }
    return null;
}

/// Get driver count
pub fn getDriverCount() usize {
    return driver_count;
}

/// Check if initialized
pub fn isInitialized() bool {
    return initialized;
}

/// Debug: print registered drivers
pub fn debugPrintDrivers() void {
    var y: u32 = 400;
    framebuffer.puts("Registered drivers:", 10, y, 0x00ffff00);
    y += 16;

    for (&drivers) |*entry| {
        if (entry.in_use) {
            framebuffer.puts(entry.getName(), 20, y, 0x00ffffff);
            y += 16;
        }
    }

    if (driver_count == 0) {
        framebuffer.puts("  (none)", 20, y, 0x00808080);
    }
}
