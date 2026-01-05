@echo off
setlocal

cd /D "%~dp0\.."

set ISO_ROOT=zig-out\iso_root
set LIMINE_DIR=.zig-cache\limine

:: Create ISO directory structure
if exist "%ISO_ROOT%" rmdir /S /Q "%ISO_ROOT%"
mkdir "%ISO_ROOT%\boot"
mkdir "%ISO_ROOT%\boot\limine"
mkdir "%ISO_ROOT%\EFI\BOOT"

:: Copy kernel
copy "zig-out\bin\graphene" "%ISO_ROOT%\boot\graphene"

:: Copy Limine config
copy "limine.conf" "%ISO_ROOT%\boot\limine\limine.conf"

:: Download Limine if not present
if not exist "%LIMINE_DIR%" (
    echo Downloading Limine bootloader...
    mkdir "%LIMINE_DIR%"
    curl -L -o "%LIMINE_DIR%\limine.zip" "https://github.com/limine-bootloader/limine/releases/download/v8.6.0/limine-8.6.0.zip"
    tar -xf "%LIMINE_DIR%\limine.zip" -C "%LIMINE_DIR%" --strip-components=1
    del "%LIMINE_DIR%\limine.zip"
)

:: Copy Limine files
copy "%LIMINE_DIR%\limine-bios.sys" "%ISO_ROOT%\boot\limine\"
copy "%LIMINE_DIR%\limine-bios-cd.bin" "%ISO_ROOT%\boot\limine\"
copy "%LIMINE_DIR%\limine-uefi-cd.bin" "%ISO_ROOT%\boot\limine\"
copy "%LIMINE_DIR%\BOOTX64.EFI" "%ISO_ROOT%\EFI\BOOT\"
copy "%LIMINE_DIR%\BOOTIA32.EFI" "%ISO_ROOT%\EFI\BOOT\"

:: Create ISO using xorriso (must be installed)
xorriso -as mkisofs ^
    -b boot/limine/limine-bios-cd.bin ^
    -no-emul-boot -boot-load-size 4 -boot-info-table ^
    --efi-boot boot/limine/limine-uefi-cd.bin ^
    -efi-boot-part --efi-boot-image --protective-msdos-label ^
    "%ISO_ROOT%" -o "zig-out\graphene.iso"

:: Install Limine for BIOS boot
"%LIMINE_DIR%\limine.exe" bios-install "zig-out\graphene.iso"

echo.
echo ISO created: zig-out\graphene.iso
