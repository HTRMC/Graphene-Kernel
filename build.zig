const std = @import("std");

pub fn build(b: *std.Build) void {
    // Freestanding x86_64 target for kernel
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    });

    const optimize = b.standardOptimizeOption(.{});

    // Kernel executable
    const kernel = b.addExecutable(.{
        .name = "graphene",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .kernel,
    });

    // Disable stack protector (not available in freestanding)
    kernel.root_module.stack_protector = false;

    // Use custom linker script
    kernel.setLinkerScript(b.path("linker.ld"));

    // Install the kernel binary
    b.installArtifact(kernel);

    // Limine bootloader dependency
    const limine = b.dependency("limine", .{});
    kernel.root_module.addImport("limine", limine.module("limine"));

    // Build ISO step
    const iso_cmd = b.addSystemCommand(&.{
        "cmd", "/c", "scripts\\build-iso.bat",
    });
    iso_cmd.step.dependOn(b.getInstallStep());

    const iso_step = b.step("iso", "Build bootable ISO image");
    iso_step.dependOn(&iso_cmd.step);

    // Run in QEMU step
    const qemu_cmd = b.addSystemCommand(&.{
        "qemu-system-x86_64",
        "-M", "q35",
        "-m", "256M",
        "-serial", "stdio",
        "-bios", "ovmf/OVMF.fd",
        "-cdrom", "zig-out/graphene.iso",
        "-boot", "d",
    });
    qemu_cmd.step.dependOn(iso_step);

    const run_step = b.step("run", "Build ISO and run in QEMU");
    run_step.dependOn(&qemu_cmd.step);
}
