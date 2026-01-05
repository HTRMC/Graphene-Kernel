# Graphene Kernel

A minimal x86_64 monolithic kernel written in Zig.

## Prerequisites

### Windows

1. **MSYS2** - Install from https://www.msys2.org/
   ```bash
   # In MSYS2 terminal, install xorriso
   pacman -S xorriso
   ```

2. **QEMU** - Install from https://www.qemu.org/download/#windows
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

# This will:
# 1. Download Zig 0.15.2 (first run only)
# 2. Compile the kernel
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
│       └── font.zig        # 8x8 bitmap font
└── scripts/
    └── build-iso.bat   # ISO creation script
```

## Architecture

- **Target**: x86_64 freestanding
- **Bootloader**: Limine (UEFI + BIOS)
- **Kernel type**: Monolithic

## Dependencies (auto-downloaded)

| Dependency | Purpose | Location |
|------------|---------|----------|
| Zig | Compiler | `compiler/zig/` |
| Limine | Bootloader | `limine/` |
| OVMF | UEFI firmware for QEMU | `ovmf/` |
