const std = @import("std");

pub fn build(b: *std.Build) void {
    // Freestanding x86_64 target for kernel (matches limine-zig-template)
    var query: std.Target.Query = .{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    };

    // Disable SIMD features that require state saving in kernel mode
    // Keep x87 FPU enabled as compiler-rt may need it
    // The template adds popcnt and soft_float, and subtracts only SIMD features
    const Target = std.Target.x86;
    query.cpu_features_add = Target.featureSet(&.{ .popcnt, .soft_float });
    query.cpu_features_sub = Target.featureSet(&.{ .avx, .avx2, .sse, .sse2, .mmx });

    const target = b.resolveTargetQuery(query);
    const optimize = b.standardOptimizeOption(.{});

    // Create root module for kernel
    const kernel_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Set kernel-specific options (must be set after module creation)
    kernel_module.red_zone = false;
    kernel_module.code_model = .kernel;

    // Kernel executable
    const kernel = b.addExecutable(.{
        .name = "graphene",
        .root_module = kernel_module,
    });

    // Use custom linker script
    kernel.setLinkerScript(b.path("linker.ld"));

    // Enable verbose linking to debug
    kernel.verbose_link = true;

    // Install the kernel binary
    b.installArtifact(kernel);

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
