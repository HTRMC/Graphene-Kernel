// Graphene Kernel - Virtual Memory Manager (VMM)
// High-level virtual memory management with address spaces

const pmm = @import("pmm.zig");
const paging = @import("paging.zig");
const framebuffer = @import("framebuffer.zig");

/// Virtual memory region flags
pub const VmFlags = packed struct(u8) {
    read: bool = false,
    write: bool = false,
    execute: bool = false,
    user: bool = false,
    guard: bool = false, // Guard page (no backing memory)
    shared: bool = false, // Shared memory region
    _reserved: u2 = 0,

    /// Convert to page table flags
    pub fn toPageFlags(self: VmFlags) paging.PageFlags {
        return .{
            .present = !self.guard, // Guard pages are not present
            .writable = self.write,
            .user_accessible = self.user,
            .no_execute = !self.execute,
        };
    }

    /// Common presets
    pub const KERNEL_RW: VmFlags = .{ .read = true, .write = true };
    pub const KERNEL_RX: VmFlags = .{ .read = true, .execute = true };
    pub const KERNEL_RO: VmFlags = .{ .read = true };
    pub const USER_RW: VmFlags = .{ .read = true, .write = true, .user = true };
    pub const USER_RX: VmFlags = .{ .read = true, .execute = true, .user = true };
    pub const USER_RO: VmFlags = .{ .read = true, .user = true };
    pub const GUARD: VmFlags = .{ .guard = true };
};

/// Virtual memory region
pub const VmRegion = struct {
    start: u64,
    size: u64,
    flags: VmFlags,
    /// For capability tracking (optional)
    cap_slot: ?u32 = null,
};

/// Maximum regions per address space (Phase 1 - simple fixed array)
const MAX_REGIONS: usize = 256;

/// Address space structure
pub const AddressSpace = struct {
    /// Root PML4 physical address
    pml4_phys: u64,
    /// Tracked regions (simple array for Phase 1)
    regions: [MAX_REGIONS]?VmRegion = [_]?VmRegion{null} ** MAX_REGIONS,
    region_count: usize = 0,

    /// Find region containing address
    pub fn findRegion(self: *AddressSpace, vaddr: u64) ?*VmRegion {
        for (&self.regions) |*maybe_region| {
            if (maybe_region.*) |*region| {
                if (vaddr >= region.start and vaddr < region.start + region.size) {
                    return region;
                }
            }
        }
        return null;
    }

    /// Add a region
    pub fn addRegion(self: *AddressSpace, region: VmRegion) VmmError!void {
        // Check for overlaps
        for (self.regions) |maybe_existing| {
            if (maybe_existing) |existing| {
                if (regionsOverlap(region, existing)) {
                    return VmmError.RegionOverlap;
                }
            }
        }

        // Find free slot
        for (&self.regions) |*slot| {
            if (slot.* == null) {
                slot.* = region;
                self.region_count += 1;
                return;
            }
        }

        return VmmError.TooManyRegions;
    }

    /// Remove a region
    pub fn removeRegion(self: *AddressSpace, start: u64) void {
        for (&self.regions) |*slot| {
            if (slot.*) |region| {
                if (region.start == start) {
                    slot.* = null;
                    self.region_count -= 1;
                    return;
                }
            }
        }
    }
};

fn regionsOverlap(a: VmRegion, b: VmRegion) bool {
    return !(a.start + a.size <= b.start or b.start + b.size <= a.start);
}

/// VMM errors
pub const VmmError = error{
    OutOfMemory,
    InvalidAddress,
    RegionOverlap,
    TooManyRegions,
    NotMapped,
    PermissionDenied,
    WxViolation, // Write + Execute violation
};

/// Kernel address space (shared across all processes)
var kernel_space: AddressSpace = undefined;
var kernel_pml4: u64 = 0;
var initialized: bool = false;

/// Kernel virtual address regions
pub const KERNEL_BASE: u64 = 0xFFFFFFFF80000000;
pub const KERNEL_HEAP_BASE: u64 = 0xFFFFFFFF90000000;
pub const KERNEL_HEAP_SIZE: u64 = 256 * 1024 * 1024; // 256MB kernel heap
pub const KERNEL_STACK_BASE: u64 = 0xFFFFFFFFA0000000;

/// User space boundaries
pub const USER_BASE: u64 = 0x0000000000400000; // 4MB (avoid null page)
pub const USER_TOP: u64 = 0x00007FFFFFFFFFFF; // End of user canonical addresses
pub const USER_STACK_TOP: u64 = 0x00007FFFFFF00000; // Below top for stack

/// Initialize VMM
pub fn init() void {
    // Get current CR3 (Limine's page tables)
    kernel_pml4 = paging.readCr3();

    // Initialize kernel address space
    kernel_space.pml4_phys = kernel_pml4;
    kernel_space.region_count = 0;

    initialized = true;
}

/// Get kernel address space
pub fn getKernelSpace() *AddressSpace {
    return &kernel_space;
}

/// Get kernel PML4 physical address
pub fn getKernelPml4() u64 {
    return kernel_pml4;
}

/// Create a new user address space
pub fn createAddressSpace() VmmError!*AddressSpace {
    // Allocate PML4
    const pml4_phys = pmm.allocFrame() orelse return VmmError.OutOfMemory;

    // Zero the table
    const pml4_virt: *[512]paging.PageFlags = @ptrFromInt(pmm.physToVirt(pml4_phys));
    for (pml4_virt) |*entry| {
        entry.* = paging.PageFlags{};
    }

    // Copy kernel mappings (upper half)
    paging.copyKernelMappings(pml4_phys, kernel_pml4);

    // Allocate AddressSpace structure
    // For Phase 1, we use a simple static pool
    const space = allocAddressSpaceStruct() orelse return VmmError.OutOfMemory;
    space.* = AddressSpace{};
    space.pml4_phys = pml4_phys;

    return space;
}

/// Destroy an address space
pub fn destroyAddressSpace(space: *AddressSpace) void {
    if (space.pml4_phys == kernel_pml4) {
        // Don't destroy kernel space
        return;
    }

    // Unmap all user regions and free physical memory
    for (space.regions) |maybe_region| {
        if (maybe_region) |region| {
            if (region.flags.user) {
                // Free backing physical pages
                const num_pages = (region.size + pmm.PAGE_SIZE - 1) / pmm.PAGE_SIZE;
                var vaddr = region.start;
                for (0..num_pages) |_| {
                    if (paging.translate(space.pml4_phys, vaddr)) |paddr| {
                        pmm.freeFrame(paddr);
                    }
                    vaddr += pmm.PAGE_SIZE;
                }
            }
        }
    }

    // Free page table hierarchy (simplified - just free PML4 for now)
    // Full implementation would walk and free all intermediate tables
    pmm.freeFrame(space.pml4_phys);

    // Free AddressSpace struct
    freeAddressSpaceStruct(space);
}

/// Map a region in an address space
pub fn mapRegion(space: *AddressSpace, vaddr: u64, paddr: u64, size: u64, flags: VmFlags) VmmError!void {
    // W^X enforcement
    if (flags.write and flags.execute) {
        return VmmError.WxViolation;
    }

    // Align addresses and size
    const aligned_vaddr = vaddr & ~(pmm.PAGE_SIZE - 1);
    const aligned_paddr = paddr & ~(pmm.PAGE_SIZE - 1);
    const aligned_size = ((size + pmm.PAGE_SIZE - 1) / pmm.PAGE_SIZE) * pmm.PAGE_SIZE;

    // Add region to tracking
    try space.addRegion(.{
        .start = aligned_vaddr,
        .size = aligned_size,
        .flags = flags,
    });

    // Map pages
    const page_flags = flags.toPageFlags();
    const num_pages = aligned_size / pmm.PAGE_SIZE;

    paging.mapRange(space.pml4_phys, aligned_vaddr, aligned_paddr, num_pages, page_flags) catch |err| {
        // Rollback region tracking on failure
        space.removeRegion(aligned_vaddr);
        return switch (err) {
            paging.PagingError.OutOfMemory => VmmError.OutOfMemory,
            paging.PagingError.AlreadyMapped => VmmError.RegionOverlap,
            else => VmmError.InvalidAddress,
        };
    };
}

/// Map a region with newly allocated physical memory
pub fn mapRegionAlloc(space: *AddressSpace, vaddr: u64, size: u64, flags: VmFlags) VmmError!void {
    // W^X enforcement
    if (flags.write and flags.execute) {
        return VmmError.WxViolation;
    }

    const aligned_vaddr = vaddr & ~(pmm.PAGE_SIZE - 1);
    const aligned_size = ((size + pmm.PAGE_SIZE - 1) / pmm.PAGE_SIZE) * pmm.PAGE_SIZE;
    const num_pages = aligned_size / pmm.PAGE_SIZE;

    // Add region tracking
    try space.addRegion(.{
        .start = aligned_vaddr,
        .size = aligned_size,
        .flags = flags,
    });

    // Allocate and map each page
    const page_flags = flags.toPageFlags();
    var current_vaddr = aligned_vaddr;
    var mapped_pages: usize = 0;

    while (mapped_pages < num_pages) : ({
        current_vaddr += pmm.PAGE_SIZE;
        mapped_pages += 1;
    }) {
        const paddr = pmm.allocFrame() orelse {
            // Rollback on OOM
            unmapRegionInternal(space, aligned_vaddr, mapped_pages);
            space.removeRegion(aligned_vaddr);
            return VmmError.OutOfMemory;
        };

        // Zero the page
        const page_virt: [*]u8 = @ptrFromInt(pmm.physToVirt(paddr));
        for (0..pmm.PAGE_SIZE) |i| {
            page_virt[i] = 0;
        }

        paging.mapPageForce(space.pml4_phys, current_vaddr, paddr, page_flags) catch {
            pmm.freeFrame(paddr);
            unmapRegionInternal(space, aligned_vaddr, mapped_pages);
            space.removeRegion(aligned_vaddr);
            return VmmError.OutOfMemory;
        };
    }
}

/// Unmap a region
pub fn unmapRegion(space: *AddressSpace, vaddr: u64) void {
    const region = space.findRegion(vaddr) orelse return;
    const start = region.start;
    const num_pages = region.size / pmm.PAGE_SIZE;

    // Free physical pages and unmap
    unmapRegionInternal(space, start, num_pages);

    // Remove from tracking
    space.removeRegion(start);
}

fn unmapRegionInternal(space: *AddressSpace, start: u64, num_pages: usize) void {
    var vaddr = start;
    for (0..num_pages) |_| {
        if (paging.translate(space.pml4_phys, vaddr)) |paddr| {
            pmm.freeFrame(paddr);
        }
        paging.unmapPage(space.pml4_phys, vaddr);
        vaddr += pmm.PAGE_SIZE;
    }
}

/// Handle page fault
/// Returns true if handled (e.g., demand paging), false if should fault
pub fn handlePageFault(vaddr: u64, error_code: u64) bool {
    const space = getCurrentAddressSpace();

    // Check if address is in a valid region
    const region = space.findRegion(vaddr) orelse {
        // No region - segfault
        return false;
    };

    // Check permissions
    const is_write = (error_code & 0x2) != 0;
    const is_user = (error_code & 0x4) != 0;
    const is_exec = (error_code & 0x10) != 0;

    // Permission checks
    if (is_user and !region.flags.user) return false;
    if (is_write and !region.flags.write) return false;
    if (is_exec and !region.flags.execute) return false;

    // Guard page - intentional fault
    if (region.flags.guard) return false;

    // For Phase 1, we don't do demand paging - all regions are fully mapped
    // So if we get here, it's a real fault
    return false;
}

/// Get current address space (from CR3)
pub fn getCurrentAddressSpace() *AddressSpace {
    const cr3 = paging.readCr3();
    if (cr3 == kernel_pml4) {
        return &kernel_space;
    }
    // For Phase 1, return kernel space
    // Later, get from current thread's process
    return &kernel_space;
}

/// Switch to address space
pub fn switchAddressSpace(space: *AddressSpace) void {
    paging.writeCr3(space.pml4_phys);
}

/// Check if VMM is initialized
pub fn isInitialized() bool {
    return initialized;
}

// Simple AddressSpace struct pool for Phase 1
const MAX_ADDRESS_SPACES: usize = 64;
var address_space_pool: [MAX_ADDRESS_SPACES]AddressSpace = undefined;
var address_space_used: [MAX_ADDRESS_SPACES]bool = [_]bool{false} ** MAX_ADDRESS_SPACES;

fn allocAddressSpaceStruct() ?*AddressSpace {
    for (&address_space_used, 0..) |*used, i| {
        if (!used.*) {
            used.* = true;
            return &address_space_pool[i];
        }
    }
    return null;
}

fn freeAddressSpaceStruct(space: *AddressSpace) void {
    const index = (@intFromPtr(space) - @intFromPtr(&address_space_pool)) / @sizeOf(AddressSpace);
    if (index < MAX_ADDRESS_SPACES) {
        address_space_used[index] = false;
    }
}
