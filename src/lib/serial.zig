// Graphene Kernel - Serial Console Driver (16550 UART)
// Provides serial output for debugging and console I/O

/// Standard COM port base addresses
pub const COM1: u16 = 0x3F8;
pub const COM2: u16 = 0x2F8;
pub const COM3: u16 = 0x3E8;
pub const COM4: u16 = 0x2E8;

/// UART register offsets from base address
const DATA_REG: u16 = 0; // Data register (read/write)
const INT_ENABLE: u16 = 1; // Interrupt enable register
const FIFO_CTRL: u16 = 2; // FIFO control register
const LINE_CTRL: u16 = 3; // Line control register
const MODEM_CTRL: u16 = 4; // Modem control register
const LINE_STATUS: u16 = 5; // Line status register
const MODEM_STATUS: u16 = 6; // Modem status register

/// Line status register bits
const LSR_DATA_READY: u8 = 0x01; // Data ready to be read
const LSR_THRE: u8 = 0x20; // Transmit holding register empty (ready to send)

/// Line control register bits
const LCR_DLAB: u8 = 0x80; // Divisor Latch Access Bit

/// Currently active serial port
var active_port: u16 = COM1;

/// Write to an I/O port
fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "{dx}" (port),
    );
}

/// Read from an I/O port
fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "{dx}" (port),
    );
}

/// Initialize serial port with specified baud rate
/// Common baud rates: 115200, 57600, 38400, 19200, 9600
pub fn init() void {
    initPort(COM1, 115200);
}

/// Initialize a specific serial port
pub fn initPort(port: u16, baud_rate: u32) void {
    active_port = port;

    // Calculate divisor for baud rate (base clock is 115200)
    const divisor: u16 = @intCast(115200 / baud_rate);

    // Disable interrupts
    outb(port + INT_ENABLE, 0x00);

    // Enable DLAB to set baud rate divisor
    outb(port + LINE_CTRL, LCR_DLAB);

    // Set divisor (low byte and high byte)
    outb(port + DATA_REG, @truncate(divisor)); // Low byte
    outb(port + INT_ENABLE, @truncate(divisor >> 8)); // High byte (shares address with INT_ENABLE when DLAB=1)

    // 8 bits, no parity, 1 stop bit (8N1)
    outb(port + LINE_CTRL, 0x03);

    // Enable FIFO, clear them, with 14-byte threshold
    outb(port + FIFO_CTRL, 0xC7);

    // Enable IRQs, set RTS/DSR
    outb(port + MODEM_CTRL, 0x0B);

    // Test serial chip (loopback mode)
    outb(port + MODEM_CTRL, 0x1E);
    outb(port + DATA_REG, 0xAE);

    // Check if we receive the same byte back
    if (inb(port + DATA_REG) != 0xAE) {
        // Serial port not working, but we'll try anyway
        // (some emulators don't support loopback properly)
    }

    // Set normal operation mode (not loopback)
    // Enable OUT1, OUT2 (for interrupts), RTS, DTR
    outb(port + MODEM_CTRL, 0x0F);
}

/// Check if serial port is ready to transmit
fn isTransmitEmpty() bool {
    return (inb(active_port + LINE_STATUS) & LSR_THRE) != 0;
}

/// Wait until transmit buffer is empty
fn waitForTransmit() void {
    while (!isTransmitEmpty()) {
        // Busy wait - could add a small pause here
    }
}

/// Write a single character to serial port
pub fn putChar(c: u8) void {
    waitForTransmit();
    outb(active_port + DATA_REG, c);
}

/// Write a string to serial port
pub fn puts(str: []const u8) void {
    for (str) |c| {
        if (c == '\n') {
            // Send CR+LF for newlines
            putChar('\r');
        }
        putChar(c);
    }
}

/// Print a string followed by newline
pub fn println(str: []const u8) void {
    puts(str);
    putChar('\r');
    putChar('\n');
}

/// Check if data is available to read
pub fn dataAvailable() bool {
    return (inb(active_port + LINE_STATUS) & LSR_DATA_READY) != 0;
}

/// Read a character from serial port (blocking)
pub fn getChar() u8 {
    while (!dataAvailable()) {
        // Busy wait
    }
    return inb(active_port + DATA_REG);
}

/// Read a character from serial port (non-blocking)
/// Returns null if no data available
pub fn tryGetChar() ?u8 {
    if (dataAvailable()) {
        return inb(active_port + DATA_REG);
    }
    return null;
}

/// Print a hexadecimal number
pub fn putHex(value: u64) void {
    puts("0x");
    var started = false;
    var i: u6 = 60;
    while (true) {
        const nibble: u8 = @truncate(value >> i);
        const masked = nibble & 0x0F;
        if (masked != 0 or started or i == 0) {
            started = true;
            const c: u8 = if (masked < 10) '0' + masked else 'a' + (masked - 10);
            putChar(c);
        }
        if (i == 0) break;
        i -= 4;
    }
    if (!started) {
        putChar('0');
    }
}

/// Print a decimal number
pub fn putDec(value: u64) void {
    if (value == 0) {
        putChar('0');
        return;
    }

    var buf: [20]u8 = undefined;
    var i: usize = 0;
    var v = value;

    while (v > 0) {
        buf[i] = @truncate((v % 10) + '0');
        v /= 10;
        i += 1;
    }

    // Print in reverse order
    while (i > 0) {
        i -= 1;
        putChar(buf[i]);
    }
}

/// Formatted print with basic format specifiers
/// Supports: %s (string), %d (decimal), %x (hex), %c (char), %% (percent)
pub fn printf(comptime fmt: []const u8, args: anytype) void {
    comptime var arg_idx: usize = 0;
    comptime var i: usize = 0;

    inline while (i < fmt.len) {
        if (fmt[i] == '%' and i + 1 < fmt.len) {
            switch (fmt[i + 1]) {
                's' => {
                    puts(args[arg_idx]);
                    arg_idx += 1;
                },
                'd' => {
                    const val = args[arg_idx];
                    if (@TypeOf(val) == i32 or @TypeOf(val) == i64) {
                        if (val < 0) {
                            putChar('-');
                            putDec(@intCast(-val));
                        } else {
                            putDec(@intCast(val));
                        }
                    } else {
                        putDec(@intCast(val));
                    }
                    arg_idx += 1;
                },
                'x' => {
                    putHex(@intCast(args[arg_idx]));
                    arg_idx += 1;
                },
                'c' => {
                    putChar(@intCast(args[arg_idx]));
                    arg_idx += 1;
                },
                '%' => {
                    putChar('%');
                },
                else => {
                    putChar('%');
                    putChar(fmt[i + 1]);
                },
            }
            i += 2;
        } else {
            if (fmt[i] == '\n') {
                putChar('\r');
            }
            putChar(fmt[i]);
            i += 1;
        }
    }
}
