// Graphene PS/2 Keyboard Driver
// User-space driver that handles keyboard input via IRQ 1

const syscall = @import("syscall");

/// Capability slots granted by kernel during driver loading
const IRQ_CAP: u32 = 0; // IRQ capability at slot 0
const IOPORT_CAP: u32 = 1; // I/O port capability at slot 1

/// PS/2 keyboard I/O ports
const DATA_PORT: u16 = 0x60;
const STATUS_PORT: u16 = 0x64;

/// US keyboard scancode set 1 to ASCII lookup table
const scancode_to_ascii = [_]u8{
    0, 0, // 0x00, 0x01 - null, escape
    '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', // 0x02-0x0B
    '-', '=', 0, 0, // 0x0C-0x0F: minus, equal, backspace, tab
    'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', // 0x10-0x19
    '[', ']', '\n', 0, // 0x1A-0x1D: brackets, enter, left ctrl
    'a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', // 0x1E-0x26
    ';', '\'', '`', 0, // 0x27-0x2A: semicolon, quote, backtick, left shift
    '\\', 'z', 'x', 'c', 'v', 'b', 'n', 'm', // 0x2B-0x32
    ',', '.', '/', 0, // 0x33-0x36: comma, period, slash, right shift
    '*', 0, ' ', 0, // 0x37-0x3A: keypad *, left alt, space, caps lock
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 0x3B-0x44: F1-F10
    0, 0, // 0x45-0x46: num lock, scroll lock
    '7', '8', '9', '-', // 0x47-0x4A: keypad 7,8,9,-
    '4', '5', '6', '+', // 0x4B-0x4E: keypad 4,5,6,+
    '1', '2', '3', // 0x4F-0x51: keypad 1,2,3
    '0', '.', // 0x52-0x53: keypad 0, .
};

/// Shifted scancode mapping (when shift is held)
const scancode_to_ascii_shifted = [_]u8{
    0, 0, // 0x00, 0x01 - null, escape
    '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', // 0x02-0x0B
    '_', '+', 0, 0, // 0x0C-0x0F
    'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', // 0x10-0x19
    '{', '}', '\n', 0, // 0x1A-0x1D
    'A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', // 0x1E-0x26
    ':', '"', '~', 0, // 0x27-0x2A
    '|', 'Z', 'X', 'C', 'V', 'B', 'N', 'M', // 0x2B-0x32
    '<', '>', '?', 0, // 0x33-0x36
    '*', 0, ' ', 0, // 0x37-0x3A
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 0x3B-0x44: F1-F10
    0, 0, // 0x45-0x46
    '7', '8', '9', '-', // 0x47-0x4A
    '4', '5', '6', '+', // 0x4B-0x4E
    '1', '2', '3', // 0x4F-0x51
    '0', '.', // 0x52-0x53
};

/// State tracking
var shift_pressed: bool = false;
var caps_lock: bool = false;

/// Main entry point for keyboard driver
pub fn main() i32 {
    syscall.print("PS/2 Keyboard driver starting...\n");

    // Main driver loop
    while (true) {
        // Wait for keyboard IRQ
        const wait_result = syscall.irqWait(IRQ_CAP);
        if (wait_result < 0) {
            syscall.print("kbd: irqWait failed\n");
            continue;
        }

        // Read scancode from keyboard data port
        const read_result = syscall.ioPortRead(IOPORT_CAP, DATA_PORT, 1);
        if (read_result < 0) {
            // Acknowledge IRQ even on read failure
            _ = syscall.irqAck(IRQ_CAP);
            continue;
        }

        const scancode: u8 = @truncate(@as(u64, @bitCast(read_result)));

        // Handle the scancode
        processScancode(scancode);

        // Acknowledge IRQ to re-enable keyboard interrupts
        _ = syscall.irqAck(IRQ_CAP);
    }

    return 0;
}

/// Process a single scancode
fn processScancode(scancode: u8) void {
    // Check for key release (high bit set)
    const is_release = (scancode & 0x80) != 0;
    const key_code = scancode & 0x7F;

    // Handle modifier keys
    switch (key_code) {
        0x2A, 0x36 => { // Left shift, right shift
            shift_pressed = !is_release;
            return;
        },
        0x3A => { // Caps lock (toggle on press only)
            if (!is_release) {
                caps_lock = !caps_lock;
            }
            return;
        },
        else => {},
    }

    // Only process key presses, not releases
    if (is_release) return;

    // Convert to ASCII
    if (key_code < scancode_to_ascii.len) {
        const use_shifted = shift_pressed != caps_lock; // XOR for proper caps behavior
        const ascii = if (use_shifted)
            if (key_code < scancode_to_ascii_shifted.len) scancode_to_ascii_shifted[key_code] else 0
        else
            scancode_to_ascii[key_code];

        if (ascii != 0) {
            // Output the character
            var buf = [_]u8{ascii};
            _ = syscall.debugPrint(&buf);
        }
    }
}

/// Panic handler for Zig runtime
pub fn panic(msg: []const u8, _: ?*@import("std").builtin.StackTrace, _: ?usize) noreturn {
    _ = syscall.debugPrint("KBD PANIC: ");
    _ = syscall.debugPrint(msg);
    _ = syscall.debugPrint("\n");
    syscall.processExit(1);
}
