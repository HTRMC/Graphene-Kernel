// Graphene Kernel - Global Descriptor Table (GDT)
// Provides segment descriptors for x86_64 long mode with ring 0/3 separation

const std = @import("std");

/// GDT segment selectors (byte offsets into GDT)
pub const Selector = struct {
    pub const KERNEL_CODE: u16 = 0x08; // GDT[1]
    pub const KERNEL_DATA: u16 = 0x10; // GDT[2]
    pub const USER_DATA: u16 = 0x1B; // GDT[3] | RPL 3 (must be before user code for sysret)
    pub const USER_CODE: u16 = 0x23; // GDT[4] | RPL 3
    pub const TSS: u16 = 0x28; // GDT[5]
};

/// Access byte flags
const Access = struct {
    const PRESENT: u8 = 1 << 7;
    const DPL_RING3: u8 = 3 << 5;
    const SEGMENT: u8 = 1 << 4; // 1 for code/data, 0 for system
    const EXECUTABLE: u8 = 1 << 3;
    const DIRECTION: u8 = 1 << 2; // 0 = grows up
    const RW: u8 = 1 << 1; // Readable for code, writable for data
    const ACCESSED: u8 = 1 << 0;

    // Common combinations
    const KERNEL_CODE: u8 = PRESENT | SEGMENT | EXECUTABLE | RW;
    const KERNEL_DATA: u8 = PRESENT | SEGMENT | RW;
    const USER_CODE: u8 = PRESENT | DPL_RING3 | SEGMENT | EXECUTABLE | RW;
    const USER_DATA: u8 = PRESENT | DPL_RING3 | SEGMENT | RW;
    const TSS_AVAILABLE: u8 = PRESENT | 0x9; // Type 9 = 64-bit TSS available
};

/// Flags nibble (upper 4 bits of limit_high_flags)
const Flags = struct {
    const GRANULARITY: u8 = 1 << 7; // Limit in 4KB pages
    const LONG_MODE: u8 = 1 << 5; // 64-bit code segment
    const SIZE_32: u8 = 1 << 6; // 32-bit protected mode (not used in long mode)
};

/// Standard 8-byte GDT entry
const GdtEntry = packed struct {
    limit_low: u16,
    base_low: u16,
    base_mid: u8,
    access: u8,
    limit_high_flags: u8, // Lower 4 bits = limit[19:16], upper 4 bits = flags
    base_high: u8,

    /// Create a null descriptor
    fn empty() GdtEntry {
        return .{
            .limit_low = 0,
            .base_low = 0,
            .base_mid = 0,
            .access = 0,
            .limit_high_flags = 0,
            .base_high = 0,
        };
    }

    /// Create a code/data segment descriptor
    fn segment(base: u32, limit: u20, access: u8, flags: u8) GdtEntry {
        return .{
            .limit_low = @truncate(limit),
            .base_low = @truncate(base),
            .base_mid = @truncate(base >> 16),
            .access = access,
            .limit_high_flags = @as(u8, @truncate(limit >> 16)) | (flags & 0xF0),
            .base_high = @truncate(base >> 24),
        };
    }
};

/// 16-byte TSS descriptor for 64-bit mode
const TssDescriptor = packed struct {
    limit_low: u16,
    base_low: u16,
    base_mid: u8,
    access: u8,
    limit_high_flags: u8,
    base_high: u8,
    base_upper: u32,
    reserved: u32,

    fn init(base: u64, limit: u20) TssDescriptor {
        return .{
            .limit_low = @truncate(limit),
            .base_low = @truncate(base),
            .base_mid = @truncate(base >> 16),
            .access = Access.TSS_AVAILABLE,
            .limit_high_flags = @as(u8, @truncate(limit >> 16)) & 0x0F,
            .base_high = @truncate(base >> 24),
            .base_upper = @truncate(base >> 32),
            .reserved = 0,
        };
    }
};

/// Task State Segment - required for privilege level switching
/// Uses extern struct for C ABI layout (matches hardware TSS format)
pub const Tss = extern struct {
    reserved0: u32 align(1) = 0,
    /// Stack pointers for privilege levels 0-2
    rsp0: u64 align(1) = 0,
    rsp1: u64 align(1) = 0,
    rsp2: u64 align(1) = 0,
    reserved1: u64 align(1) = 0,
    /// Interrupt stack table (IST) pointers
    ist1: u64 align(1) = 0,
    ist2: u64 align(1) = 0,
    ist3: u64 align(1) = 0,
    ist4: u64 align(1) = 0,
    ist5: u64 align(1) = 0,
    ist6: u64 align(1) = 0,
    ist7: u64 align(1) = 0,
    reserved2: u64 align(1) = 0,
    reserved3: u16 align(1) = 0,
    /// I/O map base address
    iopb_offset: u16 align(1) = 104, // sizeof(Tss) = 104 bytes

    pub fn setKernelStack(self: *Tss, stack: u64) void {
        self.rsp0 = stack;
    }

    pub fn setIst(self: *Tss, index: u3, stack: u64) void {
        switch (index) {
            1 => self.ist1 = stack,
            2 => self.ist2 = stack,
            3 => self.ist3 = stack,
            4 => self.ist4 = stack,
            5 => self.ist5 = stack,
            6 => self.ist6 = stack,
            7 => self.ist7 = stack,
            0 => {},
        }
    }
};

/// GDT structure with all entries
const Gdt = packed struct {
    null_desc: GdtEntry, // 0x00
    kernel_code: GdtEntry, // 0x08
    kernel_data: GdtEntry, // 0x10
    user_data: GdtEntry, // 0x18 (must be before user_code for sysret)
    user_code: GdtEntry, // 0x20
    tss_low: GdtEntry, // 0x28 (TSS is 16 bytes, spans two entries)
    tss_high: GdtEntry, // 0x30
};

/// GDT pointer structure for LGDT instruction
const GdtPointer = packed struct {
    limit: u16,
    base: u64,
};

// Static GDT and TSS instances
var gdt: Gdt = undefined;
var tss: Tss = Tss{};
var gdt_pointer: GdtPointer = undefined;

/// Initialize the GDT with all required segments
pub fn init() void {
    // Null descriptor
    gdt.null_desc = GdtEntry.empty();

    // Kernel code: base=0, limit=max, executable, ring 0, 64-bit
    gdt.kernel_code = GdtEntry.segment(0, 0xFFFFF, Access.KERNEL_CODE, Flags.LONG_MODE | Flags.GRANULARITY);

    // Kernel data: base=0, limit=max, writable, ring 0
    gdt.kernel_data = GdtEntry.segment(0, 0xFFFFF, Access.KERNEL_DATA, Flags.GRANULARITY);

    // User data: base=0, limit=max, writable, ring 3
    gdt.user_data = GdtEntry.segment(0, 0xFFFFF, Access.USER_DATA, Flags.GRANULARITY);

    // User code: base=0, limit=max, executable, ring 3, 64-bit
    gdt.user_code = GdtEntry.segment(0, 0xFFFFF, Access.USER_CODE, Flags.LONG_MODE | Flags.GRANULARITY);

    // TSS descriptor (16 bytes)
    const tss_addr = @intFromPtr(&tss);
    const tss_desc = TssDescriptor.init(tss_addr, @sizeOf(Tss) - 1);
    gdt.tss_low = @bitCast(@as(u64, @truncate(@as(u128, @bitCast(tss_desc)))));
    gdt.tss_high = @bitCast(@as(u64, @truncate(@as(u128, @bitCast(tss_desc)) >> 64)));

    // Set up GDT pointer
    gdt_pointer = .{
        .limit = @sizeOf(Gdt) - 1,
        .base = @intFromPtr(&gdt),
    };

    // Load GDT
    loadGdt();

    // Load TSS
    loadTss();
}

/// Set the kernel stack pointer in TSS (used for ring 3 -> ring 0 transitions)
pub fn setKernelStack(stack: u64) void {
    tss.setKernelStack(stack);
}

/// Set an IST entry for interrupt handling with separate stack
pub fn setInterruptStack(ist_index: u3, stack: u64) void {
    tss.setIst(ist_index, stack);
}

fn loadGdt() void {
    // Load GDT
    asm volatile ("lgdt (%[gdt_ptr])"
        :
        : [gdt_ptr] "r" (&gdt_pointer),
    );

    // Reload code segment by far return
    // We clobber rax, so declare it as an output
    var dummy_rax: u64 = undefined;
    asm volatile (
        \\push %[kernel_code]
        \\lea 1f(%%rip), %%rax
        \\push %%rax
        \\lretq
        \\1:
        : [_] "={rax}" (dummy_rax),
        : [kernel_code] "i" (@as(u64, Selector.KERNEL_CODE)),
    );

    // Reload data segments
    // We clobber rax (via ax), so declare it as an output
    asm volatile (
        \\mov %[kernel_data], %%ax
        \\mov %%ax, %%ds
        \\mov %%ax, %%es
        \\mov %%ax, %%fs
        \\mov %%ax, %%gs
        \\mov %%ax, %%ss
        : [_] "={rax}" (dummy_rax),
        : [kernel_data] "i" (@as(u16, Selector.KERNEL_DATA)),
    );
}

fn loadTss() void {
    asm volatile ("ltr %[tss_sel]"
        :
        : [tss_sel] "r" (Selector.TSS),
    );
}
