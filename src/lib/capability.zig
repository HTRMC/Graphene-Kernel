// Graphene Kernel - Capability System
// Per-process capability tables for object access control

const object = @import("object.zig");

/// Maximum capabilities per process
pub const MAX_CAPS: u32 = 1024;

/// Capability slot index type
pub const CapSlot = u32;

/// Invalid slot sentinel
pub const INVALID_SLOT: CapSlot = 0xFFFFFFFF;

/// Capability rights (from DESIGN.md)
pub const Rights = packed struct(u8) {
    read: bool = false, // R - Read access
    write: bool = false, // W - Write access
    execute: bool = false, // X - Execute/control
    send: bool = false, // S - Send via IPC
    handle: bool = false, // H - Can handle/delegate capability
    grant: bool = false, // G - Can grant to other processes
    _reserved: u2 = 0,

    /// Full rights
    pub const ALL: Rights = .{
        .read = true,
        .write = true,
        .execute = true,
        .send = true,
        .handle = true,
        .grant = true,
    };

    /// Read-only
    pub const RO: Rights = .{ .read = true };

    /// Read-write
    pub const RW: Rights = .{ .read = true, .write = true };

    /// Read-execute
    pub const RX: Rights = .{ .read = true, .execute = true };

    /// Send only
    pub const SEND: Rights = .{ .send = true };

    /// Receive/handle only
    pub const HANDLE: Rights = .{ .handle = true };

    /// Check if self has all rights in required
    pub fn hasRights(self: Rights, required: Rights) bool {
        const self_bits: u8 = @bitCast(self);
        const required_bits: u8 = @bitCast(required);
        return (self_bits & required_bits) == required_bits;
    }

    /// Mask rights (can only reduce, never escalate)
    pub fn mask(self: Rights, mask_rights: Rights) Rights {
        const self_bits: u8 = @bitCast(self);
        const mask_bits: u8 = @bitCast(mask_rights);
        return @bitCast(self_bits & mask_bits);
    }

    /// Check if any rights are set
    pub fn hasAny(self: Rights) bool {
        const bits: u8 = @bitCast(self);
        return (bits & 0x3F) != 0;
    }
};

/// Single capability entry
pub const Capability = struct {
    /// Object type for fast type checking
    object_type: object.ObjectType = .none,

    /// Rights mask
    rights: Rights = .{},

    /// Generation (must match object's generation for validity)
    generation: u32 = 0,

    /// Pointer to kernel object
    obj: ?*object.Object = null,

    /// Check if capability is valid
    pub fn isValid(self: *const Capability) bool {
        if (self.obj == null) return false;
        if (self.object_type == .none) return false;
        if (!self.obj.?.isValid()) return false;
        if (self.generation != self.obj.?.generation) return false;
        return true;
    }

    /// Clear capability
    pub fn clear(self: *Capability) void {
        self.* = .{};
    }
};

/// Capability table (per-process)
pub const CapTable = struct {
    /// Capability slots (fixed array for O(1) lookup)
    slots: [MAX_CAPS]Capability = [_]Capability{.{}} ** MAX_CAPS,

    /// Bitmap of used slots (for fast free slot search)
    used_bitmap: [MAX_CAPS / 64]u64 = [_]u64{0} ** (MAX_CAPS / 64),

    /// Next free slot hint (optimization)
    next_free_hint: u32 = 0,

    /// Number of used slots
    used_count: u32 = 0,

    /// Parent table (for revocation tracking)
    parent: ?*CapTable = null,

    /// Find a free slot
    pub fn findFreeSlot(self: *CapTable) ?CapSlot {
        // Start from hint
        var slot = self.next_free_hint;
        const start = slot;

        while (true) {
            if (!self.isSlotUsed(slot)) {
                self.next_free_hint = (slot + 1) % MAX_CAPS;
                return slot;
            }

            slot = (slot + 1) % MAX_CAPS;
            if (slot == start) {
                // Wrapped around, table full
                return null;
            }
        }
    }

    /// Check if slot is used
    pub fn isSlotUsed(self: *const CapTable, slot: CapSlot) bool {
        if (slot >= MAX_CAPS) return false;
        const word_index = slot / 64;
        const bit_index: u6 = @truncate(slot % 64);
        return (self.used_bitmap[word_index] & (@as(u64, 1) << bit_index)) != 0;
    }

    /// Mark slot as used
    fn markSlotUsed(self: *CapTable, slot: CapSlot) void {
        if (slot >= MAX_CAPS) return;
        const word_index = slot / 64;
        const bit_index: u6 = @truncate(slot % 64);
        self.used_bitmap[word_index] |= (@as(u64, 1) << bit_index);
        self.used_count += 1;
    }

    /// Mark slot as free
    fn markSlotFree(self: *CapTable, slot: CapSlot) void {
        if (slot >= MAX_CAPS) return;
        const word_index = slot / 64;
        const bit_index: u6 = @truncate(slot % 64);
        self.used_bitmap[word_index] &= ~(@as(u64, 1) << bit_index);
        if (self.used_count > 0) {
            self.used_count -= 1;
        }
    }
};

/// Capability errors
pub const CapError = error{
    InvalidSlot,
    SlotInUse,
    TableFull,
    InvalidCapability,
    TypeMismatch,
    InsufficientRights,
    InvalidObject,
};

/// Insert a new capability
pub fn insert(table: *CapTable, obj: *object.Object, rights: Rights) CapError!CapSlot {
    const slot = table.findFreeSlot() orelse return CapError.TableFull;

    // Increment object reference count
    obj.ref();

    table.slots[slot] = .{
        .object_type = obj.obj_type,
        .rights = rights,
        .generation = obj.generation,
        .obj = obj,
    };

    table.markSlotUsed(slot);
    return slot;
}

/// Insert at specific slot
pub fn insertAt(table: *CapTable, slot: CapSlot, obj: *object.Object, rights: Rights) CapError!void {
    if (slot >= MAX_CAPS) return CapError.InvalidSlot;
    if (table.isSlotUsed(slot)) return CapError.SlotInUse;

    obj.ref();

    table.slots[slot] = .{
        .object_type = obj.obj_type,
        .rights = rights,
        .generation = obj.generation,
        .obj = obj,
    };

    table.markSlotUsed(slot);
}

/// Delete a capability
pub fn delete(table: *CapTable, slot: CapSlot) void {
    if (slot >= MAX_CAPS) return;
    if (!table.isSlotUsed(slot)) return;

    const cap = &table.slots[slot];
    if (cap.obj) |obj| {
        _ = obj.unref();
    }

    cap.clear();
    table.markSlotFree(slot);
}

/// Look up capability with validation
pub fn lookup(
    table: *CapTable,
    slot: CapSlot,
    required_type: ?object.ObjectType,
    required_rights: Rights,
) CapError!*object.Object {
    if (slot >= MAX_CAPS) return CapError.InvalidSlot;
    if (!table.isSlotUsed(slot)) return CapError.InvalidCapability;

    const cap = &table.slots[slot];

    if (!cap.isValid()) {
        return CapError.InvalidCapability;
    }

    // Type check (if required)
    if (required_type) |expected| {
        if (cap.object_type != expected) {
            return CapError.TypeMismatch;
        }
    }

    // Rights check
    if (!cap.rights.hasRights(required_rights)) {
        return CapError.InsufficientRights;
    }

    return cap.obj.?;
}

/// Copy capability with reduced rights
pub fn copy(
    table: *CapTable,
    src_slot: CapSlot,
    dst_slot: CapSlot,
    rights_mask: Rights,
) CapError!void {
    if (src_slot >= MAX_CAPS or dst_slot >= MAX_CAPS) {
        return CapError.InvalidSlot;
    }
    if (!table.isSlotUsed(src_slot)) return CapError.InvalidCapability;
    if (table.isSlotUsed(dst_slot)) return CapError.SlotInUse;

    const src_cap = &table.slots[src_slot];
    if (!src_cap.isValid()) {
        return CapError.InvalidCapability;
    }

    // Copy with reduced rights
    const new_rights = src_cap.rights.mask(rights_mask);

    // Increment object reference
    src_cap.obj.?.ref();

    table.slots[dst_slot] = .{
        .object_type = src_cap.object_type,
        .rights = new_rights,
        .generation = src_cap.generation,
        .obj = src_cap.obj,
    };

    table.markSlotUsed(dst_slot);
}

/// Copy capability to another table (for process creation, IPC)
pub fn copyToTable(
    src_table: *CapTable,
    src_slot: CapSlot,
    dst_table: *CapTable,
    rights_mask: Rights,
) CapError!CapSlot {
    if (src_slot >= MAX_CAPS) return CapError.InvalidSlot;
    if (!src_table.isSlotUsed(src_slot)) return CapError.InvalidCapability;

    const src_cap = &src_table.slots[src_slot];
    if (!src_cap.isValid()) {
        return CapError.InvalidCapability;
    }

    const dst_slot = dst_table.findFreeSlot() orelse return CapError.TableFull;

    // Copy with reduced rights
    const new_rights = src_cap.rights.mask(rights_mask);

    // Increment object reference
    src_cap.obj.?.ref();

    dst_table.slots[dst_slot] = .{
        .object_type = src_cap.object_type,
        .rights = new_rights,
        .generation = src_cap.generation,
        .obj = src_cap.obj,
    };

    dst_table.markSlotUsed(dst_slot);
    return dst_slot;
}

/// Revoke capability (invalidates the slot)
/// Note: Full revocation tree walking is not implemented in Phase 1
pub fn revoke(table: *CapTable, slot: CapSlot) void {
    if (slot >= MAX_CAPS) return;
    if (!table.isSlotUsed(slot)) return;

    const cap = &table.slots[slot];
    if (cap.obj) |obj| {
        // Invalidate the object (increments generation)
        // This will cause all capabilities with old generation to fail validation
        obj.invalidate();
        _ = obj.unref();
    }

    cap.clear();
    table.markSlotFree(slot);
}

/// Validate a capability (quick check without lookup)
pub fn validate(table: *const CapTable, slot: CapSlot) bool {
    if (slot >= MAX_CAPS) return false;
    if (!table.isSlotUsed(slot)) return false;
    return table.slots[slot].isValid();
}

/// Get capability rights
pub fn getRights(table: *const CapTable, slot: CapSlot) ?Rights {
    if (slot >= MAX_CAPS) return null;
    if (!table.isSlotUsed(slot)) return null;
    if (!table.slots[slot].isValid()) return null;
    return table.slots[slot].rights;
}

/// Get capability object type
pub fn getType(table: *const CapTable, slot: CapSlot) ?object.ObjectType {
    if (slot >= MAX_CAPS) return null;
    if (!table.isSlotUsed(slot)) return null;
    return table.slots[slot].object_type;
}

/// Clear all capabilities in table (for process destruction)
pub fn clearAll(table: *CapTable) void {
    for (0..MAX_CAPS) |slot| {
        delete(table, @truncate(slot));
    }
}

/// Count used capabilities
pub fn countUsed(table: *const CapTable) u32 {
    return table.used_count;
}

// Simple pool for capability tables (Phase 1)
const MAX_CAP_TABLES: usize = 64;
var cap_table_pool: [MAX_CAP_TABLES]CapTable = undefined;
var cap_table_used: [MAX_CAP_TABLES]bool = [_]bool{false} ** MAX_CAP_TABLES;

/// Allocate a new capability table
pub fn createTable() ?*CapTable {
    for (&cap_table_used, 0..) |*used, i| {
        if (!used.*) {
            used.* = true;
            cap_table_pool[i] = CapTable{};
            return &cap_table_pool[i];
        }
    }
    return null;
}

/// Free a capability table
pub fn destroyTable(table: *CapTable) void {
    // Clear all capabilities first
    clearAll(table);

    // Return to pool
    const index = (@intFromPtr(table) - @intFromPtr(&cap_table_pool)) / @sizeOf(CapTable);
    if (index < MAX_CAP_TABLES) {
        cap_table_used[index] = false;
    }
}
