# Graphene Kernel

A hybrid microkernel for x86_64 written in Zig, featuring capability-based security.

## Prerequisites

### Windows

1. **MSYS2** - Install from https://www.msys2.org/

   ```bash
   # In MSYS2 terminal, install xorriso
   pacman -S xorriso
   ```

2. **QEMU** - Install from https://www.qemu.org/download/#windows or https://qemu.weilnetz.de/w64/
   - Add to PATH or install to default location

### Linux

```bash
# Debian/Ubuntu
sudo apt install xorriso qemu-system-x86

# Arch
sudo pacman -S xorriso qemu-system-x86
```

## Building

Clone the repository and run:

```bash
# Windows
.\run.bat

# First run automatically downloads:
#   - Zig 0.16.0-dev.1859+212968c57 compiler
#   - OVMF firmware (for UEFI boot)
# Then compiles the kernel
```

## Running

```bash
# Build ISO and launch QEMU
.\run.bat run

# Or just build the ISO
.\run.bat iso
```

## Project Structure

```
graphene-kernel/
├── build.zig           # Zig build configuration
├── build.zig.zon       # Package manifest
├── linker.ld           # Kernel linker script
├── limine.conf         # Bootloader configuration
├── run.bat             # Build/run script (downloads Zig)
├── .zigversion         # Zig version to use
├── src/
│   ├── main.zig        # Kernel entry point
│   └── lib/
│       ├── limine.zig      # Limine bootloader bindings
│       ├── framebuffer.zig # Framebuffer driver
│       ├── font.zig        # 8x8 bitmap font
│       ├── gdt.zig         # Global Descriptor Table + TSS
│       ├── idt.zig         # Interrupt Descriptor Table
│       └── pic.zig         # 8259 PIC driver
└── scripts/
    └── build-iso.bat   # ISO creation script
```

## Architecture

- **Target**: x86_64 freestanding
- **Bootloader**: Limine (UEFI + BIOS)
- **Kernel type**: Hybrid microkernel
- **Security model**: Capability-based (no root/UID)

## Dependencies (auto-downloaded)

| Dependency | Purpose                | Location        |
| ---------- | ---------------------- | --------------- |
| Zig        | Compiler               | `compiler/zig/` |
| Limine     | Bootloader             | `limine/`       |
| OVMF       | UEFI firmware for QEMU | `ovmf/`         |

## Known Issues

### Windows: Build fails on first attempt

On Windows, the first build may fail with an LLD linker error:

```
error: ld.lld ... failure
```

**Cause**: Windows file locking - the linker can't write to output files that are still locked from a previous build.

**Solution**: Run `.\run.bat` again. The build usually succeeds on retry. (If not please reach out😊)
