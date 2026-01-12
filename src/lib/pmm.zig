// Graphene Kernel - Physical Memory Manager (PMM)
// Bitmap-based physical frame allocator

const limine = @import("limine.zig");
const framebuffer = @import("framebuffer.zig");

/// Page size (4KB)
pub const PAGE_SIZE: u64 = 4096;
pub const PAGE_SHIFT: u6 = 12;

/// Physical frame number type
pub const Frame = u64;

/// PMM state
var bitmap: [*]u8 = undefined;
var bitmap_size: usize = 0;
var total_frames: u64 = 0;
var free_frames: u64 = 0;
var hhdm_offset: u64 = 0;
var highest_address: u64 = 0;

/// Hint for next free frame search (optimization)
var last_alloc_index: usize = 0;

/// Convert physical address to virtual using HHDM
pub fn physToVirt(phys: u64) u64 {
    return phys + hhdm_offset;
}

/// Convert virtual address to physical
pub fn virtToPhys(virt: u64) u64 {
    return virt - hhdm_offset;
}

/// Convert physical address to frame number
pub fn addrToFrame(addr: u64) Frame {
    return addr >> PAGE_SHIFT;
}

/// Convert frame number to physical address
pub fn frameToAddr(frame: Frame) u64 {
    return frame << PAGE_SHIFT;
}

/// Check if frame is marked as used in bitmap
fn isFrameUsed(frame: Frame) bool {
    if (frame >= total_frames) return true;
    const byte_index = frame / 8;
    const bit_index: u3 = @truncate(frame % 8);
    return (bitmap[byte_index] & (@as(u8, 1) << bit_index)) != 0;
}

/// Mark frame as used in bitmap
fn markFrameUsed(frame: Frame) void {
    if (frame >= total_frames) return;
    const byte_index = frame / 8;
    const bit_index: u3 = @truncate(frame % 8);
    bitmap[byte_index] |= (@as(u8, 1) << bit_index);
}

/// Mark frame as free in bitmap
fn markFrameFree(frame: Frame) void {
    if (frame >= total_frames) return;
    const byte_index = frame / 8;
    const bit_index: u3 = @truncate(frame % 8);
    bitmap[byte_index] &= ~(@as(u8, 1) << bit_index);
}

/// Initialize PMM from Limine memory map
pub fn init(mmap_response: *limine.MemoryMapResponse, hhdm_response: *limine.HhdmResponse) void {
    hhdm_offset = hhdm_response.offset;

    const entries = mmap_response.getEntries();

    // First pass: find highest usable address
    highest_address = 0;
    for (entries) |entry| {
        const end = entry.base + entry.length;
        if (end > highest_address) {
            highest_address = end;
        }
    }

    // Calculate bitmap size
    total_frames = highest_address / PAGE_SIZE;
    bitmap_size = (total_frames + 7) / 8; // Round up to bytes

    // Second pass: find a usable region to place the bitmap
    var bitmap_phys: u64 = 0;
    for (entries) |entry| {
        if (entry.type == .usable and entry.length >= bitmap_size) {
            bitmap_phys = entry.base;
            break;
        }
    }

    if (bitmap_phys == 0) {
        // No suitable region found - kernel panic
        framebuffer.puts("[PANIC] PMM: No memory for bitmap!", 10, 300, 0x00ff0000);
        return;
    }

    // Place bitmap at found location (access via HHDM)
    bitmap = @ptrFromInt(physToVirt(bitmap_phys));

    // Initialize bitmap: mark all frames as used
    for (0..bitmap_size) |i| {
        bitmap[i] = 0xFF;
    }

    // Third pass: mark usable regions as free
    free_frames = 0;
    for (entries) |entry| {
        if (entry.type == .usable or entry.type == .bootloader_reclaimable) {
            var base = entry.base;
            var length = entry.length;

            // Skip the bitmap region we placed
            if (base == bitmap_phys) {
                const bitmap_pages = (bitmap_size + PAGE_SIZE - 1) / PAGE_SIZE;
                base += bitmap_pages * PAGE_SIZE;
                if (length > bitmap_pages * PAGE_SIZE) {
                    length -= bitmap_pages * PAGE_SIZE;
                } else {
                    continue;
                }
            }

            // Align base up to page boundary
            const aligned_base = (base + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
            if (aligned_base >= base + length) continue;

            const aligned_length = length - (aligned_base - base);
            const num_pages = aligned_length / PAGE_SIZE;

            // Mark pages as free
            const start_frame = addrToFrame(aligned_base);
            for (0..num_pages) |i| {
                markFrameFree(start_frame + i);
                free_frames += 1;
            }
        }
    }
}

/// Allocate a single physical frame
/// Returns physical address or null if out of memory
pub fn allocFrame() ?u64 {
    // Search bitmap starting from last allocation hint
    var search_start = last_alloc_index;
    var wrapped = false;

    while (true) {
        // Search through bitmap bytes
        var byte_index = search_start / 8;
        while (byte_index < bitmap_size) : (byte_index += 1) {
            // Skip fully used bytes
            if (bitmap[byte_index] == 0xFF) continue;

            // Find free bit in this byte
            const byte_val = bitmap[byte_index];
            for (0..8) |bit| {
                const bit_index: u3 = @truncate(bit);
                if ((byte_val & (@as(u8, 1) << bit_index)) == 0) {
                    const frame: Frame = byte_index * 8 + bit;
                    if (frame < total_frames) {
                        markFrameUsed(frame);
                        free_frames -= 1;
                        last_alloc_index = byte_index * 8;
                        return frameToAddr(frame);
                    }
                }
            }
        }

        // Wrap around and search from beginning
        if (!wrapped and search_start > 0) {
            search_start = 0;
            wrapped = true;
        } else {
            break;
        }
    }

    return null; // Out of memory
}

/// Allocate contiguous physical frames
/// Returns physical address of first frame or null if not available
pub fn allocFrames(count: usize) ?u64 {
    if (count == 0) return null;
    if (count == 1) return allocFrame();

    // Search for contiguous free frames
    var start_frame: Frame = 0;
    while (start_frame + count <= total_frames) {
        // Check if 'count' frames starting at start_frame are all free
        var all_free = true;
        for (0..count) |i| {
            if (isFrameUsed(start_frame + i)) {
                // Skip to frame after the used one
                start_frame = start_frame + i + 1;
                all_free = false;
                break;
            }
        }

        if (all_free) {
            // Found contiguous region, mark as used
            for (0..count) |i| {
                markFrameUsed(start_frame + i);
            }
            free_frames -= count;
            return frameToAddr(start_frame);
        }
    }

    return null; // No contiguous region found
}

/// Free a single physical frame
pub fn freeFrame(phys_addr: u64) void {
    const frame = addrToFrame(phys_addr);
    if (frame < total_frames and isFrameUsed(frame)) {
        markFrameFree(frame);
        free_frames += 1;
        // Update hint if this frame is earlier
        if (frame < last_alloc_index) {
            last_alloc_index = frame;
        }
    }
}

/// Free contiguous physical frames
pub fn freeFrames(phys_addr: u64, count: usize) void {
    const start_frame = addrToFrame(phys_addr);
    for (0..count) |i| {
        const frame = start_frame + i;
        if (frame < total_frames and isFrameUsed(frame)) {
            markFrameFree(frame);
            free_frames += 1;
        }
    }
    // Update hint
    if (start_frame < last_alloc_index) {
        last_alloc_index = start_frame;
    }
}

/// Get number of free frames
pub fn getFreeFrames() u64 {
    return free_frames;
}

/// Get total number of frames
pub fn getTotalFrames() u64 {
    return total_frames;
}

/// Get free memory in bytes
pub fn getFreeMemory() u64 {
    return free_frames * PAGE_SIZE;
}

/// Get total memory in bytes
pub fn getTotalMemory() u64 {
    return total_frames * PAGE_SIZE;
}

/// Get HHDM offset
pub fn getHhdmOffset() u64 {
    return hhdm_offset;
}
