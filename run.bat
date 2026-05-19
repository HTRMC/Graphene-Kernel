@echo off
setlocal enabledelayedexpansion

:: Change to script directory
cd /D "%~dp0"

:: Prefer locally-installed compiler (compiler\zig\zig.exe), fall back to system zig on PATH.
set ZIG_FOLDER=compiler\zig
if exist "%ZIG_FOLDER%\zig.exe" (
    set ZIG_EXE="%ZIG_FOLDER%\zig.exe"
    echo Using local Zig compiler.
) else (
    where zig >nul 2>&1
    if errorlevel 1 (
        echo No local compiler at %ZIG_FOLDER%\zig.exe and no 'zig' on PATH.
        exit /b 1
    )
    set ZIG_EXE=zig
    echo Using system Zig from PATH.
)

:: Check if OVMF exists (needed for UEFI boot in QEMU)
if exist "ovmf\OVMF.fd" (
    echo OVMF firmware found!
) else (
    echo OVMF firmware not found. Downloading...

    :: Create ovmf directory
    if not exist ovmf mkdir ovmf

    :: Download OVMF from edk2 nightly builds
    set OVMF_URL=https://retrage.github.io/edk2-nightly/bin/RELEASEX64_OVMF.fd
    echo Downloading OVMF from !OVMF_URL!...
    curl -L -o "ovmf\OVMF.fd" "!OVMF_URL!"

    if errorlevel 1 (
        echo Failed to download OVMF firmware!
        exit /b 1
    )

    echo OVMF firmware installed successfully!
)

:: Run the kernel build
echo.
echo Building Graphene Kernel...
echo.
:: Use ReleaseSafe by default (Debug mode has ubsan issues with soft_float)
%ZIG_EXE% build -Doptimize=ReleaseSafe %*

if errorlevel 1 (
    echo.
    echo Build failed
    exit /b 1
)
