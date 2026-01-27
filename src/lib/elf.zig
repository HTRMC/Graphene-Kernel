// Graphene Kernel - ELF64 Loader
// Parses and loads ELF64 executables with W^X enforcement

const std = @import("std");
const builtin = @import("builtin");
const vmm = @import("vmm.zig");
const pmm = @import("pmm.zig");
const serial = @import("serial.zig");

/// Debug logging - only enabled in Debug builds
const debug_enabled = builtin.mode == .Debug;

fn debugPrint(comptime fmt: []const u8) void {
    if (debug_enabled) {
        serial.println(fmt);
    }
}

fn debugPuts(str: []const u8) void {
    if (debug_enabled) {
        serial.puts(str);
    }
}

fn debugHex(value: u64) void {
    if (debug_enabled) {
        serial.putHex(value);
    }
}

fn debugDec(value: u64) void {
    if (debug_enabled) {
        serial.putDec(value);
    }
}

/// ELF magic number
const ELF_MAGIC = [4]u8{ 0x7F, 'E', 'L', 'F' };

/// ELF class (32/64 bit)
const ELFCLASS64: u8 = 2;

/// ELF data encoding
const ELFDATA2LSB: u8 = 1; // Little endian

/// ELF type
const ET_EXEC: u16 = 2; // Executable
const ET_DYN: u16 = 3; // Shared object (PIE)

/// ELF machine type
const EM_X86_64: u16 = 0x3E;

/// Program header types
const PT_NULL: u32 = 0;
const PT_LOAD: u32 = 1;
const PT_DYNAMIC: u32 = 2;
const PT_INTERP: u32 = 3;
const PT_NOTE: u32 = 4;
const PT_PHDR: u32 = 6;

/// Program header flags
const PF_X: u32 = 1; // Execute
const PF_W: u32 = 2; // Write
const PF_R: u32 = 4; // Read

/// ELF64 file header
pub const Elf64Header = extern struct {
    e_ident: [16]u8, // Magic number and other info
    e_type: u16, // Object file type
    e_machine: u16, // Architecture
    e_version: u32, // Object file version
    e_entry: u64, // Entry point virtual address
    e_phoff: u64, // Program header table file offset
    e_shoff: u64, // Section header table file offset
    e_flags: u32, // Processor-specific flags
    e_ehsize: u16, // ELF header size in bytes
    e_phentsize: u16, // Program header table entry size
    e_phnum: u16, // Program header table entry count
    e_shentsize: u16, // Section header table entry size
    e_shnum: u16, // Section header table entry count
    e_shstrndx: u16, // Section header string table index
};

/// ELF64 program header
pub const Elf64ProgramHeader = extern struct {
    p_type: u32, // Segment type
    p_flags: u32, // Segment flags
    p_offset: u64, // Segment file offset
    p_vaddr: u64, // Segment virtual address
    p_paddr: u64, // Segment physical address
    p_filesz: u64, // Segment size in file
    p_memsz: u64, // Segment size in memory
    p_align: u64, // Segment alignment
};

/// ELF loading errors
pub const ElfError = error{
    InvalidMagic,
    InvalidClass,
    InvalidEndian,
    InvalidType,
    InvalidMachine,
    InvalidVersion,
    TooSmall,
    InvalidProgramHeader,
    SegmentOutOfBounds,
    WXViolation,
    LoadFailed,
    OutOfMemory,
};

/// Result of loading an ELF
pub const LoadResult = struct {
    entry_point: u64,
    highest_address: u64,
    lowest_address: u64,
};

/// Validate ELF header
pub fn validateHeader(data: []const u8) ElfError!*const Elf64Header {
    // Check minimum size for header
    if (data.len < @sizeOf(Elf64Header)) {
        return ElfError.TooSmall;
    }

    const header: *const Elf64Header = @ptrCast(@alignCast(data.ptr));

    // Check magic number
    if (header.e_ident[0] != ELF_MAGIC[0] or
        header.e_ident[1] != ELF_MAGIC[1] or
        header.e_ident[2] != ELF_MAGIC[2] or
        header.e_ident[3] != ELF_MAGIC[3])
    {
        return ElfError.InvalidMagic;
    }

    // Check 64-bit
    if (header.e_ident[4] != ELFCLASS64) {
        return ElfError.InvalidClass;
    }

    // Check little endian
    if (header.e_ident[5] != ELFDATA2LSB) {
        return ElfError.InvalidEndian;
    }

    // Check executable type
    if (header.e_type != ET_EXEC and header.e_type != ET_DYN) {
        return ElfError.InvalidType;
    }

    // Check x86_64
    if (header.e_machine != EM_X86_64) {
        return ElfError.InvalidMachine;
    }

    // Check version
    if (header.e_version != 1) {
        return ElfError.InvalidVersion;
    }

    // Check program header validity
    if (header.e_phnum == 0 or header.e_phentsize < @sizeOf(Elf64ProgramHeader)) {
        return ElfError.InvalidProgramHeader;
    }

    // Check program headers fit in file
    const ph_end = header.e_phoff + @as(u64, header.e_phnum) * @as(u64, header.e_phentsize);
    if (ph_end > data.len) {
        return ElfError.InvalidProgramHeader;
    }

    return header;
}

/// Get program headers from ELF data
pub fn getProgramHeaders(header: *const Elf64Header, data: []const u8) []const Elf64ProgramHeader {
    const ph_offset = header.e_phoff;
    const ph_count = header.e_phnum;

    const ph_ptr: [*]const Elf64ProgramHeader = @ptrCast(@alignCast(data.ptr + ph_offset));
    return ph_ptr[0..ph_count];
}

/// Load ELF into address space
pub fn load(space: *vmm.AddressSpace, data: []const u8) ElfError!LoadResult {
    const header = try validateHeader(data);
    const program_headers = getProgramHeaders(header, data);

    var highest: u64 = 0;
    var lowest: u64 = 0xFFFFFFFFFFFFFFFF;

    // First pass: validate all segments
    for (program_headers) |ph| {
        if (ph.p_type != PT_LOAD) continue;

        // Check for W^X violation
        if ((ph.p_flags & PF_W) != 0 and (ph.p_flags & PF_X) != 0) {
            return ElfError.WXViolation;
        }

        // Check segment bounds
        if (ph.p_offset + ph.p_filesz > data.len) {
            return ElfError.SegmentOutOfBounds;
        }

        // Check virtual address is in user space
        if (ph.p_vaddr < vmm.USER_BASE or ph.p_vaddr + ph.p_memsz > vmm.USER_TOP) {
            return ElfError.SegmentOutOfBounds;
        }

        // Track address range
        if (ph.p_vaddr < lowest) {
            lowest = ph.p_vaddr;
        }
        if (ph.p_vaddr + ph.p_memsz > highest) {
            highest = ph.p_vaddr + ph.p_memsz;
        }
    }

    // Second pass: load segments
    for (program_headers) |ph| {
        if (ph.p_type != PT_LOAD) continue;

        try loadSegment(space, data, &ph);
    }

    return LoadResult{
        .entry_point = header.e_entry,
        .highest_address = highest,
        .lowest_address = lowest,
    };
}

/// Load a single segment
fn loadSegment(space: *vmm.AddressSpace, data: []const u8, ph: *const Elf64ProgramHeader) ElfError!void {
    const vaddr_start = ph.p_vaddr & ~@as(u64, 0xFFF); // Page-align down
    const vaddr_end = (ph.p_vaddr + ph.p_memsz + 0xFFF) & ~@as(u64, 0xFFF); // Page-align up
    const num_pages = (vaddr_end - vaddr_start) / 0x1000;

    debugPuts("[ELF] Loading segment at vaddr ");
    debugHex(vaddr_start);
    debugPuts(", ");
    debugDec(num_pages);
    debugPuts(" pages\n");

    // Convert ELF flags to VMM flags
    var flags = vmm.MapFlags{
        .user = true,
        .writable = (ph.p_flags & PF_W) != 0,
        .executable = (ph.p_flags & PF_X) != 0,
    };

    // Allocate and map pages
    var page: u64 = 0;
    while (page < num_pages) : (page += 1) {
        const vaddr = vaddr_start + page * 0x1000;

        // Allocate physical frame
        const frame = pmm.allocFrame() orelse return ElfError.OutOfMemory;

        debugPuts("[ELF] Page ");
        debugDec(page);
        debugPuts(": vaddr=");
        debugHex(vaddr);
        debugPuts(" frame=");
        debugHex(frame);
        debugPuts("\n");

        // Map with write permission initially (for copying data)
        var temp_flags = flags;
        temp_flags.writable = true;

        debugPrint("[ELF] Mapping page...");
        space.mapPage(vaddr, frame, temp_flags) catch {
            pmm.freeFrame(frame);
            return ElfError.LoadFailed;
        };
        debugPrint("[ELF] Page mapped, zeroing...");

        // Zero the page first
        const page_ptr = pmm.physToVirt(frame);
        debugPuts("[ELF] Zero via HHDM addr: ");
        debugHex(page_ptr);
        debugPuts("\n");
        const page_slice: [*]u8 = @ptrFromInt(page_ptr);
        for (0..0x1000) |i| {
            page_slice[i] = 0;
        }
        debugPrint("[ELF] Page zeroed, copying data...");

        // Copy file data if this page contains it
        const page_start = vaddr;
        const page_end = vaddr + 0x1000;
        const seg_file_start = ph.p_vaddr;
        const seg_file_end = ph.p_vaddr + ph.p_filesz;

        if (page_end > seg_file_start and page_start < seg_file_end) {
            // Calculate overlap
            const copy_start = @max(page_start, seg_file_start);
            const copy_end = @min(page_end, seg_file_end);
            const copy_len = copy_end - copy_start;

            // Calculate offsets
            const page_offset = copy_start - page_start;
            const file_offset = ph.p_offset + (copy_start - ph.p_vaddr);

            debugPuts("[ELF] Copying ");
            debugDec(copy_len);
            debugPuts(" bytes from offset ");
            debugDec(file_offset);
            debugPuts("\n");

            // Copy data
            const src = data[file_offset..][0..copy_len];
            for (0..copy_len) |i| {
                page_slice[page_offset + i] = src[i];
            }
            debugPrint("[ELF] Copy done");
        }
        debugPrint("[ELF] Page complete");
    }

    // Remap with correct permissions if needed (remove write for RX segments)
    if (!flags.writable and flags.executable) {
        page = 0;
        while (page < num_pages) : (page += 1) {
            const vaddr = vaddr_start + page * 0x1000;
            // Get physical address and remap with correct flags
            if (space.translate(vaddr)) |paddr| {
                // Unmap and remap with correct flags
                space.unmapPage(vaddr);
                space.mapPage(vaddr, paddr, flags) catch {
                    return ElfError.LoadFailed;
                };
            }
        }
    }
}

/// Check if data looks like an ELF file
pub fn isElf(data: []const u8) bool {
    if (data.len < 4) return false;
    return data[0] == ELF_MAGIC[0] and
        data[1] == ELF_MAGIC[1] and
        data[2] == ELF_MAGIC[2] and
        data[3] == ELF_MAGIC[3];
}

/// Get entry point from ELF without full loading
pub fn getEntryPoint(data: []const u8) ElfError!u64 {
    const header = try validateHeader(data);
    return header.e_entry;
}
