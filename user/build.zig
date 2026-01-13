// Graphene User Space Build Configuration
const std = @import("std");

pub fn build(b: *std.Build) void {
    // Target: freestanding x86_64 (no OS)
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    });

    const optimize = b.standardOptimizeOption(.{});

    // Shared syscall module
    const syscall_module = b.createModule(.{
        .root_source_file = b.path("lib/syscall.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Build init process
    const init = b.addExecutable(.{
        .name = "init",
        .root_source_file = b.path("init/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    init.root_module.addImport("syscall", syscall_module);
    init.setLinkerScript(b.path("linker-user.ld"));
    init.root_module.red_zone = false;
    init.root_module.stack_check = false;

    b.installArtifact(init);

    // Build keyboard driver
    const kbd = b.addExecutable(.{
        .name = "kbd",
        .root_source_file = b.path("drivers/kbd/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    kbd.root_module.addImport("syscall", syscall_module);
    kbd.setLinkerScript(b.path("linker-user.ld"));
    kbd.root_module.red_zone = false;
    kbd.root_module.stack_check = false;

    b.installArtifact(kbd);
}
