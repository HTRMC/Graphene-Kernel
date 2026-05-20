# Graphene test-shell harness
#
# Boots the ISO under QEMU with COM1 wired to a TCP-socket chardev
# instead of -serial stdio. We send the fixture bytes into the socket
# (serial RX from the guest's perspective) and read the shell output
# back (serial TX), looking for a marker that proves the round-trip.
#
# Why a socket instead of stdio: QEMU's stdio chardev on Windows does
# not deliver redirected/piped stdin to the UART RX. A TCP socket is
# bidirectional, well-tested cross-platform, and lets the harness see
# the boot log through the same chardev too.

param(
    [string]$Fixture = 'scripts\fixtures\basic.txt',
    [string]$OutFile = 'zig-out\test-shell.out',
    [string]$Marker  = 'GRAPHENE_TEST_DONE',
    [int]   $TimeoutSec = 45,
    [int]   $Port = 4444
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Fixture)) {
    Write-Host "FAIL: fixture '$Fixture' missing"
    exit 1
}
if (-not (Test-Path 'zig-out\graphene.iso')) {
    Write-Host "FAIL: zig-out\graphene.iso missing (build the ISO first)"
    exit 1
}
if (-not (Test-Path 'disk.img')) {
    Write-Host "FAIL: disk.img missing"
    exit 1
}

# Resolve qemu binary. PATH lookup is unreliable for Start-Process when
# the shell launching us doesn't have qemu on PATH.
$qemuBin = $null
$qemuCmd = Get-Command qemu-system-x86_64.exe -ErrorAction SilentlyContinue
if ($qemuCmd) { $qemuBin = $qemuCmd.Source }
foreach ($cand in @('C:\Program Files\qemu\qemu-system-x86_64.exe',
                    'C:\qemu\qemu-system-x86_64.exe')) {
    if (-not $qemuBin -and (Test-Path $cand)) { $qemuBin = $cand }
}
if (-not $qemuBin) {
    Write-Host "FAIL: qemu-system-x86_64.exe not found"
    exit 1
}

$qemuArgs = @(
    '-M','q35','-m','256M',
    '-bios','ovmf\OVMF.fd',
    '-cdrom','zig-out\graphene.iso','-boot','d',
    '-drive','file=disk.img,if=none,id=blk0,format=raw',
    '-device','virtio-blk-pci,drive=blk0',
    # wait=on: QEMU blocks until we connect, so no UART byte is ever
    # emitted/dropped before our reader is attached.
    '-chardev',"socket,id=c0,host=127.0.0.1,port=$Port,server=on,wait=on",
    '-serial','chardev:c0',
    '-display','none','-no-reboot'
)

Write-Host "test-shell: launching QEMU on TCP $Port ($qemuBin)..."
$qemu = Start-Process -FilePath $qemuBin -ArgumentList $qemuArgs `
    -NoNewWindow -PassThru

# Retry until QEMU's TCP listener is up; wait=on guarantees the rest of
# the boot pipeline doesn't start until we connect.
$client = New-Object System.Net.Sockets.TcpClient
$connected = $false
for ($attempt = 0; $attempt -lt 50 -and -not $connected; $attempt++) {
    try {
        $client.Connect('127.0.0.1', $Port)
        $connected = $true
    } catch {
        Start-Sleep -Milliseconds 200
    }
}
if (-not $connected) {
    Write-Host "FAIL: could not connect to QEMU TCP serial on port $Port"
    try { $qemu.Kill() } catch { }
    exit 1
}

$ns = $client.GetStream()

# Drain whatever boot output is already pending before sending input.
# Wait until we've seen the shell prompt, then push the fixture. This
# avoids a race where bytes land in the UART RX FIFO before user space
# has scheduled the serial driver to drain it.
$sb = New-Object System.Text.StringBuilder
$buf = New-Object byte[] 8192
$promptDeadline = (Get-Date).AddSeconds(20)
$sawPrompt = $false
while ((Get-Date) -lt $promptDeadline) {
    if ($ns.DataAvailable) {
        $n = $ns.Read($buf, 0, $buf.Length)
        if ($n -gt 0) {
            [void]$sb.Append([System.Text.Encoding]::ASCII.GetString($buf, 0, $n))
            if ($sb.ToString() -match 'graphene>') {
                $sawPrompt = $true
                break
            }
        }
    } else {
        Start-Sleep -Milliseconds 100
    }
}
if (-not $sawPrompt) {
    Write-Host "FAIL: shell prompt never appeared on serial"
    Write-Host '--- begin captured serial output ---'
    Write-Host $sb.ToString()
    Write-Host '--- end captured serial output ---'
    try { $ns.Close() } catch { }
    try { $client.Close() } catch { }
    if (-not $qemu.HasExited) { try { $qemu.Kill() } catch { } }
    exit 1
}

# Tiny extra settle so the shell is parked in readLine and the serial
# driver has scheduled at least once after the prompt.
Start-Sleep -Milliseconds 500

$fixtureBytes = [System.IO.File]::ReadAllBytes($Fixture)
# Type the fixture in slowly (one byte per ~5ms). Mimics interactive
# input and gives the guest's UART RX FIFO room to drain between
# bytes, avoiding a burst that races with shell output for serial-
# driver CPU.
foreach ($b in $fixtureBytes) {
    $ns.WriteByte($b)
    $ns.Flush()
    Start-Sleep -Milliseconds 5
}
Write-Host "test-shell: prompt seen; sent $($fixtureBytes.Length) fixture bytes; scanning for marker '$Marker'..."

$sb = New-Object System.Text.StringBuilder
$buf = New-Object byte[] 8192
$found = $false
$deadline = (Get-Date).AddSeconds($TimeoutSec)
while ((Get-Date) -lt $deadline) {
    if ($ns.DataAvailable) {
        $n = $ns.Read($buf, 0, $buf.Length)
        if ($n -gt 0) {
            [void]$sb.Append([System.Text.Encoding]::ASCII.GetString($buf, 0, $n))
            if ($sb.ToString() -match [regex]::Escape($Marker)) {
                $found = $true
                break
            }
        }
    } else {
        Start-Sleep -Milliseconds 100
    }
}

[System.IO.File]::WriteAllText($OutFile, $sb.ToString())
try { $ns.Close() } catch { }
try { $client.Close() } catch { }
if (-not $qemu.HasExited) { try { $qemu.Kill() } catch { } }

if ($found) {
    Write-Host "PASS: '$Marker' observed on serial round-trip"
    exit 0
}

Write-Host "FAIL: '$Marker' not found within $TimeoutSec s"
Write-Host '--- begin captured serial output ---'
Write-Host $sb.ToString()
Write-Host '--- end captured serial output ---'
exit 1
