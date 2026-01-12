// Graphene Kernel - Syscall Entry
// System call dispatch and handlers

const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const framebuffer = @import("framebuffer.zig");
const capability = @import("capability.zig");
const object = @import("object.zig");
const thread = @import("thread.zig");
const process = @import("process.zig");
const scheduler = @import("scheduler.zig");
const vmm = @import("vmm.zig");
const usermode = @import("usermode.zig");

/// Syscall numbers (from DESIGN.md)
pub const SyscallNumber = enum(u64) {
    cap_send = 0,
    cap_recv = 1,
    cap_call = 2,
    cap_copy = 3,
    cap_delete = 4,
    cap_revoke = 5,
    mem_map = 6,
    mem_unmap = 7,
    thread_create = 8,
    thread_exit = 9,
    thread_yield = 10,
    process_create = 11,
    process_exit = 12,
    irq_wait = 13,
    irq_ack = 14,
    debug_print = 15,
    // Extensions
    cap_info = 16, // Get capability info
    process_info = 17, // Get process info
    _,
};

/// Syscall error codes
pub const SyscallError = enum(i64) {
    success = 0,
    invalid_syscall = -1,
    invalid_capability = -2,
    permission_denied = -3,
    invalid_argument = -4,
    out_of_memory = -5,
    would_block = -6,
    not_found = -7,
    not_implemented = -8,
    type_mismatch = -9,
    table_full = -10,
};

/// MSR addresses for syscall/sysret
const IA32_STAR: u32 = 0xC0000081;
const IA32_LSTAR: u32 = 0xC0000082;
const IA32_FMASK: u32 = 0xC0000084;
const IA32_EFER: u32 = 0xC0000080;

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

/// Syscall handler state
var syscall_initialized: bool = false;

/// Initialize syscall mechanism
pub fn init() void {
    // For Phase 1, we use int 0x80 which is already set up in IDT
    // Fast syscall/sysret setup is more complex and requires per-CPU data

    // Enable SCE (System Call Extensions) in EFER
    var efer = rdmsr(IA32_EFER);
    efer |= 1; // SCE bit
    wrmsr(IA32_EFER, efer);

    // Set up STAR register
    // Bits 63:48 = SYSRET CS and SS (user code/data)
    // Bits 47:32 = SYSCALL CS and SS (kernel code/data)
    // For SYSRET: CS = bits[63:48] + 16, SS = bits[63:48] + 8
    // For SYSCALL: CS = bits[47:32], SS = bits[47:32] + 8
    const sysret_base = @as(u64, gdt.Selector.USER_DATA - 8); // 0x1B - 8 = 0x13
    const syscall_base = @as(u64, gdt.Selector.KERNEL_CODE);
    const star_value = (sysret_base << 48) | (syscall_base << 32);
    wrmsr(IA32_STAR, star_value);

    // Set LSTAR to syscall entry (for fast syscall - not used in Phase 1)
    // wrmsr(IA32_LSTAR, @intFromPtr(&syscall_entry_fast));

    // Set FMASK - flags to clear on syscall (clear IF)
    wrmsr(IA32_FMASK, 0x200);

    syscall_initialized = true;
}

/// Main syscall handler (called from IDT handler via interrupt_handler)
/// This is called when int 0x80 is triggered
pub fn handle(frame: *idt.InterruptFrame) void {
    const syscall_num = frame.rax;
    const args = [6]u64{
        frame.rdi,
        frame.rsi,
        frame.rdx,
        frame.r10, // r10 replaces rcx for syscall (rcx is used by syscall instruction)
        frame.r8,
        frame.r9,
    };

    const result = dispatch(syscall_num, args);
    frame.rax = @bitCast(result);
}

/// Dispatch syscall to appropriate handler
fn dispatch(num: u64, args: [6]u64) i64 {
    const syscall = @as(SyscallNumber, @enumFromInt(num));

    return switch (syscall) {
        .cap_send => sysCapSend(args),
        .cap_recv => sysCapRecv(args),
        .cap_call => sysCapCall(args),
        .cap_copy => sysCapCopy(args),
        .cap_delete => sysCapDelete(args),
        .cap_revoke => sysCapRevoke(args),
        .mem_map => sysMemMap(args),
        .mem_unmap => sysMemUnmap(args),
        .thread_create => sysThreadCreate(args),
        .thread_exit => sysThreadExit(args),
        .thread_yield => sysThreadYield(args),
        .process_create => sysProcessCreate(args),
        .process_exit => sysProcessExit(args),
        .irq_wait => sysIrqWait(args),
        .irq_ack => sysIrqAck(args),
        .debug_print => sysDebugPrint(args),
        .cap_info => sysCapInfo(args),
        .process_info => sysProcessInfo(args),
        _ => @intFromEnum(SyscallError.invalid_syscall),
    };
}

// ============================================================================
// Syscall Handlers (Phase 1: Stubs, to be implemented with scheduler/IPC)
// ============================================================================

fn sysCapSend(args: [6]u64) i64 {
    // cap_send(cap_slot, msg_ptr, msg_len)
    _ = args;
    // Requires IPC implementation
    return @intFromEnum(SyscallError.not_implemented);
}

fn sysCapRecv(args: [6]u64) i64 {
    // cap_recv(cap_slot, buf_ptr, buf_len)
    _ = args;
    // Requires IPC implementation
    return @intFromEnum(SyscallError.not_implemented);
}

fn sysCapCall(args: [6]u64) i64 {
    // cap_call(cap_slot, msg_ptr, msg_len, reply_ptr, reply_len)
    _ = args;
    // Requires IPC implementation
    return @intFromEnum(SyscallError.not_implemented);
}

fn sysCapCopy(args: [6]u64) i64 {
    // cap_copy(src_slot, dst_slot, rights_mask)
    const src_slot: capability.CapSlot = @truncate(args[0]);
    const dst_slot: capability.CapSlot = @truncate(args[1]);
    const rights_mask: capability.Rights = @bitCast(@as(u8, @truncate(args[2])));

    // Get current process's capability table
    // For Phase 1, we don't have processes yet, return not_implemented
    _ = src_slot;
    _ = dst_slot;
    _ = rights_mask;
    return @intFromEnum(SyscallError.not_implemented);
}

fn sysCapDelete(args: [6]u64) i64 {
    // cap_delete(slot)
    const slot: capability.CapSlot = @truncate(args[0]);
    _ = slot;
    return @intFromEnum(SyscallError.not_implemented);
}

fn sysCapRevoke(args: [6]u64) i64 {
    // cap_revoke(slot)
    const slot: capability.CapSlot = @truncate(args[0]);
    _ = slot;
    return @intFromEnum(SyscallError.not_implemented);
}

fn sysMemMap(args: [6]u64) i64 {
    // mem_map(cap_slot, vaddr, size, flags)
    const cap_slot: capability.CapSlot = @truncate(args[0]);
    const vaddr = args[1];
    const size = args[2];
    const flags = args[3];
    _ = cap_slot;
    _ = vaddr;
    _ = size;
    _ = flags;
    return @intFromEnum(SyscallError.not_implemented);
}

fn sysMemUnmap(args: [6]u64) i64 {
    // mem_unmap(vaddr, size)
    const vaddr = args[0];
    const size = args[1];
    _ = vaddr;
    _ = size;
    return @intFromEnum(SyscallError.not_implemented);
}

fn sysThreadCreate(args: [6]u64) i64 {
    // thread_create(entry, stack_cap, arg)
    _ = args;
    // Requires scheduler implementation
    return @intFromEnum(SyscallError.not_implemented);
}

fn sysThreadExit(args: [6]u64) i64 {
    // thread_exit(code)
    const code: i32 = @truncate(@as(i64, @bitCast(args[0])));

    // Mark current thread as zombie
    if (thread.getCurrentThreadUnsafe()) |t| {
        t.state = .zombie;
    }

    // If scheduler is running, yield to let it clean up
    if (scheduler.isRunning()) {
        scheduler.yield();
    }

    // Should not return, but if it does, halt
    asm volatile ("cli");
    while (true) {
        asm volatile ("hlt");
    }

    _ = code;
    return 0; // Never reached
}

fn sysThreadYield(args: [6]u64) i64 {
    // thread_yield()
    _ = args;

    if (scheduler.isRunning()) {
        scheduler.yield();
    }

    return 0;
}

fn sysProcessCreate(args: [6]u64) i64 {
    // process_create(image_cap, caps_to_grant[])
    _ = args;
    return @intFromEnum(SyscallError.not_implemented);
}

fn sysProcessExit(args: [6]u64) i64 {
    // process_exit(code)
    const code: i32 = @truncate(@as(i64, @bitCast(args[0])));

    // Get current process and exit it
    if (process.getCurrentProcess()) |proc| {
        proc.exit_code = code;
        proc.state = .zombie;

        // Mark all threads as zombie
        for (proc.threads) |maybe_thread| {
            if (maybe_thread) |t| {
                t.state = .zombie;
            }
        }
    }

    // If scheduler is running, yield
    if (scheduler.isRunning()) {
        scheduler.yield();
    }

    // Should not return
    asm volatile ("cli");
    while (true) {
        asm volatile ("hlt");
    }

    return 0; // Never reached
}

fn sysIrqWait(args: [6]u64) i64 {
    // irq_wait(cap_slot)
    _ = args;
    return @intFromEnum(SyscallError.not_implemented);
}

fn sysIrqAck(args: [6]u64) i64 {
    // irq_ack(cap_slot)
    _ = args;
    return @intFromEnum(SyscallError.not_implemented);
}

/// Debug print Y position (advances with each print)
var debug_y: u32 = 300;

fn sysDebugPrint(args: [6]u64) i64 {
    // debug_print(str_ptr, str_len)
    const str_ptr = args[0];
    const str_len = args[1];

    if (str_len > 1024) {
        return @intFromEnum(SyscallError.invalid_argument);
    }

    // Validate user buffer
    if (!usermode.isUserAddress(str_ptr) or !usermode.isUserAddress(str_ptr + str_len - 1)) {
        return @intFromEnum(SyscallError.invalid_argument);
    }

    // Get string from user space
    const str: [*]const u8 = @ptrFromInt(str_ptr);
    const slice = str[0..@min(str_len, 256)];

    // Print to framebuffer
    var y: u32 = debug_y;
    var x: u32 = 10;
    for (slice) |c| {
        if (c == '\n') {
            y += 16;
            x = 10;
        } else if (c >= 32 and c < 127) {
            framebuffer.putChar(c, x, y, 0x0000ff00); // Green for user output
            x += 8;
            if (x > 780) {
                x = 10;
                y += 16;
            }
        }
    }

    // Update position for next print
    debug_y = y + 16;
    if (debug_y > 580) {
        debug_y = 300; // Wrap around
    }

    return @intCast(str_len);
}

fn sysCapInfo(args: [6]u64) i64 {
    // cap_info(slot) -> returns type and rights packed
    const slot: capability.CapSlot = @truncate(args[0]);
    _ = slot;
    return @intFromEnum(SyscallError.not_implemented);
}

fn sysProcessInfo(args: [6]u64) i64 {
    // process_info(what) -> returns various process info
    _ = args;
    return @intFromEnum(SyscallError.not_implemented);
}

/// Check if syscall is initialized
pub fn isInitialized() bool {
    return syscall_initialized;
}

/// Get syscall name for debugging
pub fn getName(num: u64) []const u8 {
    const syscall = @as(SyscallNumber, @enumFromInt(num));
    return switch (syscall) {
        .cap_send => "cap_send",
        .cap_recv => "cap_recv",
        .cap_call => "cap_call",
        .cap_copy => "cap_copy",
        .cap_delete => "cap_delete",
        .cap_revoke => "cap_revoke",
        .mem_map => "mem_map",
        .mem_unmap => "mem_unmap",
        .thread_create => "thread_create",
        .thread_exit => "thread_exit",
        .thread_yield => "thread_yield",
        .process_create => "process_create",
        .process_exit => "process_exit",
        .irq_wait => "irq_wait",
        .irq_ack => "irq_ack",
        .debug_print => "debug_print",
        .cap_info => "cap_info",
        .process_info => "process_info",
        _ => "unknown",
    };
}
