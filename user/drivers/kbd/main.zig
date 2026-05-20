// Graphene PS/2 Keyboard Driver
// User-space driver using IRQ and I/O port capabilities.
// Translates scancodes to ASCII and pushes each character into the tty
// service's input queue via a `.tty_input` VFS op on TTY_CAP_SLOT. The
// kernel is not in the keyboard data path — only IRQ delivery and I/O
// port access.

const syscall = @import("syscall");
const vfs = @import("vfs");

pub const proc_name: []const u8 = "kbd";

/// Capability slots (assigned by kernel when driver is loaded)
const IRQ_CAP: u32 = 0; // IRQ 1 capability
const IOPORT_CAP: u32 = 1; // I/O ports 0x60-0x64 capability
const TTY_INPUT_CAP: u32 = vfs.TTY_INPUT_SLOT; // SEND on async input endpoint to tty

/// PS/2 Controller ports
const DATA_PORT: u16 = 0x60;
const STATUS_PORT: u16 = 0x64;
const COMMAND_PORT: u16 = 0x64;

/// PS/2 status register bits
const STATUS_OBF: u8 = 0x01; // output buffer has data
const STATUS_AUX: u8 = 0x20; // data came from second port (mouse)

/// PS/2 controller commands written to 0x64
const CMD_DISABLE_AUX: u8 = 0xA7; // disable second PS/2 port (mouse)

/// Special scancodes
const SC_BACKSPACE: u8 = 0x0E;
const SC_LEFT_SHIFT: u8 = 0x2A;
const SC_RIGHT_SHIFT: u8 = 0x36;
const SC_CAPS_LOCK: u8 = 0x3A;

/// Simple US keyboard scancode to ASCII table (set 1, make codes only)
const scancode_table = [_]u8{
    0,   27,  '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=', 8,   '\t', // 0x00-0x0F
    'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']', '\n', 0,   'a', 's', // 0x10-0x1F
    'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', '\'', '`', 0,   '\\', 'z', 'x', 'c', 'v', // 0x20-0x2F
    'b', 'n', 'm', ',', '.', '/', 0,   '*', 0,   ' ', 0,   0,   0,   0,   0,   0, // 0x30-0x3F
};

/// Shifted scancode table (with shift held)
const scancode_table_shifted = [_]u8{
    0,   27,  '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '_', '+', 8,   '\t', // 0x00-0x0F
    'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '{', '}', '\n', 0,   'A', 'S', // 0x10-0x1F
    'D', 'F', 'G', 'H', 'J', 'K', 'L', ':', '"', '~', 0,   '|', 'Z', 'X', 'C', 'V', // 0x20-0x2F
    'B', 'N', 'M', '<', '>', '?', 0,   '*', 0,   ' ', 0,   0,   0,   0,   0,   0, // 0x30-0x3F
};

/// Keyboard state
var shift_pressed: bool = false;
var caps_lock: bool = false;

/// Convert scancode to ASCII character
fn scancodeToAscii(scancode: u8) u8 {
    if (scancode < scancode_table.len) {
        var ascii = if (shift_pressed)
            scancode_table_shifted[scancode]
        else
            scancode_table[scancode];

        // Apply caps lock to letters only (toggles case)
        if (caps_lock) {
            if (ascii >= 'a' and ascii <= 'z') {
                ascii = ascii - 32; // Convert to uppercase
            } else if (ascii >= 'A' and ascii <= 'Z') {
                ascii = ascii + 32; // Convert to lowercase (shift+caps = lowercase)
            }
        }

        return ascii;
    }
    return 0;
}

/// Push a single ASCII byte into tty's input queue via the `.tty_input`
/// op. Uses capSend (fire-and-forget); tty does not reply for tty_input
/// so this never parks anything in the endpoint's send_queue.
fn sendToShell(ch: u8) void {
    var buf: [@sizeOf(vfs.RequestHeader) + 1]u8 = undefined;
    const hdr: *vfs.RequestHeader = @ptrCast(@alignCast(&buf));
    hdr.* = .{
        .op = @intFromEnum(vfs.FsOp.tty_input),
        .flags = 0,
        .name_len = 0,
        ._pad = 0,
        .offset = 0,
        .size = 1,
    };
    buf[@sizeOf(vfs.RequestHeader)] = ch;
    _ = syscall.capSend(TTY_INPUT_CAP, &buf, buf.len);
}

/// Drain any bytes left in the 8042 output buffer (UEFI may leave junk,
/// and mouse events would otherwise sit ahead of keystrokes in the FIFO).
fn drainOutputBuffer() void {
    var safety: u32 = 0;
    while (safety < 128) : (safety += 1) {
        const status = syscall.ioPortRead(IOPORT_CAP, STATUS_PORT, 1);
        if (status < 0) return;
        if ((@as(u8, @truncate(@as(u64, @bitCast(status)))) & STATUS_OBF) == 0) return;
        _ = syscall.ioPortRead(IOPORT_CAP, DATA_PORT, 1);
    }
}

/// Main entry point for keyboard driver
pub fn main() i32 {
    syscall.klogStr("kbd: driver started\n");

    // Disable the mouse port and drain stale bytes so the kbd FIFO
    // only contains keyboard scancodes from here on.
    _ = syscall.ioPortWrite(IOPORT_CAP, COMMAND_PORT, CMD_DISABLE_AUX, 1);
    drainOutputBuffer();

    while (true) {
        const wait_result = syscall.irqWait(IRQ_CAP);
        if (wait_result < 0) {
            syscall.klogStr("kbd: irqWait failed\n");
            break;
        }

        // If the byte came from the second port (mouse), ignore it.
        const status_r = syscall.ioPortRead(IOPORT_CAP, STATUS_PORT, 1);
        if (status_r >= 0) {
            const status: u8 = @truncate(@as(u64, @bitCast(status_r)));
            if ((status & STATUS_AUX) != 0) {
                _ = syscall.ioPortRead(IOPORT_CAP, DATA_PORT, 1);
                _ = syscall.irqAck(IRQ_CAP);
                continue;
            }
        }

        const scancode_result = syscall.ioPortRead(IOPORT_CAP, DATA_PORT, 1);
        if (scancode_result < 0) {
            _ = syscall.irqAck(IRQ_CAP);
            continue;
        }

        const scancode: u8 = @truncate(@as(u64, @bitCast(scancode_result)));

        // Skip break codes (key release) but track shift state
        if (scancode & 0x80 != 0) {
            const make_code = scancode & 0x7F;
            if (make_code == SC_LEFT_SHIFT or make_code == SC_RIGHT_SHIFT) {
                shift_pressed = false;
            }
            _ = syscall.irqAck(IRQ_CAP);
            continue;
        }

        // Track shift press
        if (scancode == SC_LEFT_SHIFT or scancode == SC_RIGHT_SHIFT) {
            shift_pressed = true;
            _ = syscall.irqAck(IRQ_CAP);
            continue;
        }

        // Toggle caps lock
        if (scancode == SC_CAPS_LOCK) {
            caps_lock = !caps_lock;
            _ = syscall.irqAck(IRQ_CAP);
            continue;
        }

        // Backspace
        if (scancode == SC_BACKSPACE) {
            sendToShell(8);
            _ = syscall.irqAck(IRQ_CAP);
            continue;
        }

        // Regular key — push to the tty input queue. Echoing back to
        // the screen is the shell's responsibility (raw-mode style).
        const ascii = scancodeToAscii(scancode);
        if (ascii != 0) sendToShell(ascii);

        _ = syscall.irqAck(IRQ_CAP);
    }

    return 0;
}
