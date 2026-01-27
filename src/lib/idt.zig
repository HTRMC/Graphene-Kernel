// Graphene Kernel - Interrupt Descriptor Table (IDT)
// Handles CPU exceptions, hardware interrupts, and software interrupts

const std = @import("std");
const gdt = @import("gdt.zig");
const framebuffer = @import("framebuffer.zig");
const pic = @import("pic.zig");
const apic = @import("apic.zig");
const scheduler = @import("scheduler.zig");
const syscall = @import("syscall.zig");
const vmm = @import("vmm.zig");
const object = @import("object.zig");
const serial = @import("serial.zig");

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

    // Load IDT - use lidtq for 64-bit explicit size
    asm volatile (
        \\lidtq 0(%%rax)
        :
        : [idt_ptr] "{rax}" (&idt_pointer),
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
                asm volatile ("pushq $0");
            }
            // Push vector number
            asm volatile ("pushq %[vec]"
                :
                : [vec] "i" (@as(u64, vector)),
            );
            // Jump to common handler
            asm volatile ("jmp %[common:P]"
                :
                : [common] "X" (&interruptCommon),
            );
        }
    }.stub;
}

/// Syscall stub (vector 0x80)
fn syscall_stub() callconv(.naked) void {
    asm volatile (
        \\pushq $0          // No error code
        \\pushq $0x80       // Vector
    );
    asm volatile ("jmp %[common:P]"
        :
        : [common] "X" (&interruptCommon),
    );
}

/// Common interrupt handler entry point
fn interruptCommon() callconv(.naked) void {
    // Save all registers
    asm volatile (
        \\pushq %%rax
        \\pushq %%rbx
        \\pushq %%rcx
        \\pushq %%rdx
        \\pushq %%rsi
        \\pushq %%rdi
        \\pushq %%rbp
        \\pushq %%r8
        \\pushq %%r9
        \\pushq %%r10
        \\pushq %%r11
        \\pushq %%r12
        \\pushq %%r13
        \\pushq %%r14
        \\pushq %%r15
        \\
        \\movq %%rsp, %%rdi  // First argument: pointer to InterruptFrame
    );
    asm volatile ("call %[handler:P]"
        :
        : [handler] "X" (&interruptHandler),
    );
    asm volatile (
        \\popq %%r15
        \\popq %%r14
        \\popq %%r13
        \\popq %%r12
        \\popq %%r11
        \\popq %%r10
        \\popq %%r9
        \\popq %%r8
        \\popq %%rbp
        \\popq %%rdi
        \\popq %%rsi
        \\popq %%rdx
        \\popq %%rcx
        \\popq %%rbx
        \\popq %%rax
        \\
        \\addq $16, %%rsp    // Pop error code and vector
        \\iretq
    );
}

/// Main interrupt handler (called from assembly)
fn interruptHandler(frame: *InterruptFrame) void {
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

    // Check if exception occurred in user mode (RPL = 3 in CS selector)
    const in_user_mode = (frame.cs & 3) == 3;

    // For page faults, try VMM handler first
    if (vector == Exception.PAGE_FAULT) {
        const cr2 = asm volatile ("mov %%cr2, %[result]"
            : [result] "=r" (-> u64),
        );

        // Try VMM page fault handler
        if (vmm.isInitialized() and vmm.handlePageFault(cr2, frame.error_code)) {
            return; // Handled successfully
        }

        // If in user mode, terminate the process instead of panicking
        if (in_user_mode) {
            handleUserException(frame, "PAGE FAULT", cr2);
            return;
        }

        // Kernel page fault - this is fatal
        serial.println("\n!!! KERNEL PAGE FAULT !!!");
        serial.puts("CR2: ");
        serial.putHex(cr2);
        serial.puts("\nError code: ");
        serial.putHex(frame.error_code);
        serial.puts("\nRIP: ");
        serial.putHex(frame.rip);
        serial.puts("\n");

        framebuffer.puts("KERNEL PAGE FAULT", 10, 640, 0x00ff0000);
        framebuffer.puts("CR2:", 10, 660, 0x00ff0000);
        printHex64(cr2, 50, 660);
        framebuffer.puts("ERR:", 10, 680, 0x00ff0000);
        printHex64(frame.error_code, 50, 680);
    } else {
        // If in user mode, terminate the process instead of panicking
        if (in_user_mode) {
            handleUserException(frame, if (vector < exception_names.len) exception_names[vector] else "Unknown", 0);
            return;
        }

        // Kernel exception - fatal
        const name = if (vector < exception_names.len) exception_names[vector] else "Unknown";

        serial.println("\n!!! KERNEL PANIC !!!");
        serial.puts("Exception: ");
        serial.puts(name);
        serial.puts("\nRIP: ");
        serial.putHex(frame.rip);
        serial.puts("\nError code: ");
        serial.putHex(frame.error_code);
        serial.puts("\n");

        framebuffer.puts("KERNEL PANIC:", 10, 640, 0x00ff0000);
        framebuffer.puts(name, 130, 640, 0x00ff0000);
        framebuffer.puts("RIP:", 10, 660, 0x00ff0000);
        printHex64(frame.rip, 50, 660);
    }

    // Halt on kernel exception
    asm volatile ("cli");
    while (true) {
        asm volatile ("hlt");
    }
}

/// Handle exception in user mode - terminate the process gracefully
fn handleUserException(frame: *InterruptFrame, reason: []const u8, fault_addr: u64) void {
    // Log to serial console
    serial.puts("\n[FAULT] User process exception: ");
    serial.puts(reason);
    serial.puts("\n");
    serial.puts("[FAULT] RIP: ");
    serial.putHex(frame.rip);
    if (fault_addr != 0) {
        serial.puts(" Fault address: ");
        serial.putHex(fault_addr);
    }
    serial.puts("\n");

    // Get current process and thread
    const current_thread = scheduler.getCurrent();
    if (current_thread) |t| {
        const process = @import("process.zig");
        if (t.process) |proc_ptr| {
            const proc: *process.Process = @ptrCast(@alignCast(proc_ptr));
            serial.puts("[FAULT] Process: ");
            // Print process name (null-terminated)
            for (proc.name) |c| {
                if (c == 0) break;
                serial.putChar(c);
            }
            serial.puts(" (PID ");
            serial.putDec(proc.pid);
            serial.puts(")\n");

            // Mark process as crashed
            proc.state = .zombie;
            proc.exit_code = @bitCast(@as(u32, 0xFFFFFFFF)); // Signal abnormal termination (-1)

            // Mark all threads as zombie
            for (proc.threads) |maybe_thread| {
                if (maybe_thread) |thread_ptr| {
                    thread_ptr.state = .zombie;
                }
            }
        }

        // Mark current thread as zombie
        t.state = .zombie;
    }

    serial.println("[FAULT] Process terminated, continuing scheduler");

    // Yield to scheduler to run other processes
    if (scheduler.isRunning()) {
        scheduler.yield();
    }

    // If scheduler returns (shouldn't happen), halt
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
        1 => {
            // Keyboard IRQ - wake user-space driver if registered
            if (object.getIrqObject(1)) |irq_obj| {
                irq_obj.pending_count += 1;
                if (irq_obj.wait_queue.dequeue()) |waiting_thread| {
                    scheduler.wake(waiting_thread);
                }
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

    // Send End-Of-Interrupt
    if (apic.isEnabled()) {
        apic.sendEoi();
    } else {
        pic.sendEoi(irq);
    }
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

/// Print a 64-bit value as hex for debugging
fn printHex64(value: u64, x: u32, y: u32) void {
    const hex_chars = "0123456789ABCDEF";
    var buf: [18]u8 = undefined;
    buf[0] = '0';
    buf[1] = 'x';
    var v = value;
    var i: usize = 17;
    while (i >= 2) : (i -= 1) {
        buf[i] = hex_chars[@truncate(v & 0xF)];
        v >>= 4;
    }
    framebuffer.puts(&buf, x, y, 0x00ff8888);
}
