@echo off
setlocal

cd /D "%~dp0\.."

:: Find xorriso (check common MSYS2 paths)
set XORRISO=
if exist "C:\Program Files\msys64\usr\bin\xorriso.exe" set "XORRISO=C:\Program Files\msys64\usr\bin\xorriso.exe"
if exist "C:\msys64\usr\bin\xorriso.exe" set XORRISO=C:\msys64\usr\bin\xorriso.exe
where xorriso >nul 2>&1 && set XORRISO=xorriso

if "%XORRISO%"=="" (
    echo ERROR: xorriso not found. Install via MSYS2: pacman -S xorriso
    exit /b 1
)

echo Using xorriso: %XORRISO%

set ISO_ROOT=zig-out\iso_root
set LIMINE_DIR=limine
set LIMINE_BASE=https://raw.githubusercontent.com/limine-bootloader/limine/v8.x-binary

:: Create ISO directory structure
if exist "%ISO_ROOT%" rmdir /S /Q "%ISO_ROOT%"
mkdir "%ISO_ROOT%\boot"
mkdir "%ISO_ROOT%\boot\limine"
mkdir "%ISO_ROOT%\EFI\BOOT"

:: Copy kernel
copy "zig-out\bin\graphene" "%ISO_ROOT%\boot\graphene"

:: Copy init process (if it exists)
if exist "zig-out\bin\init" (
    copy "zig-out\bin\init" "%ISO_ROOT%\boot\init"
    echo Copied init process to ISO
)

:: Copy shell process (if it exists)
if exist "zig-out\bin\shell" (
    copy "zig-out\bin\shell" "%ISO_ROOT%\boot\shell"
    echo Copied shell process to ISO
)

:: Copy keyboard driver (if it exists)
if exist "zig-out\bin\kbd" (
    copy "zig-out\bin\kbd" "%ISO_ROOT%\boot\kbd"
    echo Copied keyboard driver to ISO
)

:: Copy ramfs service (if it exists)
if exist "zig-out\bin\ramfs" (
    copy "zig-out\bin\ramfs" "%ISO_ROOT%\boot\ramfs"
    echo Copied ramfs service to ISO
)

:: Copy Limine config
copy "limine.conf" "%ISO_ROOT%\boot\limine\limine.conf"

:: Download Limine files if not present
if not exist "%LIMINE_DIR%" mkdir "%LIMINE_DIR%"

if not exist "%LIMINE_DIR%\limine-bios.sys" (
    echo Downloading Limine bootloader files...
    curl -L -o "%LIMINE_DIR%\limine-bios.sys" "%LIMINE_BASE%/limine-bios.sys"
    curl -L -o "%LIMINE_DIR%\limine-bios-cd.bin" "%LIMINE_BASE%/limine-bios-cd.bin"
    curl -L -o "%LIMINE_DIR%\limine-uefi-cd.bin" "%LIMINE_BASE%/limine-uefi-cd.bin"
    curl -L -o "%LIMINE_DIR%\BOOTX64.EFI" "%LIMINE_BASE%/BOOTX64.EFI"
    curl -L -o "%LIMINE_DIR%\BOOTIA32.EFI" "%LIMINE_BASE%/BOOTIA32.EFI"
    curl -L -o "%LIMINE_DIR%\limine.exe" "%LIMINE_BASE%/limine.exe"
    echo Limine bootloader downloaded!
)

:: Copy Limine files to ISO
copy "%LIMINE_DIR%\limine-bios.sys" "%ISO_ROOT%\boot\limine\"
copy "%LIMINE_DIR%\limine-bios-cd.bin" "%ISO_ROOT%\boot\limine\"
copy "%LIMINE_DIR%\limine-uefi-cd.bin" "%ISO_ROOT%\boot\limine\"
copy "%LIMINE_DIR%\BOOTX64.EFI" "%ISO_ROOT%\EFI\BOOT\"
copy "%LIMINE_DIR%\BOOTIA32.EFI" "%ISO_ROOT%\EFI\BOOT\"

:: Create ISO
echo Creating ISO image...
"%XORRISO%" -as mkisofs ^
    -b boot/limine/limine-bios-cd.bin ^
    -no-emul-boot -boot-load-size 4 -boot-info-table ^
    --efi-boot boot/limine/limine-uefi-cd.bin ^
    -efi-boot-part --efi-boot-image --protective-msdos-label ^
    "%ISO_ROOT%" -o "zig-out\graphene.iso"

if errorlevel 1 (
    echo Failed to create ISO!
    exit /b 1
)

:: Install Limine for BIOS boot
if exist "%LIMINE_DIR%\limine.exe" (
    echo Installing Limine BIOS boot sector...
    "%LIMINE_DIR%\limine.exe" bios-install "zig-out\graphene.iso"
)

echo.
echo ISO created: zig-out\graphene.iso
