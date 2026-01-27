// Graphene Kernel - Page Table Operations
// Low-level x86_64 4-level paging support

const pmm = @import("pmm.zig");

/// Page table entry flags
pub const PageFlags = packed struct(u64) {
    present: bool = false,
    writable: bool = false,
    user_accessible: bool = false,
    write_through: bool = false,
    cache_disabled: bool = false,
    accessed: bool = false,
    dirty: bool = false,
    huge_page: bool = false, // PS bit: 2MB page at PD level, 1GB at PDPT
    global: bool = false,
    available: u3 = 0,
    physical_frame: u40 = 0, // Physical address >> 12
    reserved: u7 = 0,
    protection_key: u4 = 0,
    no_execute: bool = false,

    /// Create flags with physical address
    pub fn withAddress(self: PageFlags, phys_addr: u64) PageFlags {
        var result = self;
        result.physical_frame = @truncate(phys_addr >> 12);
        return result;
    }

    /// Get physical address from entry
    pub fn getAddress(self: PageFlags) u64 {
        return @as(u64, self.physical_frame) << 12;
    }

    /// Common flag presets
    pub const KERNEL_RW: PageFlags = .{
        .present = true,
        .writable = true,
        .user_accessible = false,
        .no_execute = true,
    };

    pub const KERNEL_RX: PageFlags = .{
        .present = true,
        .writable = false,
        .user_accessible = false,
        .no_execute = false,
    };

    pub const KERNEL_RO: PageFlags = .{
        .present = true,
        .writable = false,
        .user_accessible = false,
        .no_execute = true,
    };

    pub const USER_RW: PageFlags = .{
        .present = true,
        .writable = true,
        .user_accessible = true,
        .no_execute = true,
    };

    pub const USER_RX: PageFlags = .{
        .present = true,
        .writable = false,
        .user_accessible = true,
        .no_execute = false,
    };

    pub const USER_RO: PageFlags = .{
        .present = true,
        .writable = false,
        .user_accessible = true,
        .no_execute = true,
    };
};

/// Page table (512 entries = 4KB)
pub const PageTable = [512]PageFlags;

/// Virtual address breakdown for 4-level paging
pub const VirtAddr = packed struct(u64) {
    offset: u12, // Offset within page (0-4095)
    pt_index: u9, // Page Table index (0-511)
    pd_index: u9, // Page Directory index
    pdpt_index: u9, // Page Directory Pointer Table index
    pml4_index: u9, // Page Map Level 4 index
    sign_extend: u16, // Must be sign-extended from bit 47

    /// Decompose a virtual address
    pub fn from(addr: u64) VirtAddr {
        return @bitCast(addr);
    }

    /// Compose back to u64
    pub fn toAddr(self: VirtAddr) u64 {
        return @bitCast(self);
    }
};

/// Paging error types
pub const PagingError = error{
    OutOfMemory,
    InvalidAddress,
    AlreadyMapped,
    NotMapped,
};

/// Read CR3 register (current page table root)
pub fn readCr3() u64 {
    return asm volatile ("mov %%cr3, %[result]"
        : [result] "=r" (-> u64),
    );
}

/// Write CR3 register (switch address space)
pub fn writeCr3(pml4_phys: u64) void {
    asm volatile ("mov %[pml4], %%cr3"
        :
        : [pml4] "r" (pml4_phys),
        : .{ .memory = true }
    );
}

/// Invalidate TLB entry for address
pub fn invlpg(vaddr: u64) void {
    // Use register-indirect addressing to avoid dereferencing the address
    asm volatile ("invlpg (%%rax)"
        :
        : [addr] "{rax}" (vaddr),
        : .{ .memory = true }
    );
}

/// Flush entire TLB
pub fn flushTlb() void {
    // Rewriting CR3 flushes TLB
    writeCr3(readCr3());
}

/// Get or create page table entry, allocating intermediate tables as needed
fn getOrCreateEntry(pml4_virt: *PageTable, vaddr: u64, allocate: bool) PagingError!?*PageFlags {
    const v = VirtAddr.from(vaddr);

    // PML4 -> PDPT
    var pdpt: *PageTable = undefined;
    if (pml4_virt[v.pml4_index].present) {
        const pdpt_phys = pml4_virt[v.pml4_index].getAddress();
        pdpt = @ptrFromInt(pmm.physToVirt(pdpt_phys));
    } else if (allocate) {
        const pdpt_phys = pmm.allocFrame() orelse return PagingError.OutOfMemory;
        pdpt = @ptrFromInt(pmm.physToVirt(pdpt_phys));
        // Zero the new table
        const pdpt_bytes: [*]u8 = @ptrCast(pdpt);
        for (0..4096) |i| {
            pdpt_bytes[i] = 0;
        }
        pml4_virt[v.pml4_index] = (PageFlags{
            .present = true,
            .writable = true,
            .user_accessible = true, // Allow user access to traverse
        }).withAddress(pdpt_phys);
    } else {
        return null;
    }

    // PDPT -> PD
    var pd: *PageTable = undefined;
    if (pdpt[v.pdpt_index].present) {
        // Check for 1GB huge page
        if (pdpt[v.pdpt_index].huge_page) {
            return &pdpt[v.pdpt_index];
        }
        const pd_phys = pdpt[v.pdpt_index].getAddress();
        pd = @ptrFromInt(pmm.physToVirt(pd_phys));
    } else if (allocate) {
        const pd_phys = pmm.allocFrame() orelse return PagingError.OutOfMemory;
        pd = @ptrFromInt(pmm.physToVirt(pd_phys));
        const pd_bytes: [*]u8 = @ptrCast(pd);
        for (0..4096) |i| {
            pd_bytes[i] = 0;
        }
        pdpt[v.pdpt_index] = (PageFlags{
            .present = true,
            .writable = true,
            .user_accessible = true,
        }).withAddress(pd_phys);
    } else {
        return null;
    }

    // PD -> PT
    var pt: *PageTable = undefined;
    if (pd[v.pd_index].present) {
        // Check for 2MB huge page
        if (pd[v.pd_index].huge_page) {
            return &pd[v.pd_index];
        }
        const pt_phys = pd[v.pd_index].getAddress();
        pt = @ptrFromInt(pmm.physToVirt(pt_phys));
    } else if (allocate) {
        const pt_phys = pmm.allocFrame() orelse return PagingError.OutOfMemory;
        pt = @ptrFromInt(pmm.physToVirt(pt_phys));
        const pt_bytes: [*]u8 = @ptrCast(pt);
        for (0..4096) |i| {
            pt_bytes[i] = 0;
        }
        pd[v.pd_index] = (PageFlags{
            .present = true,
            .writable = true,
            .user_accessible = true,
        }).withAddress(pt_phys);
    } else {
        return null;
    }

    // Return PT entry
    return &pt[v.pt_index];
}

/// Map a single 4KB page
pub fn mapPage(pml4_phys: u64, vaddr: u64, paddr: u64, flags: PageFlags) PagingError!void {
    const pml4_virt: *PageTable = @ptrFromInt(pmm.physToVirt(pml4_phys));

    const entry = try getOrCreateEntry(pml4_virt, vaddr, true) orelse unreachable;

    if (entry.present) {
        return PagingError.AlreadyMapped;
    }

    entry.* = flags.withAddress(paddr);
    invlpg(vaddr);
}

/// Map a single 4KB page (overwrites existing)
pub fn mapPageForce(pml4_phys: u64, vaddr: u64, paddr: u64, flags: PageFlags) PagingError!void {
    const pml4_virt: *PageTable = @ptrFromInt(pmm.physToVirt(pml4_phys));

    const entry = try getOrCreateEntry(pml4_virt, vaddr, true) orelse unreachable;

    entry.* = flags.withAddress(paddr);
    invlpg(vaddr);
}

/// Unmap a single page
pub fn unmapPage(pml4_phys: u64, vaddr: u64) void {
    const pml4_virt: *PageTable = @ptrFromInt(pmm.physToVirt(pml4_phys));

    if (getOrCreateEntry(pml4_virt, vaddr, false) catch null) |entry| {
        entry.* = PageFlags{};
        invlpg(vaddr);
    }
}

/// Translate virtual address to physical
pub fn translate(pml4_phys: u64, vaddr: u64) ?u64 {
    const pml4_virt: *PageTable = @ptrFromInt(pmm.physToVirt(pml4_phys));
    const v = VirtAddr.from(vaddr);

    if (getOrCreateEntry(pml4_virt, vaddr, false) catch null) |entry| {
        if (entry.present) {
            return entry.getAddress() + v.offset;
        }
    }

    return null;
}

/// Get flags for a mapped page
pub fn getPageFlags(pml4_phys: u64, vaddr: u64) ?PageFlags {
    const pml4_virt: *PageTable = @ptrFromInt(pmm.physToVirt(pml4_phys));

    if (getOrCreateEntry(pml4_virt, vaddr, false) catch null) |entry| {
        if (entry.present) {
            return entry.*;
        }
    }

    return null;
}

/// Update flags for an existing mapping
pub fn updatePageFlags(pml4_phys: u64, vaddr: u64, flags: PageFlags) PagingError!void {
    const pml4_virt: *PageTable = @ptrFromInt(pmm.physToVirt(pml4_phys));

    const entry = (getOrCreateEntry(pml4_virt, vaddr, false) catch null) orelse return PagingError.NotMapped;

    if (!entry.present) {
        return PagingError.NotMapped;
    }

    const phys = entry.getAddress();
    entry.* = flags.withAddress(phys);
    invlpg(vaddr);
}

/// Map a range of pages
pub fn mapRange(pml4_phys: u64, vaddr_start: u64, paddr_start: u64, num_pages: usize, flags: PageFlags) PagingError!void {
    var vaddr = vaddr_start;
    var paddr = paddr_start;
    for (0..num_pages) |_| {
        try mapPage(pml4_phys, vaddr, paddr, flags);
        vaddr += pmm.PAGE_SIZE;
        paddr += pmm.PAGE_SIZE;
    }
}

/// Unmap a range of pages
pub fn unmapRange(pml4_phys: u64, vaddr_start: u64, num_pages: usize) void {
    var vaddr = vaddr_start;
    for (0..num_pages) |_| {
        unmapPage(pml4_phys, vaddr);
        vaddr += pmm.PAGE_SIZE;
    }
}

/// Allocate a new page table root (PML4)
pub fn allocPageTable() ?u64 {
    const pml4_phys = pmm.allocFrame() orelse return null;
    const pml4_virt: *PageTable = @ptrFromInt(pmm.physToVirt(pml4_phys));

    // Zero the table
    const pml4_bytes: [*]u8 = @ptrCast(pml4_virt);
    for (0..4096) |i| {
        pml4_bytes[i] = 0;
    }

    return pml4_phys;
}

/// Copy kernel mappings from one page table to another
/// Copies PML4 entries 256-511 (upper half)
pub fn copyKernelMappings(dst_pml4_phys: u64, src_pml4_phys: u64) void {
    const dst: *PageTable = @ptrFromInt(pmm.physToVirt(dst_pml4_phys));
    const src: *PageTable = @ptrFromInt(pmm.physToVirt(src_pml4_phys));

    // Copy upper half (kernel space)
    for (256..512) |i| {
        dst[i] = src[i];
    }
}
