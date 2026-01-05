// Limine bootloader protocol bindings for Zig 0.15+
// Based on limine-zig, modified to remove deprecated usingnamespace

const builtin = @import("builtin");
const std = @import("std");

// Configuration - hardcoded for our kernel
const api_revision: u64 = 3;
const no_pointers = false;
const allow_deprecated = false;

pub const Arch = enum {
    x86_64,
    aarch64,
    riscv64,
    loongarch64,
};

pub const arch: Arch = switch (builtin.cpu.arch) {
    .x86_64 => .x86_64,
    .aarch64 => .aarch64,
    .riscv64 => .riscv64,
    .loongarch64 => .loongarch64,
    else => |arch_tag| @compileError("Unsupported architecture: " ++ @tagName(arch_tag)),
};

fn id(a: u64, b: u64) [4]u64 {
    return .{ 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b, a, b };
}

fn LiminePtr(comptime Type: type) type {
    return if (no_pointers) u64 else Type;
}

const init_pointer = if (no_pointers) 0 else null;

pub const RequestsStartMarker = extern struct {
    marker: [4]u64 = .{
        0xf6b8f4b39de7d1ae,
        0xfab91a6940fcb9cf,
        0x785c6ed015d3e316,
        0x181e920a7852b9d9,
    },
};

pub const RequestsEndMarker = extern struct {
    marker: [2]u64 = .{ 0xadc0e0531bb10d03, 0x9572709f31764c62 },
};

pub const BaseRevision = extern struct {
    magic: [2]u64 = .{ 0xf9562b2d5c95a6c8, 0x6a7b384944536bdc },
    revision: u64,

    pub fn is_supported(self: @This()) bool {
        return self.revision == 0;
    }
};

pub const Uuid = extern struct {
    a: u32,
    b: u16,
    c: u16,
    d: [8]u8,
};

pub const MediaType = enum(u32) {
    generic = 0,
    optical = 1,
    tftp = 2,
    _,
};

pub const File = extern struct {
    revision: u64,
    address: LiminePtr(*align(4096) anyopaque),
    size: u64,
    path: LiminePtr([*:0]u8),
    string: LiminePtr([*:0]u8),
    media_type: MediaType,
    unused: u32,
    tftp_ip: u32,
    tftp_port: u32,
    partition_index: u32,
    mbr_disk_id: u32,
    gpt_disk_uuid: Uuid,
    gpt_part_uuid: Uuid,
    part_uuid: Uuid,
};

// Boot info

pub const BootloaderInfoResponse = extern struct {
    revision: u64,
    name: LiminePtr([*:0]u8),
    version: LiminePtr([*:0]u8),
};

pub const BootloaderInfoRequest = extern struct {
    id: [4]u64 = id(0xf55038d8e2a1202f, 0x279426fcf5f59740),
    revision: u64 = 0,
    response: LiminePtr(?*BootloaderInfoResponse) = init_pointer,
};

// HHDM

pub const HhdmResponse = extern struct {
    revision: u64,
    offset: u64,
};

pub const HhdmRequest = extern struct {
    id: [4]u64 = id(0x48dcf1cb8ad2b852, 0x63984e959a98244b),
    revision: u64 = 0,
    response: LiminePtr(?*HhdmResponse) = init_pointer,
};

// Framebuffer

pub const FramebufferMemoryModel = enum(u8) {
    rgb = 1,
    _,
};

pub const VideoMode = extern struct {
    pitch: u64,
    width: u64,
    height: u64,
    bpp: u16,
    memory_model: FramebufferMemoryModel,
    red_mask_size: u8,
    red_mask_shift: u8,
    green_mask_size: u8,
    green_mask_shift: u8,
    blue_mask_size: u8,
    blue_mask_shift: u8,
};

pub const Framebuffer = extern struct {
    address: LiminePtr(*anyopaque),
    width: u64,
    height: u64,
    pitch: u64,
    bpp: u16,
    memory_model: FramebufferMemoryModel,
    red_mask_size: u8,
    red_mask_shift: u8,
    green_mask_size: u8,
    green_mask_shift: u8,
    blue_mask_size: u8,
    blue_mask_shift: u8,
    edid_size: u64,
    edid: LiminePtr(?*anyopaque),
    mode_count: u64,
    modes: LiminePtr([*]*VideoMode),
};

pub const FramebufferResponse = extern struct {
    revision: u64,
    framebuffer_count: u64,
    framebuffers_ptr: LiminePtr(?[*]*Framebuffer),

    pub fn framebuffers(self: *const @This()) []*Framebuffer {
        if (self.framebuffer_count == 0 or self.framebuffers_ptr == null) {
            return &.{};
        }
        return self.framebuffers_ptr.?[0..self.framebuffer_count];
    }
};

pub const FramebufferRequest = extern struct {
    id: [4]u64 = id(0x9d5827dcd881dd75, 0xa3148604f6fab11b),
    revision: u64 = 1,
    response: LiminePtr(?*FramebufferResponse) = init_pointer,
};

// Paging mode

pub const PagingMode = enum(u64) {
    four_level = 0,
    five_level = 1,
    _,
};

pub const PagingModeResponse = extern struct {
    revision: u64,
    mode: PagingMode,
};

pub const PagingModeRequest = extern struct {
    id: [4]u64 = id(0x95c1a0edab0944cb, 0xa4e5cb3842f7488a),
    revision: u64 = 0,
    response: LiminePtr(?*PagingModeResponse) = init_pointer,
    mode: PagingMode = .four_level,
    max_mode: PagingMode = .five_level,
    min_mode: PagingMode = .four_level,
};

// MP (Multi-Processor)

pub const GotoAddress = *const fn (*MpInfo) callconv(.c) noreturn;

pub const MpFlags = packed struct(u32) {
    x2apic: bool = false,
    reserved: u31 = 0,
};

pub const MpInfo = extern struct {
    processor_id: u32,
    lapic_id: u32,
    reserved: u64,
    goto_address: LiminePtr(?GotoAddress),
    extra_argument: u64,
};

pub const MpResponse = extern struct {
    revision: u64,
    flags: MpFlags,
    bsp_lapic_id: u32,
    cpu_count: u64,
    cpus: LiminePtr(?[*]*MpInfo),

    pub fn getCpus(self: @This()) []*MpInfo {
        if (self.cpu_count == 0 or self.cpus == null) {
            return &.{};
        }
        return self.cpus.?[0..self.cpu_count];
    }
};

pub const MpRequest = extern struct {
    id: [4]u64 = id(0x95a67b819a1b857e, 0xa0b61b723b6a73e0),
    revision: u64 = 0,
    response: LiminePtr(?*MpResponse) = init_pointer,
    flags: MpFlags = .{},
    reserved: u32 = 0,
};

// Memory map

pub const MemoryMapType = enum(u64) {
    usable = 0,
    reserved = 1,
    acpi_reclaimable = 2,
    acpi_nvs = 3,
    bad_memory = 4,
    bootloader_reclaimable = 5,
    executable_and_modules = 6,
    framebuffer = 7,
    _,
};

pub const MemoryMapEntry = extern struct {
    base: u64,
    length: u64,
    type: MemoryMapType,
};

pub const MemoryMapResponse = extern struct {
    revision: u64,
    entry_count: u64,
    entries: LiminePtr(?[*]*MemoryMapEntry),

    pub fn getEntries(self: @This()) []*MemoryMapEntry {
        if (self.entry_count == 0 or self.entries == null) {
            return &.{};
        }
        return self.entries.?[0..self.entry_count];
    }
};

pub const MemoryMapRequest = extern struct {
    id: [4]u64 = id(0x67cf3d9d378a806f, 0xe304acdfc50c3c62),
    revision: u64 = 0,
    response: LiminePtr(?*MemoryMapResponse) = init_pointer,
};

// Entry point

pub const EntryPoint = *const fn () callconv(.c) noreturn;

pub const EntryPointResponse = extern struct {
    revision: u64,
};

pub const EntryPointRequest = extern struct {
    id: [4]u64 = id(0x13d86c035a1cd3e1, 0x2b0caa89d8f3026a),
    revision: u64 = 0,
    response: LiminePtr(?*EntryPointResponse) = init_pointer,
    entry: LiminePtr(EntryPoint),
};

// Executable file

pub const ExecutableFileResponse = extern struct {
    revision: u64,
    executable_file: LiminePtr(*File),
};

pub const ExecutableFileRequest = extern struct {
    id: [4]u64 = id(0xad97e90e83f1ed67, 0x31eb5d1c5ff23b69),
    revision: u64 = 0,
    response: LiminePtr(?*ExecutableFileResponse) = init_pointer,
};

// Module

pub const InternalModuleFlag = packed struct(u64) {
    required: bool,
    compressed: bool,
    reserved: u62 = 0,
};

pub const InternalModule = extern struct {
    path: LiminePtr([*:0]const u8),
    string: LiminePtr([*:0]const u8),
    flags: InternalModuleFlag,
};

pub const ModuleResponse = extern struct {
    revision: u64,
    module_count: u64,
    modules: LiminePtr(?[*]*File),

    pub fn getModules(self: @This()) []*File {
        if (self.module_count == 0 or self.modules == null) {
            return &.{};
        }
        return self.modules.?[0..self.module_count];
    }
};

pub const ModuleRequest = extern struct {
    id: [4]u64 = id(0x3e7e279702be32af, 0xca1c4f3bd1280cee),
    revision: u64 = 1,
    response: LiminePtr(?*ModuleResponse) = init_pointer,
    internal_module_count: u64 = 0,
    internal_modules: LiminePtr(?[*]const *const InternalModule) = null,
};

// RSDP

pub const RsdpResponse = extern struct {
    revision: u64,
    address: u64,
};

pub const RsdpRequest = extern struct {
    id: [4]u64 = id(0xc5e77b6b397e7b43, 0x27637845accdcf3c),
    revision: u64 = 0,
    response: LiminePtr(?*RsdpResponse) = init_pointer,
};

// Executable address

pub const ExecutableAddressResponse = extern struct {
    revision: u64,
    physical_base: u64,
    virtual_base: u64,
};

pub const ExecutableAddressRequest = extern struct {
    id: [4]u64 = id(0x71ba76863cc55f63, 0xb2644a48c516a487),
    revision: u64 = 0,
    response: LiminePtr(?*ExecutableAddressResponse) = init_pointer,
};

// Date at boot

pub const DateAtBootResponse = extern struct {
    revision: u64,
    timestamp: i64,
};

pub const DateAtBootRequest = extern struct {
    id: [4]u64 = id(0x502746e184c088aa, 0xfbc5ec83e6327893),
    revision: u64 = 0,
    response: LiminePtr(?*DateAtBootResponse) = init_pointer,
};
