// Graphene Kernel - Kernel Objects
// Base types for capability-based security

const thread = @import("thread.zig");

/// Kernel object types (matches DESIGN.md)
pub const ObjectType = enum(u8) {
    none = 0,
    memory = 1,
    thread = 2,
    process = 3,
    ipc_endpoint = 4,
    ipc_channel = 5,
    irq = 6,
    ioport = 7,
    device_mmio = 8,
};

/// Base kernel object header
/// All kernel objects start with this header for uniform handling
pub const Object = struct {
    /// Object type for runtime type checking
    obj_type: ObjectType,

    /// Reference count for lifetime management
    ref_count: u32,

    /// Generation number for capability validation
    /// Incremented when object is destroyed, invalidating stale capabilities
    generation: u32,

    /// Flags for object state
    flags: ObjectFlags,

    /// Create a new object header
    pub fn init(obj_type: ObjectType) Object {
        return .{
            .obj_type = obj_type,
            .ref_count = 1,
            .generation = 0,
            .flags = .{},
        };
    }

    /// Increment reference count
    pub fn ref(self: *Object) void {
        self.ref_count += 1;
    }

    /// Decrement reference count
    /// Returns true if object should be destroyed (count reached 0)
    pub fn unref(self: *Object) bool {
        if (self.ref_count == 0) {
            return false; // Already destroyed
        }
        self.ref_count -= 1;
        return self.ref_count == 0;
    }

    /// Invalidate object (increment generation)
    pub fn invalidate(self: *Object) void {
        self.generation +%= 1;
        self.flags.destroyed = true;
    }

    /// Check if object is valid
    pub fn isValid(self: *const Object) bool {
        return !self.flags.destroyed and self.ref_count > 0;
    }
};

/// Object flags
pub const ObjectFlags = packed struct(u8) {
    destroyed: bool = false,
    locked: bool = false, // For synchronization
    _reserved: u6 = 0,
};

/// Memory object - represents a physical memory region
pub const MemoryObject = struct {
    base: Object,

    /// Physical address start
    phys_start: u64,

    /// Size in bytes
    size: u64,

    /// Memory flags
    mem_flags: MemoryFlags,

    /// Number of mappings (for shared memory tracking)
    map_count: u32,

    pub fn init(phys_start: u64, size: u64, flags: MemoryFlags) MemoryObject {
        return .{
            .base = Object.init(.memory),
            .phys_start = phys_start,
            .size = size,
            .mem_flags = flags,
            .map_count = 0,
        };
    }
};

/// Memory object flags
pub const MemoryFlags = packed struct(u8) {
    device: bool = false, // Device memory (uncacheable)
    shared: bool = false, // Shared memory
    dma: bool = false, // DMA-capable
    contiguous: bool = false, // Physically contiguous
    _reserved: u4 = 0,
};

/// IRQ object - represents an interrupt line
pub const IrqObject = struct {
    base: Object,

    /// IRQ number
    irq_num: u8,

    /// Handler registered
    handler_registered: bool,

    /// IRQ flags
    irq_flags: IrqFlags,

    /// Wait queue for threads waiting on this IRQ
    wait_queue: thread.WaitQueue = .{},

    /// Pending IRQ count (IRQs that fired while no thread was waiting)
    pending_count: u32 = 0,

    pub fn init(irq_num: u8) IrqObject {
        return .{
            .base = Object.init(.irq),
            .irq_num = irq_num,
            .handler_registered = false,
            .irq_flags = .{},
            .wait_queue = .{},
            .pending_count = 0,
        };
    }
};

/// IRQ flags
pub const IrqFlags = packed struct(u8) {
    edge_triggered: bool = false,
    level_triggered: bool = false,
    shared: bool = false,
    _reserved: u5 = 0,
};

/// I/O port object - represents x86 I/O port range
pub const IoPortObject = struct {
    base: Object,

    /// Port range start
    port_start: u16,

    /// Number of ports
    port_count: u16,

    pub fn init(port_start: u16, port_count: u16) IoPortObject {
        return .{
            .base = Object.init(.ioport),
            .port_start = port_start,
            .port_count = port_count,
        };
    }
};

/// Device MMIO object - represents memory-mapped I/O region
pub const DeviceMmioObject = struct {
    base: Object,

    /// Physical address of MMIO region
    phys_addr: u64,

    /// Size of MMIO region
    size: u64,

    pub fn init(phys_addr: u64, size: u64) DeviceMmioObject {
        return .{
            .base = Object.init(.device_mmio),
            .phys_addr = phys_addr,
            .size = size,
        };
    }
};

// Forward declarations for complex objects (defined in their respective modules)
// Thread, Process, IpcEndpoint, IpcChannel are defined in thread.zig, process.zig, ipc.zig

/// Generic object pointer
pub const ObjectPtr = *Object;

/// Cast object to specific type
pub fn cast(comptime T: type, obj: *Object) ?*T {
    const expected_type = switch (T) {
        MemoryObject => ObjectType.memory,
        IrqObject => ObjectType.irq,
        IoPortObject => ObjectType.ioport,
        DeviceMmioObject => ObjectType.device_mmio,
        else => return null,
    };

    if (obj.obj_type != expected_type) {
        return null;
    }

    return @alignCast(@fieldParentPtr("base", obj));
}

/// Get object type name for debugging
pub fn typeName(obj_type: ObjectType) []const u8 {
    return switch (obj_type) {
        .none => "none",
        .memory => "memory",
        .thread => "thread",
        .process => "process",
        .ipc_endpoint => "ipc_endpoint",
        .ipc_channel => "ipc_channel",
        .irq => "irq",
        .ioport => "ioport",
        .device_mmio => "device_mmio",
    };
}

// ============================================================================
// Object Pools for Phase 3 Drivers
// ============================================================================

/// IRQ object pool (one per IRQ line, 16 max for legacy PIC)
const MAX_IRQ_OBJECTS: usize = 16;
var irq_object_pool: [MAX_IRQ_OBJECTS]IrqObject = undefined;
var irq_object_used: [MAX_IRQ_OBJECTS]bool = [_]bool{false} ** MAX_IRQ_OBJECTS;

/// Create an IRQ object for a specific IRQ number
/// Returns null if IRQ already has an owner or pool is full
pub fn createIrqObject(irq_num: u8) ?*IrqObject {
    // Check if IRQ already has an object (only one owner per IRQ)
    for (&irq_object_pool, irq_object_used) |*obj, used| {
        if (used and obj.irq_num == irq_num) {
            return null; // Already owned
        }
    }

    // Allocate new IRQ object
    for (&irq_object_used, 0..) |*used, i| {
        if (!used.*) {
            used.* = true;
            irq_object_pool[i] = IrqObject.init(irq_num);
            return &irq_object_pool[i];
        }
    }
    return null; // Pool full
}

/// Find IRQ object by IRQ number (for interrupt handler)
pub fn getIrqObject(irq_num: u8) ?*IrqObject {
    for (&irq_object_pool, irq_object_used) |*obj, used| {
        if (used and obj.irq_num == irq_num) {
            return obj;
        }
    }
    return null;
}

/// Free an IRQ object
pub fn freeIrqObject(irq_obj: *IrqObject) void {
    const index = (@intFromPtr(irq_obj) - @intFromPtr(&irq_object_pool)) / @sizeOf(IrqObject);
    if (index < MAX_IRQ_OBJECTS) {
        irq_object_used[index] = false;
    }
}

/// I/O port object pool
const MAX_IOPORT_OBJECTS: usize = 32;
var ioport_object_pool: [MAX_IOPORT_OBJECTS]IoPortObject = undefined;
var ioport_object_used: [MAX_IOPORT_OBJECTS]bool = [_]bool{false} ** MAX_IOPORT_OBJECTS;

/// Create an I/O port object for a port range
pub fn createIoPortObject(port_start: u16, port_count: u16) ?*IoPortObject {
    // Allocate new I/O port object
    for (&ioport_object_used, 0..) |*used, i| {
        if (!used.*) {
            used.* = true;
            ioport_object_pool[i] = IoPortObject.init(port_start, port_count);
            return &ioport_object_pool[i];
        }
    }
    return null; // Pool full
}

/// Free an I/O port object
pub fn freeIoPortObject(ioport_obj: *IoPortObject) void {
    const index = (@intFromPtr(ioport_obj) - @intFromPtr(&ioport_object_pool)) / @sizeOf(IoPortObject);
    if (index < MAX_IOPORT_OBJECTS) {
        ioport_object_used[index] = false;
    }
}
