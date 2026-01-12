// Graphene Kernel - Kernel Objects
// Base types for capability-based security

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

    pub fn init(irq_num: u8) IrqObject {
        return .{
            .base = Object.init(.irq),
            .irq_num = irq_num,
            .handler_registered = false,
            .irq_flags = .{},
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

    return @fieldParentPtr("base", obj);
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
