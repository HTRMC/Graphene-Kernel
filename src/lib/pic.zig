// Graphene Kernel - 8259 PIC (Programmable Interrupt Controller)
// Remaps hardware IRQs to vectors 32-47 to avoid conflict with CPU exceptions

/// PIC I/O ports
const PIC1_COMMAND: u16 = 0x20;
const PIC1_DATA: u16 = 0x21;
const PIC2_COMMAND: u16 = 0xA0;
const PIC2_DATA: u16 = 0xA1;

/// PIC commands
const ICW1_INIT: u8 = 0x10;
const ICW1_ICW4: u8 = 0x01;
const ICW4_8086: u8 = 0x01;
const PIC_EOI: u8 = 0x20;

/// IRQ base vectors after remapping
pub const IRQ_BASE: u8 = 32;
pub const IRQ_BASE_SLAVE: u8 = 40;

/// Write to an I/O port
fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "N{dx}" (port),
    );
}

/// Read from an I/O port
fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "N{dx}" (port),
    );
}

/// Small delay for PIC (some systems need this)
fn ioWait() void {
    outb(0x80, 0);
}

/// Initialize and remap the PIC
/// Remaps IRQ 0-7 to vectors 32-39 and IRQ 8-15 to vectors 40-47
pub fn init() void {
    // Save masks
    const mask1 = inb(PIC1_DATA);
    const mask2 = inb(PIC2_DATA);

    // Start initialization sequence (cascade mode)
    outb(PIC1_COMMAND, ICW1_INIT | ICW1_ICW4);
    ioWait();
    outb(PIC2_COMMAND, ICW1_INIT | ICW1_ICW4);
    ioWait();

    // Set vector offsets
    outb(PIC1_DATA, IRQ_BASE); // Master PIC: IRQ 0-7 -> vectors 32-39
    ioWait();
    outb(PIC2_DATA, IRQ_BASE_SLAVE); // Slave PIC: IRQ 8-15 -> vectors 40-47
    ioWait();

    // Tell master PIC about slave at IRQ2
    outb(PIC1_DATA, 4);
    ioWait();
    // Tell slave PIC its cascade identity
    outb(PIC2_DATA, 2);
    ioWait();

    // Set 8086 mode
    outb(PIC1_DATA, ICW4_8086);
    ioWait();
    outb(PIC2_DATA, ICW4_8086);
    ioWait();

    // Restore masks
    outb(PIC1_DATA, mask1);
    outb(PIC2_DATA, mask2);
}

/// Send End-Of-Interrupt signal
/// Must be called after handling a hardware IRQ
pub fn sendEoi(irq: u8) void {
    if (irq >= 8) {
        // IRQ came from slave PIC, send EOI to both
        outb(PIC2_COMMAND, PIC_EOI);
    }
    outb(PIC1_COMMAND, PIC_EOI);
}

/// Mask (disable) a specific IRQ
pub fn maskIrq(irq: u8) void {
    var port: u16 = undefined;
    var irq_line: u8 = undefined;

    if (irq < 8) {
        port = PIC1_DATA;
        irq_line = irq;
    } else {
        port = PIC2_DATA;
        irq_line = irq - 8;
    }

    const value = inb(port) | (@as(u8, 1) << @intCast(irq_line));
    outb(port, value);
}

/// Unmask (enable) a specific IRQ
pub fn unmaskIrq(irq: u8) void {
    var port: u16 = undefined;
    var irq_line: u8 = undefined;

    if (irq < 8) {
        port = PIC1_DATA;
        irq_line = irq;
    } else {
        port = PIC2_DATA;
        irq_line = irq - 8;
    }

    const value = inb(port) & ~(@as(u8, 1) << @intCast(irq_line));
    outb(port, value);
}

/// Mask all IRQs (disable all hardware interrupts via PIC)
pub fn maskAll() void {
    outb(PIC1_DATA, 0xFF);
    outb(PIC2_DATA, 0xFF);
}

/// Unmask all IRQs
pub fn unmaskAll() void {
    outb(PIC1_DATA, 0x00);
    outb(PIC2_DATA, 0x00);
}

/// Get combined IRQ mask (16 bits: slave << 8 | master)
pub fn getMask() u16 {
    return @as(u16, inb(PIC2_DATA)) << 8 | inb(PIC1_DATA);
}

/// Set combined IRQ mask
pub fn setMask(mask: u16) void {
    outb(PIC1_DATA, @truncate(mask));
    outb(PIC2_DATA, @truncate(mask >> 8));
}

/// Disable the PIC (when switching to APIC)
pub fn disable() void {
    outb(PIC2_DATA, 0xFF);
    outb(PIC1_DATA, 0xFF);
}
