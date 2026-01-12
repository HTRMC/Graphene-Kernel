// Graphene Kernel - Interrupt Descriptor Table (IDT)
// Handles CPU exceptions, hardware interrupts, and software interrupts

const std = @import("std");
const gdt = @import("gdt.zig");
const framebuffer = @import("framebuffer.zig");
const pic = @import("pic.zig");
const scheduler = @import("scheduler.zig");
const syscall = @import("syscall.zig");
const vmm = @import("vmm.zig");
const object = @import("object.zig");

/// Number of IDT entries (256 possible interrupt vectors)
const IDT_ENTRIES = 256;

/// Interrupt gate types
const GateType = struct {
    const INTERRUPT: u4 = 0xE; // 64-bit interrupt gate (clears IF)
    const TRAP: u4 = 0xF; // 64-bit trap gate (preserves IF)
};

/// IDT entry (16 bytes in 64-bit mode)
const IdtEntry = packed struct {
    offset_low: u16,
    selector: u16,
    ist: u8, // Bits 0-2: IST index, bits 3-7: reserved (zero)
    type_attr: u8, // Type (4 bits) + zero + DPL (2 bits) + present (1 bit)
    offset_mid: u16,
    offset_high: u32,
    reserved: u32 = 0,

    fn missing() IdtEntry {
        return .{
            .offset_low = 0,
            .selector = 0,
            .ist = 0,
            .type_attr = 0,
            .offset_mid = 0,
            .offset_high = 0,
        };
    }

    fn init(handler: u64, ist_index: u3, gate_type: u4, dpl: u2) IdtEntry {
        return .{
            .offset_low = @truncate(handler),
            .selector = gdt.Selector.KERNEL_CODE,
            .ist = ist_index,
            .type_attr = (@as(u8, 1) << 7) | // Present
                (@as(u8, dpl) << 5) | // DPL
                gate_type,
            .offset_mid = @truncate(handler >> 16),
            .offset_high = @truncate(handler >> 32),
        };
    }
};

/// IDT pointer for LIDT instruction
const IdtPointer = packed struct {
    limit: u16,
    base: u64,
};

/// CPU exception vectors
pub const Exception = struct {
    pub const DIVIDE_ERROR: u8 = 0;
    pub const DEBUG: u8 = 1;
    pub const NMI: u8 = 2;
    pub const BREAKPOINT: u8 = 3;
    pub const OVERFLOW: u8 = 4;
    pub const BOUND_RANGE: u8 = 5;
    pub const INVALID_OPCODE: u8 = 6;
    pub const DEVICE_NOT_AVAILABLE: u8 = 7;
    pub const DOUBLE_FAULT: u8 = 8;
    pub const COPROCESSOR_SEGMENT: u8 = 9;
    pub const INVALID_TSS: u8 = 10;
    pub const SEGMENT_NOT_PRESENT: u8 = 11;
    pub const STACK_FAULT: u8 = 12;
    pub const GENERAL_PROTECTION: u8 = 13;
    pub const PAGE_FAULT: u8 = 14;
    pub const X87_FPU: u8 = 16;
    pub const ALIGNMENT_CHECK: u8 = 17;
    pub const MACHINE_CHECK: u8 = 18;
    pub const SIMD_FPU: u8 = 19;
    pub const VIRTUALIZATION: u8 = 20;
    pub const CONTROL_PROTECTION: u8 = 21;
    pub const HYPERVISOR_INJECTION: u8 = 28;
    pub const VMM_COMMUNICATION: u8 = 29;
    pub const SECURITY: u8 = 30;
};

/// IRQ vectors (remapped to start at 32)
pub const IRQ = struct {
    pub const TIMER: u8 = 32;
    pub const KEYBOARD: u8 = 33;
    pub const CASCADE: u8 = 34;
    pub const COM2: u8 = 35;
    pub const COM1: u8 = 36;
    pub const LPT2: u8 = 37;
    pub const FLOPPY: u8 = 38;
    pub const LPT1: u8 = 39;
    pub const RTC: u8 = 40;
    pub const FREE1: u8 = 41;
    pub const FREE2: u8 = 42;
    pub const FREE3: u8 = 43;
    pub const MOUSE: u8 = 44;
    pub const FPU: u8 = 45;
    pub const PRIMARY_ATA: u8 = 46;
    pub const SECONDARY_ATA: u8 = 47;
};

/// Syscall vector
pub const SYSCALL_VECTOR: u8 = 0x80;

/// Interrupt frame pushed by CPU + our stub
pub const InterruptFrame = extern struct {
    // Pushed by our stub (in reverse order)
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rbp: u64,
    rdi: u64,
    rsi: u64,
    rdx: u64,
    rcx: u64,
    rbx: u64,
    rax: u64,
    // Pushed by our stub
    vector: u64,
    error_code: u64,
    // Pushed by CPU
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

// Static IDT
var idt: [IDT_ENTRIES]IdtEntry = [_]IdtEntry{IdtEntry.missing()} ** IDT_ENTRIES;
var idt_pointer: IdtPointer = undefined;

/// Exception names for debugging
const exception_names = [_][]const u8{
    "Divide Error",
    "Debug",
    "NMI",
    "Breakpoint",
    "Overflow",
    "Bound Range Exceeded",
    "Invalid Opcode",
    "Device Not Available",
    "Double Fault",
    "Coprocessor Segment Overrun",
    "Invalid TSS",
    "Segment Not Present",
    "Stack-Segment Fault",
    "General Protection Fault",
    "Page Fault",
    "Reserved",
    "x87 FPU Error",
    "Alignment Check",
    "Machine Check",
    "SIMD FPU Exception",
    "Virtualization Exception",
    "Control Protection Exception",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Reserved",
    "Hypervisor Injection",
    "VMM Communication",
    "Security Exception",
    "Reserved",
};

/// Initialize the IDT with all handlers
pub fn init() void {
    // Set up exception handlers (0-31)
    setExceptionHandlers();

    // Set up IRQ handlers (32-47)
    setIrqHandlers();

    // Set up syscall handler (0x80) - accessible from ring 3
    idt[SYSCALL_VECTOR] = IdtEntry.init(@intFromPtr(&syscall_stub), 0, GateType.INTERRUPT, 3);

    // Set up IDT pointer
    idt_pointer = .{
        .limit = @sizeOf(@TypeOf(idt)) - 1,
        .base = @intFromPtr(&idt),
    };

    // Load IDT
    asm volatile ("lidt (%[idt_ptr])"
        :
        : [idt_ptr] "r" (&idt_pointer),
    );
}

/// Check if an exception vector pushes an error code (comptime)
fn hasErrorCode(comptime vector: u8) bool {
    return switch (vector) {
        8, 10, 11, 12, 13, 14, 17, 21, 29, 30 => true,
        else => false,
    };
}

fn setExceptionHandlers() void {
    inline for (0..32) |i| {
        const handler = makeInterruptStub(i, hasErrorCode(i));
        // Double fault uses IST 1 for safety
        const ist: u3 = if (i == 8) 1 else 0;
        idt[i] = IdtEntry.init(@intFromPtr(handler), ist, GateType.INTERRUPT, 0);
    }
}

fn setIrqHandlers() void {
    inline for (32..48) |i| {
        const handler = makeInterruptStub(i, false);
        idt[i] = IdtEntry.init(@intFromPtr(handler), 0, GateType.INTERRUPT, 0);
    }
}

/// Generate an interrupt stub at compile time
fn makeInterruptStub(comptime vector: u8, comptime has_error_code: bool) *const fn () callconv(.naked) void {
    return struct {
        fn stub() callconv(.naked) void {
            // Push dummy error code if CPU doesn't push one
            if (!has_error_code) {
                asm volatile ("push $0");
            }
            // Push vector number
            asm volatile ("push %[vec]"
                :
                : [vec] "i" (@as(u64, vector)),
            );
            // Jump to common handler
            asm volatile ("jmp interrupt_common");
        }
    }.stub;
}

/// Syscall stub (vector 0x80)
fn syscall_stub() callconv(.naked) void {
    asm volatile (
        \\push $0          // No error code
        \\push $0x80       // Vector
        \\jmp interrupt_common
    );
}

/// Common interrupt handler entry point
export fn interrupt_common() callconv(.naked) void {
    // Save all registers
    asm volatile (
        \\push %%rax
        \\push %%rbx
        \\push %%rcx
        \\push %%rdx
        \\push %%rsi
        \\push %%rdi
        \\push %%rbp
        \\push %%r8
        \\push %%r9
        \\push %%r10
        \\push %%r11
        \\push %%r12
        \\push %%r13
        \\push %%r14
        \\push %%r15
        \\
        \\mov %%rsp, %%rdi  // First argument: pointer to InterruptFrame
        \\call interrupt_handler
        \\
        \\pop %%r15
        \\pop %%r14
        \\pop %%r13
        \\pop %%r12
        \\pop %%r11
        \\pop %%r10
        \\pop %%r9
        \\pop %%r8
        \\pop %%rbp
        \\pop %%rdi
        \\pop %%rsi
        \\pop %%rdx
        \\pop %%rcx
        \\pop %%rbx
        \\pop %%rax
        \\
        \\add $16, %%rsp    // Pop error code and vector
        \\iretq
    );
}

/// Main interrupt handler (called from assembly)
export fn interrupt_handler(frame: *InterruptFrame) void {
    const vector = frame.vector;

    if (vector < 32) {
        // CPU exception
        handleException(frame);
    } else if (vector < 48) {
        // Hardware IRQ
        handleIrq(frame);
    } else if (vector == SYSCALL_VECTOR) {
        // Syscall
        handleSyscall(frame);
    }
}

fn handleException(frame: *InterruptFrame) void {
    const vector = frame.vector;

    // For page faults, try VMM handler first
    if (vector == Exception.PAGE_FAULT) {
        const cr2 = asm volatile ("mov %%cr2, %[result]"
            : [result] "=r" (-> u64),
        );

        // Try VMM page fault handler
        if (vmm.isInitialized() and vmm.handlePageFault(cr2, frame.error_code)) {
            return; // Handled successfully
        }

        // VMM couldn't handle it - panic
        framebuffer.puts("PAGE FAULT!", 10, 200, 0x00ff0000);
        framebuffer.puts("Address: (see CR2)", 10, 220, 0x00ff0000);
    } else {
        const name = if (vector < exception_names.len) exception_names[vector] else "Unknown";
        framebuffer.puts("KERNEL PANIC!", 10, 200, 0x00ff0000);
        framebuffer.puts(name, 10, 220, 0x00ff0000);
    }

    // Halt on unhandled exception
    asm volatile ("cli");
    while (true) {
        asm volatile ("hlt");
    }
}

fn handleIrq(frame: *InterruptFrame) void {
    const irq: u8 = @truncate(frame.vector - 32);

    // Handle specific IRQs
    switch (irq) {
        0 => {
            // Timer interrupt - call scheduler tick
            if (scheduler.isRunning()) {
                scheduler.tick();
            }
        },
        else => {
            // Other hardware IRQs - wake user-space driver if registered
            if (object.getIrqObject(irq)) |irq_obj| {
                // Increment pending count (IRQ fired)
                irq_obj.pending_count += 1;

                // Wake one waiting driver thread if any
                if (irq_obj.wait_queue.dequeue()) |waiting_thread| {
                    scheduler.wake(waiting_thread);
                }
            }
        },
    }

    // Send End-Of-Interrupt to PIC
    pic.sendEoi(irq);
}

fn handleSyscall(frame: *InterruptFrame) void {
    // Dispatch to syscall handler
    syscall.handle(frame);
}

/// Enable interrupts
pub fn enable() void {
    asm volatile ("sti");
}

/// Disable interrupts
pub fn disable() void {
    asm volatile ("cli");
}

/// Check if interrupts are enabled
pub fn areEnabled() bool {
    const flags = asm volatile ("pushfq; pop %[flags]"
        : [flags] "=r" (-> u64),
    );
    return (flags & (1 << 9)) != 0;
}
