// Graphene Kernel - Generic Object Pool
// O(1) alloc/free via an intrusive free-list of slot indices.
// Replaces Phase 1's linear-scan static pools across the kernel.

/// Build a fixed-capacity pool of `T` with O(1) alloc/free.
///
/// Storage layout is unchanged from a plain `[capacity]T` so existing
/// pointer-arithmetic-based free paths keep working. The free-list is
/// kept in a parallel `[capacity]u32` array.
pub fn Pool(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();
        pub const CAPACITY: usize = capacity;
        const INVALID: u32 = 0xFFFFFFFF;

        items: [capacity]T = undefined,
        /// next_free[i] is the next free slot index when slot i is on
        /// the free-list. Undefined when slot i is allocated.
        next_free: [capacity]u32 = undefined,
        in_use: [capacity]bool = [_]bool{false} ** capacity,
        free_head: u32 = INVALID,
        used_count: u32 = 0,
        initialized: bool = false,

        fn ensureInit(self: *Self) void {
            if (self.initialized) return;
            // Chain 0 -> 1 -> 2 -> ... -> capacity-1 -> INVALID.
            var i: u32 = 0;
            while (i + 1 < capacity) : (i += 1) {
                self.next_free[i] = i + 1;
            }
            self.next_free[capacity - 1] = INVALID;
            self.free_head = 0;
            self.initialized = true;
        }

        pub fn alloc(self: *Self) ?*T {
            self.ensureInit();
            if (self.free_head == INVALID) return null;
            const idx = self.free_head;
            self.free_head = self.next_free[idx];
            self.in_use[idx] = true;
            self.used_count += 1;
            return &self.items[idx];
        }

        pub fn free(self: *Self, ptr: *T) void {
            const base = @intFromPtr(&self.items);
            const addr = @intFromPtr(ptr);
            if (addr < base) return;
            const offset = addr - base;
            const idx_usize = offset / @sizeOf(T);
            if (idx_usize >= capacity) return;
            const idx: u32 = @intCast(idx_usize);
            if (!self.in_use[idx]) return;
            self.in_use[idx] = false;
            self.next_free[idx] = self.free_head;
            self.free_head = idx;
            if (self.used_count > 0) self.used_count -= 1;
        }

        pub fn isUsed(self: *const Self, idx: u32) bool {
            return idx < capacity and self.in_use[idx];
        }

        pub fn at(self: *Self, idx: u32) *T {
            return &self.items[idx];
        }

        pub fn count(self: *const Self) u32 {
            return self.used_count;
        }

        pub fn indexOf(self: *const Self, ptr: *const T) ?u32 {
            const base = @intFromPtr(&self.items);
            const addr = @intFromPtr(ptr);
            if (addr < base) return null;
            const offset = addr - base;
            const idx = offset / @sizeOf(T);
            if (idx >= capacity) return null;
            return @intCast(idx);
        }
    };
}
