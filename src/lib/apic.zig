// Graphene Kernel - Local APIC (Advanced Programmable Interrupt Controller)
// Provides modern interrupt handling for x86_64 systems
// Replaces legacy 8259 PIC for better performance and SMP support

const pic = @import("pic.zig");
const serial = @import("serial.zig");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");

/// APIC register offsets from base address
const APIC_REG = struct {
    const ID: u32 = 0x020; // APIC ID
    const VERSION: u32 = 0x030; // APIC Version
    const TPR: u32 = 0x080; // Task Priority Register
    const APR: u32 = 0x090; // Arbitration Priority
    const PPR: u32 = 0x0A0; // Processor Priority
    const EOI: u32 = 0x0B0; // End of Interrupt
    const RRD: u32 = 0x0C0; // Remote Read
    const LDR: u32 = 0x0D0; // Logical Destination
    const DFR: u32 = 0x0E0; // Destination Format
    const SIVR: u32 = 0x0F0; // Spurious Interrupt Vector
    const ISR_BASE: u32 = 0x100; // In-Service Register (8 regs)
    const TMR_BASE: u32 = 0x180; // Trigger Mode Register (8 regs)
    const IRR_BASE: u32 = 0x200; // Interrupt Request Register (8 regs)
    const ESR: u32 = 0x280; // Error Status Register
    const ICR_LOW: u32 = 0x300; // Interrupt Command Register (low)
    const ICR_HIGH: u32 = 0x310; // Interrupt Command Register (high)
    const LVT_TIMER: u32 = 0x320; // LVT Timer
    const LVT_THERMAL: u32 = 0x330; // LVT Thermal Sensor
    const LVT_PERF: u32 = 0x340; // LVT Performance Counter
    const LVT_LINT0: u32 = 0x350; // LVT LINT0
    const LVT_LINT1: u32 = 0x360; // LVT LINT1
    const LVT_ERROR: u32 = 0x370; // LVT Error
    const TIMER_ICR: u32 = 0x380; // Timer Initial Count
    const TIMER_CCR: u32 = 0x390; // Timer Current Count
    const TIMER_DCR: u32 = 0x3E0; // Timer Divide Configuration
};

/// LVT Delivery Mode
const DeliveryMode = struct {
    const FIXED: u32 = 0b000 << 8;
    const SMI: u32 = 0b010 << 8;
    const NMI: u32 = 0b100 << 8;
    const INIT: u32 = 0b101 << 8;
    const EXTINT: u32 = 0b111 << 8;
};

/// LVT Mask bit
const LVT_MASKED: u32 = 1 << 16;

/// Timer modes
const TimerMode = struct {
    const ONE_SHOT: u32 = 0b00 << 17;
    const PERIODIC: u32 = 0b01 << 17;
    const TSC_DEADLINE: u32 = 0b10 << 17;
};

/// Timer divider values
const TimerDivider = struct {
    const DIV_1: u32 = 0b1011;
    const DIV_2: u32 = 0b0000;
    const DIV_4: u32 = 0b0001;
    const DIV_8: u32 = 0b0010;
    const DIV_16: u32 = 0b0011;
    const DIV_32: u32 = 0b1000;
    const DIV_64: u32 = 0b1001;
    const DIV_128: u32 = 0b1010;
};

/// MSR addresses
const IA32_APIC_BASE_MSR: u32 = 0x1B;

/// APIC base address flags
const APIC_BASE_ENABLE: u64 = 1 << 11;
const APIC_BASE_BSP: u64 = 1 << 8;
const APIC_BASE_ADDR_MASK: u64 = 0xFFFFF000;

/// Default APIC base address
const DEFAULT_APIC_BASE: u64 = 0xFEE00000;

/// Spurious vector number
const SPURIOUS_VECTOR: u8 = 0xFF;

/// Timer vector
pub const TIMER_VECTOR: u8 = 32;

/// APIC state
var apic_base: u64 = 0;
var apic_enabled: bool = false;
var timer_frequency: u64 = 0;

/// Read MSR
fn rdmsr(msr: u32) u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdmsr"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        : [msr] "{ecx}" (msr),
    );
    return (@as(u64, high) << 32) | low;
}

/// Write MSR
fn wrmsr(msr: u32, value: u64) void {
    const low: u32 = @truncate(value);
    const high: u32 = @truncate(value >> 32);
    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (msr),
          [low] "{eax}" (low),
          [high] "{edx}" (high),
    );
}

/// Execute CPUID instruction
fn cpuid(leaf: u32) struct { eax: u32, ebx: u32, ecx: u32, edx: u32 } {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [_eax] "={eax}" (eax),
          [_ebx] "={ebx}" (ebx),
          [_ecx] "={ecx}" (ecx),
          [_edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
    );
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

/// Check if APIC is supported via CPUID
pub fn isSupported() bool {
    const result = cpuid(1);
    // Bit 9 of EDX indicates APIC support
    return (result.edx & (1 << 9)) != 0;
}

/// Check if x2APIC is supported
pub fn isX2ApicSupported() bool {
    const result = cpuid(1);
    // Bit 21 of ECX indicates x2APIC support
    return (result.ecx & (1 << 21)) != 0;
}

/// Read APIC register
fn readReg(offset: u32) u32 {
    const addr: *volatile u32 = @ptrFromInt(apic_base + offset);
    return addr.*;
}

/// Write APIC register
fn writeReg(offset: u32, value: u32) void {
    const addr: *volatile u32 = @ptrFromInt(apic_base + offset);
    addr.* = value;
}

/// Initialize the Local APIC
pub fn init() bool {
    // Check CPUID for APIC support
    if (!isSupported()) {
        serial.println("[APIC] Not supported by CPU");
        return false;
    }

    serial.println("[APIC] Detected APIC support");

    // Get APIC base address from MSR
    const msr_value = rdmsr(IA32_APIC_BASE_MSR);
    apic_base = msr_value & APIC_BASE_ADDR_MASK;

    // Check if already enabled
    const is_bsp = (msr_value & APIC_BASE_BSP) != 0;
    if (is_bsp) {
        serial.println("[APIC] Running on BSP (Bootstrap Processor)");
    }

    // Enable APIC via MSR if not already enabled
    if ((msr_value & APIC_BASE_ENABLE) == 0) {
        wrmsr(IA32_APIC_BASE_MSR, msr_value | APIC_BASE_ENABLE);
        serial.println("[APIC] Enabled via MSR");
    }

    // Map APIC MMIO region into kernel address space
    // HHDM only maps RAM, so we need explicit mapping for device MMIO
    const phys_base = if (apic_base == 0) DEFAULT_APIC_BASE else apic_base;

    serial.puts("[APIC] Physical base: ");
    serial.putHex(phys_base);
    serial.puts("\n");

    // Map the APIC MMIO page (4KB is enough for all APIC registers)
    apic_base = vmm.mapMmio(phys_base, 4096) catch {
        serial.println("[APIC] Failed to map MMIO region");
        return false;
    };

    serial.puts("[APIC] Virtual base: ");
    serial.putHex(apic_base);
    serial.puts("\n");

    // Disable legacy PIC by masking all interrupts
    pic.disable();
    serial.println("[APIC] Legacy PIC disabled");

    // Set spurious interrupt vector and enable APIC
    // Bit 8 enables the APIC, bits 0-7 are the spurious vector
    writeReg(APIC_REG.SIVR, @as(u32, SPURIOUS_VECTOR) | (1 << 8));

    // Set task priority to 0 (accept all interrupts)
    writeReg(APIC_REG.TPR, 0);

    // Mask all LVT entries initially
    writeReg(APIC_REG.LVT_TIMER, LVT_MASKED);
    writeReg(APIC_REG.LVT_LINT0, LVT_MASKED);
    writeReg(APIC_REG.LVT_LINT1, LVT_MASKED);
    writeReg(APIC_REG.LVT_ERROR, LVT_MASKED);

    // Clear any pending errors
    writeReg(APIC_REG.ESR, 0);
    _ = readReg(APIC_REG.ESR);

    // Read APIC ID and version
    const apic_id = readReg(APIC_REG.ID) >> 24;
    const apic_version = readReg(APIC_REG.VERSION);
    const max_lvt = ((apic_version >> 16) & 0xFF) + 1;

    serial.puts("[APIC] ID: ");
    serial.putDec(apic_id);
    serial.puts(", Version: 0x");
    serial.putHex(apic_version & 0xFF);
    serial.puts(", Max LVT: ");
    serial.putDec(max_lvt);
    serial.puts("\n");

    apic_enabled = true;
    serial.println("[APIC] Initialization complete");

    return true;
}

/// Configure and start the APIC timer
pub fn initTimer(frequency_hz: u32) void {
    if (!apic_enabled) {
        serial.println("[APIC] Cannot init timer - APIC not enabled");
        return;
    }

    serial.puts("[APIC] Configuring timer for ");
    serial.putDec(frequency_hz);
    serial.puts(" Hz\n");

    // Set timer divider to 16
    writeReg(APIC_REG.TIMER_DCR, TimerDivider.DIV_16);

    // Calibrate timer using a busy loop
    // We'll measure how many ticks occur in a known time period
    // For simplicity, use PIT for calibration reference

    // Start with a large initial count
    writeReg(APIC_REG.TIMER_ICR, 0xFFFFFFFF);

    // Wait approximately 10ms using simple delay
    // (In a real system, you'd use PIT or HPET for precise calibration)
    var i: u32 = 0;
    while (i < 1000000) : (i += 1) {
        asm volatile ("pause");
    }

    // Stop timer and read count
    writeReg(APIC_REG.LVT_TIMER, LVT_MASKED);
    const elapsed = 0xFFFFFFFF - readReg(APIC_REG.TIMER_CCR);

    // Calculate ticks per second (rough estimate)
    // elapsed ticks occurred in ~10ms, so multiply by 100 for 1 second
    const ticks_per_second = elapsed * 100;
    timer_frequency = ticks_per_second;

    // Calculate initial count for desired frequency
    const initial_count = ticks_per_second / frequency_hz;

    serial.puts("[APIC] Timer calibrated: ");
    serial.putDec(ticks_per_second);
    serial.puts(" ticks/sec, initial count: ");
    serial.putDec(initial_count);
    serial.puts("\n");

    // Configure timer: periodic mode, unmask, vector 32
    writeReg(APIC_REG.LVT_TIMER, TimerMode.PERIODIC | TIMER_VECTOR);

    // Set initial count to start timer
    writeReg(APIC_REG.TIMER_ICR, @truncate(initial_count));

    serial.println("[APIC] Timer started");
}

/// Send End-Of-Interrupt to APIC
pub fn sendEoi() void {
    if (apic_enabled) {
        writeReg(APIC_REG.EOI, 0);
    } else {
        // Fallback to PIC EOI for the timer IRQ
        pic.sendEoi(0);
    }
}

/// Check if APIC is enabled
pub fn isEnabled() bool {
    return apic_enabled;
}

/// Get APIC ID
pub fn getId() u8 {
    if (!apic_enabled) return 0;
    return @truncate(readReg(APIC_REG.ID) >> 24);
}

/// Mask (disable) a Local Vector Table entry
pub fn maskLvt(lvt_reg: u32) void {
    if (!apic_enabled) return;
    const value = readReg(lvt_reg);
    writeReg(lvt_reg, value | LVT_MASKED);
}

/// Unmask (enable) a Local Vector Table entry
pub fn unmaskLvt(lvt_reg: u32) void {
    if (!apic_enabled) return;
    const value = readReg(lvt_reg);
    writeReg(lvt_reg, value & ~LVT_MASKED);
}

/// Get error status
pub fn getErrorStatus() u32 {
    if (!apic_enabled) return 0;
    // Write to ESR before reading (required by spec)
    writeReg(APIC_REG.ESR, 0);
    return readReg(APIC_REG.ESR);
}
