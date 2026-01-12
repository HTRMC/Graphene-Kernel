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

    // Build init process
    const init = b.addExecutable(.{
        .name = "init",
        .root_source_file = b.path("init/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add library modules
    init.root_module.addImport("syscall", b.createModule(.{
        .root_source_file = b.path("lib/syscall.zig"),
        .target = target,
        .optimize = optimize,
    }));

    // Use custom linker script
    init.setLinkerScript(b.path("linker-user.ld"));

    // Disable standard library features not available in freestanding
    init.root_module.red_zone = false;
    init.root_module.stack_check = false;

    // Install the binary
    b.installArtifact(init);

    // Create raw binary for embedding
    const init_raw = init.addObjCopy(.{
        .format = .bin,
    });
    const install_raw = b.addInstallBinFile(init_raw.getOutput(), "init.bin");
    b.getInstallStep().dependOn(&install_raw.step);
}
