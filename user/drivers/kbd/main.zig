// Graphene PS/2 Keyboard Driver
// User-space driver using IRQ and I/O port capabilities

const syscall = @import("syscall");

/// Capability slots (assigned by kernel when driver is loaded)
const IRQ_CAP: u32 = 0; // IRQ 1 capability
const IOPORT_CAP: u32 = 1; // I/O ports 0x60-0x64 capability

/// PS/2 Controller ports
const DATA_PORT: u16 = 0x60;
const STATUS_PORT: u16 = 0x64;

/// Status register bits
const STATUS_OUTPUT_FULL: u8 = 0x01;

/// Simple US keyboard scancode to ASCII table (set 1, make codes only)
const scancode_table = [_]u8{
    0,   27,  '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=', 8,   '\t', // 0x00-0x0F
    'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']', '\n', 0,   'a', 's', // 0x10-0x1F
    'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', '\'', '`', 0,   '\\', 'z', 'x', 'c', 'v', // 0x20-0x2F
    'b', 'n', 'm', ',', '.', '/', 0,   '*', 0,   ' ', 0,   0,   0,   0,   0,   0, // 0x30-0x3F
};

/// Convert scancode to ASCII character
fn scancodeToAscii(scancode: u8) u8 {
    // Ignore break codes (key release) - high bit set
    if (scancode & 0x80 != 0) return 0;

    if (scancode < scancode_table.len) {
        return scancode_table[scancode];
    }
    return 0;
}

/// Main entry point for keyboard driver
pub fn main() i32 {
    syscall.print("kbd: PS/2 keyboard driver starting\n");

    // Main driver loop
    var key_count: u32 = 0;
    while (true) {
        // Wait for keyboard IRQ
        const wait_result = syscall.irqWait(IRQ_CAP);
        if (wait_result < 0) {
            syscall.print("kbd: irqWait failed\n");
            break;
        }

        // Read scancode from data port
        const scancode_result = syscall.ioPortRead(IOPORT_CAP, DATA_PORT, 1);
        if (scancode_result < 0) {
            syscall.print("kbd: ioPortRead failed\n");
            // Acknowledge IRQ anyway to prevent lockup
            _ = syscall.irqAck(IRQ_CAP);
            continue;
        }

        const scancode: u8 = @truncate(@as(u64, @bitCast(scancode_result)));

        // Convert to ASCII and print if valid
        const ascii = scancodeToAscii(scancode);
        if (ascii != 0) {
            // Print the character
            var buf: [2]u8 = .{ ascii, 0 };
            _ = syscall.debugPrint(buf[0..1]);
            key_count += 1;
        }

        // Acknowledge IRQ to allow more interrupts
        _ = syscall.irqAck(IRQ_CAP);
    }

    syscall.print("kbd: driver exiting\n");
    return 0;
}
