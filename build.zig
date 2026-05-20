const std = @import("std");

pub fn build(b: *std.Build) void {
    // Freestanding x86_64 target for kernel (matches limine-zig-template)
    var kernel_query: std.Target.Query = .{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    };

    // Disable SIMD features that require state saving in kernel mode
    // Keep x87 FPU enabled as compiler-rt may need it
    // The template adds popcnt and soft_float, and subtracts only SIMD features
    const Target = std.Target.x86;
    kernel_query.cpu_features_add = Target.featureSet(&.{ .popcnt, .soft_float });
    kernel_query.cpu_features_sub = Target.featureSet(&.{ .avx, .avx2, .sse, .sse2, .mmx });

    const kernel_target = b.resolveTargetQuery(kernel_query);
    // Note: Using hardcoded ReleaseSafe to avoid ubsan SSE issues with freestanding target
    _ = b.standardOptimizeOption(.{});

    // Create root module for kernel
    const kernel_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = kernel_target,
        // Use ReleaseSafe to avoid ubsan using SSE in Debug mode
        .optimize = .ReleaseSafe,
        .strip = true,
        .unwind_tables = .none,
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

    // Install the kernel binary
    b.installArtifact(kernel);

    // ========================================
    // User space: init process
    // ========================================
    var user_query: std.Target.Query = .{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    };
    // Disable SIMD and use soft float for user space
    user_query.cpu_features_add = Target.featureSet(&.{.soft_float});
    user_query.cpu_features_sub = Target.featureSet(&.{ .avx, .avx2, .sse, .sse2, .mmx });

    const user_target = b.resolveTargetQuery(user_query);

    // User syscall library module
    const syscall_module = b.createModule(.{
        .root_source_file = b.path("user/lib/syscall.zig"),
        .target = user_target,
        .optimize = .ReleaseSafe,
        .strip = true,
    });

    // Shared VFS protocol module (depends on syscall)
    const vfs_module = b.createModule(.{
        .root_source_file = b.path("user/lib/vfs.zig"),
        .target = user_target,
        .optimize = .ReleaseSafe,
        .strip = true,
        .imports = &.{
            .{ .name = "syscall", .module = syscall_module },
        },
    });

    // Shared logger protocol module (depends on syscall)
    const log_module = b.createModule(.{
        .root_source_file = b.path("user/lib/log.zig"),
        .target = user_target,
        .optimize = .ReleaseSafe,
        .strip = true,
        .imports = &.{
            .{ .name = "syscall", .module = syscall_module },
        },
    });

    // Shared block-device protocol module (depends on syscall)
    const blk_module = b.createModule(.{
        .root_source_file = b.path("user/lib/blk.zig"),
        .target = user_target,
        .optimize = .ReleaseSafe,
        .strip = true,
        .imports = &.{
            .{ .name = "syscall", .module = syscall_module },
        },
    });

    // Init process module (start.zig is root, calls main from init)
    const init_main_module = b.createModule(.{
        .root_source_file = b.path("user/init/main.zig"),
        .target = user_target,
        .optimize = .ReleaseSafe,
        .strip = true,
        .imports = &.{
            .{ .name = "syscall", .module = syscall_module },
        },
    });

    const init_module = b.createModule(.{
        .root_source_file = b.path("user/lib/start.zig"),
        .target = user_target,
        .optimize = .ReleaseSafe,
        .strip = true,
        .unwind_tables = .none,
        .imports = &.{
            .{ .name = "syscall", .module = syscall_module },
            .{ .name = "main", .module = init_main_module },
        },
    });

    init_module.red_zone = false;

    // Init executable
    const init = b.addExecutable(.{
        .name = "init",
        .root_module = init_module,
    });

    // Use user linker script
    init.setLinkerScript(b.path("user/linker-user.ld"));

    // Install init binary
    b.installArtifact(init);

    // ========================================
    // User space: shell process
    // ========================================
    const shell_main_module = b.createModule(.{
        .root_source_file = b.path("user/shell/main.zig"),
        .target = user_target,
        .optimize = .ReleaseSafe,
        .strip = true,
        .imports = &.{
            .{ .name = "syscall", .module = syscall_module },
            .{ .name = "vfs", .module = vfs_module },
            .{ .name = "log", .module = log_module },
        },
    });

    const shell_module = b.createModule(.{
        .root_source_file = b.path("user/lib/start.zig"),
        .target = user_target,
        .optimize = .ReleaseSafe,
        .strip = true,
        .unwind_tables = .none,
        .imports = &.{
            .{ .name = "syscall", .module = syscall_module },
            .{ .name = "main", .module = shell_main_module },
        },
    });

    shell_module.red_zone = false;

    // Shell executable
    const shell = b.addExecutable(.{
        .name = "shell",
        .root_module = shell_module,
    });

    // Use user linker script
    shell.setLinkerScript(b.path("user/linker-user.ld"));

    // Install shell binary
    b.installArtifact(shell);

    // ========================================
    // User space: keyboard driver
    // ========================================
    const kbd_main_module = b.createModule(.{
        .root_source_file = b.path("user/drivers/kbd/main.zig"),
        .target = user_target,
        .optimize = .ReleaseSafe,
        .strip = true,
        .imports = &.{
            .{ .name = "syscall", .module = syscall_module },
            .{ .name = "vfs", .module = vfs_module },
        },
    });

    const kbd_module = b.createModule(.{
        .root_source_file = b.path("user/lib/start.zig"),
        .target = user_target,
        .optimize = .ReleaseSafe,
        .strip = true,
        .unwind_tables = .none,
        .imports = &.{
            .{ .name = "syscall", .module = syscall_module },
            .{ .name = "main", .module = kbd_main_module },
        },
    });

    kbd_module.red_zone = false;

    // Keyboard driver executable
    const kbd = b.addExecutable(.{
        .name = "kbd",
        .root_module = kbd_module,
    });

    // Use user linker script
    kbd.setLinkerScript(b.path("user/linker-user.ld"));

    // Install kbd binary
    b.installArtifact(kbd);

    // ========================================
    // User space: ramfs service
    // ========================================
    const ramfs_main_module = b.createModule(.{
        .root_source_file = b.path("user/services/ramfs/main.zig"),
        .target = user_target,
        .optimize = .ReleaseSafe,
        .strip = true,
        .imports = &.{
            .{ .name = "syscall", .module = syscall_module },
            .{ .name = "vfs", .module = vfs_module },
        },
    });

    const ramfs_module = b.createModule(.{
        .root_source_file = b.path("user/lib/start.zig"),
        .target = user_target,
        .optimize = .ReleaseSafe,
        .strip = true,
        .unwind_tables = .none,
        .imports = &.{
            .{ .name = "syscall", .module = syscall_module },
            .{ .name = "main", .module = ramfs_main_module },
        },
    });

    ramfs_module.red_zone = false;

    // Ramfs service executable
    const ramfs = b.addExecutable(.{
        .name = "ramfs",
        .root_module = ramfs_module,
    });

    // Use user linker script
    ramfs.setLinkerScript(b.path("user/linker-user.ld"));

    // Install ramfs binary
    b.installArtifact(ramfs);

    // ========================================
    // User space: logger service
    // ========================================
    const logger_main_module = b.createModule(.{
        .root_source_file = b.path("user/services/logger/main.zig"),
        .target = user_target,
        .optimize = .ReleaseSafe,
        .strip = true,
        .imports = &.{
            .{ .name = "syscall", .module = syscall_module },
            .{ .name = "log", .module = log_module },
        },
    });

    const logger_module = b.createModule(.{
        .root_source_file = b.path("user/lib/start.zig"),
        .target = user_target,
        .optimize = .ReleaseSafe,
        .strip = true,
        .unwind_tables = .none,
        .imports = &.{
            .{ .name = "syscall", .module = syscall_module },
            .{ .name = "main", .module = logger_main_module },
        },
    });

    logger_module.red_zone = false;

    const logger = b.addExecutable(.{
        .name = "logger",
        .root_module = logger_module,
    });

    logger.setLinkerScript(b.path("user/linker-user.ld"));

    b.installArtifact(logger);

    // ========================================
    // User space: devfs service
    // ========================================
    const devfs_main_module = b.createModule(.{
        .root_source_file = b.path("user/services/devfs/main.zig"),
        .target = user_target,
        .optimize = .ReleaseSafe,
        .strip = true,
        .imports = &.{
            .{ .name = "syscall", .module = syscall_module },
            .{ .name = "vfs", .module = vfs_module },
            .{ .name = "blk", .module = blk_module },
        },
    });

    const devfs_module = b.createModule(.{
        .root_source_file = b.path("user/lib/start.zig"),
        .target = user_target,
        .optimize = .ReleaseSafe,
        .strip = true,
        .unwind_tables = .none,
        .imports = &.{
            .{ .name = "syscall", .module = syscall_module },
            .{ .name = "main", .module = devfs_main_module },
        },
    });

    devfs_module.red_zone = false;

    const devfs = b.addExecutable(.{
        .name = "devfs",
        .root_module = devfs_module,
    });

    devfs.setLinkerScript(b.path("user/linker-user.ld"));

    b.installArtifact(devfs);

    // ========================================
    // User space: virtio-blk driver service
    // ========================================
    const virtioblk_main_module = b.createModule(.{
        .root_source_file = b.path("user/services/virtioblk/main.zig"),
        .target = user_target,
        .optimize = .ReleaseSafe,
        .strip = true,
        .imports = &.{
            .{ .name = "syscall", .module = syscall_module },
            .{ .name = "blk", .module = blk_module },
        },
    });

    const virtioblk_module = b.createModule(.{
        .root_source_file = b.path("user/lib/start.zig"),
        .target = user_target,
        .optimize = .ReleaseSafe,
        .strip = true,
        .unwind_tables = .none,
        .imports = &.{
            .{ .name = "syscall", .module = syscall_module },
            .{ .name = "main", .module = virtioblk_main_module },
        },
    });

    virtioblk_module.red_zone = false;

    const virtioblk = b.addExecutable(.{
        .name = "virtioblk",
        .root_module = virtioblk_module,
    });

    virtioblk.setLinkerScript(b.path("user/linker-user.ld"));

    b.installArtifact(virtioblk);

    // ========================================
    // User space: fatfs (FAT32 filesystem) service
    // ========================================
    const fatfs_main_module = b.createModule(.{
        .root_source_file = b.path("user/services/fatfs/main.zig"),
        .target = user_target,
        .optimize = .ReleaseSafe,
        .strip = true,
        .imports = &.{
            .{ .name = "syscall", .module = syscall_module },
            .{ .name = "vfs", .module = vfs_module },
            .{ .name = "blk", .module = blk_module },
        },
    });

    const fatfs_module = b.createModule(.{
        .root_source_file = b.path("user/lib/start.zig"),
        .target = user_target,
        .optimize = .ReleaseSafe,
        .strip = true,
        .unwind_tables = .none,
        .imports = &.{
            .{ .name = "syscall", .module = syscall_module },
            .{ .name = "main", .module = fatfs_main_module },
        },
    });

    fatfs_module.red_zone = false;

    const fatfs = b.addExecutable(.{
        .name = "fatfs",
        .root_module = fatfs_module,
    });

    fatfs.setLinkerScript(b.path("user/linker-user.ld"));

    b.installArtifact(fatfs);

    // ========================================
    // User space: tty (terminal) service
    // ========================================
    const tty_font_module = b.createModule(.{
        .root_source_file = b.path("user/services/tty/font.zig"),
        .target = user_target,
        .optimize = .ReleaseSafe,
        .strip = true,
    });

    const tty_main_module = b.createModule(.{
        .root_source_file = b.path("user/services/tty/main.zig"),
        .target = user_target,
        .optimize = .ReleaseSafe,
        .strip = true,
        .imports = &.{
            .{ .name = "syscall", .module = syscall_module },
            .{ .name = "vfs", .module = vfs_module },
            .{ .name = "font", .module = tty_font_module },
        },
    });

    const tty_module = b.createModule(.{
        .root_source_file = b.path("user/lib/start.zig"),
        .target = user_target,
        .optimize = .ReleaseSafe,
        .strip = true,
        .unwind_tables = .none,
        .imports = &.{
            .{ .name = "syscall", .module = syscall_module },
            .{ .name = "main", .module = tty_main_module },
        },
    });

    tty_module.red_zone = false;

    const tty = b.addExecutable(.{
        .name = "tty",
        .root_module = tty_module,
    });

    tty.setLinkerScript(b.path("user/linker-user.ld"));

    b.installArtifact(tty);

    // ========================================
    // User space: serial (16550 UART) service
    // ========================================
    const serial_main_module = b.createModule(.{
        .root_source_file = b.path("user/services/serial/main.zig"),
        .target = user_target,
        .optimize = .ReleaseSafe,
        .strip = true,
        .imports = &.{
            .{ .name = "syscall", .module = syscall_module },
            .{ .name = "vfs", .module = vfs_module },
        },
    });

    const serial_module = b.createModule(.{
        .root_source_file = b.path("user/lib/start.zig"),
        .target = user_target,
        .optimize = .ReleaseSafe,
        .strip = true,
        .unwind_tables = .none,
        .imports = &.{
            .{ .name = "syscall", .module = syscall_module },
            .{ .name = "main", .module = serial_main_module },
        },
    });

    serial_module.red_zone = false;

    const serial_svc = b.addExecutable(.{
        .name = "serial",
        .root_module = serial_module,
    });

    serial_svc.setLinkerScript(b.path("user/linker-user.ld"));

    b.installArtifact(serial_svc);

    // ========================================
    // Build ISO step
    // ========================================
    const iso_cmd = b.addSystemCommand(&.{
        "cmd", "/c", "scripts\\build-iso.bat",
    });
    iso_cmd.step.dependOn(b.getInstallStep());

    const iso_step = b.step("iso", "Build bootable ISO image");
    iso_step.dependOn(&iso_cmd.step);

    // Run in QEMU step. virtio-blk-pci is attached so PCI enumeration
    // can find it; the backing file is created by ensureDiskImage above.
    const qemu_cmd = b.addSystemCommand(&.{
        "qemu-system-x86_64",
        "-M", "q35",
        "-m", "256M",
        "-serial", "stdio",
        "-bios", "ovmf/OVMF.fd",
        "-cdrom", "zig-out/graphene.iso",
        "-boot", "d",
        "-drive", "file=disk.img,if=none,id=blk0,format=raw",
        "-device", "virtio-blk-pci,drive=blk0",
    });
    qemu_cmd.step.dependOn(iso_step);

    const run_step = b.step("run", "Build ISO and run in QEMU");
    run_step.dependOn(&qemu_cmd.step);

    // ========================================
    // test-shell: pipe a fixture into the shell over -serial stdio,
    // assert expected substrings appear in the output.
    // ========================================
    const test_shell_cmd = b.addSystemCommand(&.{
        "cmd", "/c", "scripts\\test-shell.bat",
    });
    test_shell_cmd.step.dependOn(iso_step);

    const test_shell_step = b.step("test-shell", "Run shell over serial with a fixture and grep DONE");
    test_shell_step.dependOn(&test_shell_cmd.step);
}
