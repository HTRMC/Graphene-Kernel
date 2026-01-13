// Graphene PS/2 Keyboard Driver
// User-space driver using IRQ and I/O port capabilities

const syscall = @import("syscall");

/// Capability slots (assigned by kernel when driver is loaded)
const IRQ_CAP: u32 = 0; // IRQ 1 capability
const IOPORT_CAP: u32 = 1; // I/O ports 0x60-0x64 capability

/// PS/2 Controller ports
const DATA_PORT: u16 = 0x60;
const STATUS_PORT: u16 = 0x64;

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

/// Main entry point for keyboard driver
pub fn main() i32 {
    syscall.print("kbd: driver started\n");

    while (true) {
        const wait_result = syscall.irqWait(IRQ_CAP);
        if (wait_result < 0) {
            syscall.print("kbd: irqWait failed\n");
            break;
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
            const buf = [_]u8{8};
            _ = syscall.debugPrint(&buf);
            _ = syscall.irqAck(IRQ_CAP);
            continue;
        }

        // Regular key - convert and print
        const ascii = scancodeToAscii(scancode);
        if (ascii != 0) {
            const buf = [_]u8{ascii};
            _ = syscall.debugPrint(&buf);
        }

        _ = syscall.irqAck(IRQ_CAP);
    }

    return 0;
}
