// Graphene Kernel - Heap Allocator
// Two-tier allocator: slab for small sizes, free-list for large

const std = @import("std");
const pmm = @import("pmm.zig");
const paging = @import("paging.zig");
const vmm = @import("vmm.zig");

/// Heap configuration
const MIN_ALLOC_SIZE: usize = 16;
const MAX_SLAB_SIZE: usize = 2048;
const SLAB_PAGE_COUNT: usize = 4; // Pages per slab (16KB per size class)

/// Allocation header for free-list allocator
const AllocHeader = struct {
    size: usize,
    magic: u32 = MAGIC_ALLOC,

    const MAGIC_ALLOC: u32 = 0xA110C8ED;
    const MAGIC_FREE: u32 = 0xFEEEFEEE;
};

/// Free block for free-list (embedded in free memory)
const FreeBlock = struct {
    size: usize,
    next: ?*FreeBlock,
    magic: u32 = AllocHeader.MAGIC_FREE,
};

/// Slab entry (free list node embedded in free slots)
const SlabEntry = struct {
    next: ?*SlabEntry,
};

/// Slab cache for a specific size class
const SlabCache = struct {
    size: usize,
    free_head: ?*SlabEntry,
    pages_used: usize,

    fn init(size: usize) SlabCache {
        return .{
            .size = size,
            .free_head = null,
            .pages_used = 0,
        };
    }

    fn alloc(self: *SlabCache) ?[*]u8 {
        if (self.free_head) |entry| {
            self.free_head = entry.next;
            return @ptrCast(entry);
        }

        // Need to allocate new slab page
        if (!self.growSlab()) {
            return null;
        }

        // Try again after growing
        if (self.free_head) |entry| {
            self.free_head = entry.next;
            return @ptrCast(entry);
        }

        return null;
    }

    fn free(self: *SlabCache, ptr: [*]u8) void {
        const entry: *SlabEntry = @ptrCast(@alignCast(ptr));
        entry.next = self.free_head;
        self.free_head = entry;
    }

    fn growSlab(self: *SlabCache) bool {
        // Allocate a page for this slab
        const phys = pmm.allocFrame() orelse return false;
        const virt = pmm.physToVirt(phys);

        // Map it (should already be mapped via HHDM, but ensure it)
        // Since we're using HHDM, physical memory is already accessible

        // Initialize free list for this page
        const page: [*]u8 = @ptrFromInt(virt);
        const entries_per_page = pmm.PAGE_SIZE / self.size;

        var i: usize = 0;
        while (i < entries_per_page) : (i += 1) {
            const entry: *SlabEntry = @ptrCast(@alignCast(page + i * self.size));
            entry.next = self.free_head;
            self.free_head = entry;
        }

        self.pages_used += 1;
        return true;
    }
};

/// Size classes for slab allocator
const size_classes = [_]usize{ 16, 32, 64, 128, 256, 512, 1024, 2048 };
const NUM_SIZE_CLASSES = size_classes.len;

/// Heap state
var slabs: [NUM_SIZE_CLASSES]SlabCache = undefined;
var free_list: ?*FreeBlock = null;
var heap_base: u64 = 0;
var heap_top: u64 = 0;
var heap_max: u64 = 0;
var initialized: bool = false;

/// Total allocation stats
var total_allocated: usize = 0;
var total_freed: usize = 0;

/// Initialize the heap
pub fn init() void {
    // Initialize slab caches
    for (&slabs, size_classes) |*slab, size| {
        slab.* = SlabCache.init(size);
    }

    // Heap uses HHDM for backing - no separate virtual region needed for Phase 1
    // We allocate physical pages directly and access via HHDM
    heap_base = 0;
    heap_top = 0;
    heap_max = vmm.KERNEL_HEAP_SIZE;

    initialized = true;
}

/// Get size class index for a given size
fn getSizeClassIndex(size: usize) ?usize {
    for (size_classes, 0..) |class_size, i| {
        if (size <= class_size) {
            return i;
        }
    }
    return null;
}

/// Round size up to include header
fn totalSize(size: usize) usize {
    return size + @sizeOf(AllocHeader);
}

/// Allocate memory
pub fn alloc(size: usize, alignment: usize) ?[*]u8 {
    if (!initialized) return null;
    if (size == 0) return null;

    // For small allocations, use slab
    if (getSizeClassIndex(size)) |index| {
        if (slabs[index].alloc()) |ptr| {
            total_allocated += size_classes[index];
            return ptr;
        }
    }

    // For large allocations, use free-list backed by direct physical allocation
    return allocLarge(size, alignment);
}

fn allocLarge(size: usize, alignment: usize) ?[*]u8 {
    _ = alignment; // TODO: proper alignment handling

    const alloc_size = totalSize(size);
    const pages_needed = (alloc_size + pmm.PAGE_SIZE - 1) / pmm.PAGE_SIZE;

    // First, try to find a suitable block in free list
    var prev: ?*FreeBlock = null;
    var current = free_list;
    while (current) |block| {
        if (block.size >= alloc_size) {
            // Found suitable block
            if (block.size >= alloc_size + @sizeOf(FreeBlock) + MIN_ALLOC_SIZE) {
                // Split block
                const new_block: *FreeBlock = @ptrFromInt(@intFromPtr(block) + alloc_size);
                new_block.size = block.size - alloc_size;
                new_block.next = block.next;
                new_block.magic = AllocHeader.MAGIC_FREE;

                if (prev) |p| {
                    p.next = new_block;
                } else {
                    free_list = new_block;
                }
            } else {
                // Use whole block
                if (prev) |p| {
                    p.next = block.next;
                } else {
                    free_list = block.next;
                }
            }

            // Set up allocation header
            const header: *AllocHeader = @ptrCast(block);
            header.size = alloc_size;
            header.magic = AllocHeader.MAGIC_ALLOC;

            total_allocated += alloc_size;
            return @ptrFromInt(@intFromPtr(header) + @sizeOf(AllocHeader));
        }

        prev = block;
        current = block.next;
    }

    // No suitable free block, allocate new pages
    const phys = pmm.allocFrames(pages_needed) orelse return null;
    const virt = pmm.physToVirt(phys);

    // Set up allocation header
    const header: *AllocHeader = @ptrFromInt(virt);
    header.size = pages_needed * pmm.PAGE_SIZE;
    header.magic = AllocHeader.MAGIC_ALLOC;

    total_allocated += header.size;
    return @ptrFromInt(virt + @sizeOf(AllocHeader));
}

/// Free memory
pub fn free(ptr: ?[*]u8) void {
    if (ptr == null) return;
    if (!initialized) return;

    const addr = @intFromPtr(ptr.?);

    // Check if it's a slab allocation
    for (&slabs, size_classes) |*slab, class_size| {
        // Slab allocations don't have headers
        // We need a way to identify them - for Phase 1, check if within slab pages
        // This is simplified - production would track slab page ranges
        _ = class_size;
        _ = slab;
    }

    // Treat as large allocation
    const header: *AllocHeader = @ptrFromInt(addr - @sizeOf(AllocHeader));

    // Validate magic
    if (header.magic != AllocHeader.MAGIC_ALLOC) {
        // Invalid free or double-free
        return;
    }

    total_freed += header.size;

    // Convert to free block
    const block: *FreeBlock = @ptrCast(header);
    block.magic = AllocHeader.MAGIC_FREE;
    block.size = header.size;

    // Add to free list (sorted by address for coalescing)
    insertFreeBlock(block);

    // Try to coalesce with adjacent blocks
    coalesceFreeBlocks();
}

fn insertFreeBlock(block: *FreeBlock) void {
    const block_addr = @intFromPtr(block);

    var prev: ?*FreeBlock = null;
    var current = free_list;

    while (current) |curr| {
        if (@intFromPtr(curr) > block_addr) {
            break;
        }
        prev = curr;
        current = curr.next;
    }

    block.next = current;
    if (prev) |p| {
        p.next = block;
    } else {
        free_list = block;
    }
}

fn coalesceFreeBlocks() void {
    var current = free_list;
    while (current) |block| {
        if (block.next) |next| {
            // Check if adjacent
            const block_end = @intFromPtr(block) + block.size;
            if (block_end == @intFromPtr(next)) {
                // Merge
                block.size += next.size;
                block.next = next.next;
                // Don't advance - check for more merges with same block
                continue;
            }
        }
        current = block.next;
    }
}

/// Reallocate memory
pub fn realloc(ptr: ?[*]u8, old_size: usize, new_size: usize) ?[*]u8 {
    if (ptr == null) {
        return alloc(new_size, @alignOf(usize));
    }

    if (new_size == 0) {
        free(ptr);
        return null;
    }

    // Allocate new, copy, free old
    const new_ptr = alloc(new_size, @alignOf(usize)) orelse return null;
    const copy_size = if (old_size < new_size) old_size else new_size;

    const src: [*]const u8 = ptr.?;
    const dst: [*]u8 = new_ptr;
    for (0..copy_size) |i| {
        dst[i] = src[i];
    }

    free(ptr);
    return new_ptr;
}

/// Zig std.mem.Allocator interface
pub const allocator = std.mem.Allocator{
    .ptr = undefined,
    .vtable = &vtable,
};

const vtable = std.mem.Allocator.VTable{
    .alloc = zigAlloc,
    .resize = zigResize,
    .free = zigFree,
};

fn zigAlloc(_: *anyopaque, len: usize, ptr_align: u8, _: usize) ?[*]u8 {
    const alignment = @as(usize, 1) << @as(std.mem.Allocator.Log2Align, @intCast(ptr_align));
    return alloc(len, alignment);
}

fn zigResize(_: *anyopaque, buf: []u8, _: u8, new_len: usize, _: usize) bool {
    // Simple resize - only shrink in place for now
    if (new_len <= buf.len) {
        return true;
    }
    return false;
}

fn zigFree(_: *anyopaque, buf: []u8, _: u8, _: usize) void {
    free(buf.ptr);
}

/// Get heap statistics
pub const HeapStats = struct {
    total_allocated: usize,
    total_freed: usize,
    current_used: usize,
};

pub fn getStats() HeapStats {
    return .{
        .total_allocated = total_allocated,
        .total_freed = total_freed,
        .current_used = total_allocated - total_freed,
    };
}

/// Check if heap is initialized
pub fn isInitialized() bool {
    return initialized;
}
