// Graphene User Library - System Call Wrappers
// Provides type-safe syscall interface for user programs

/// Syscall numbers (must match kernel's syscall.zig)
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
    cap_info = 16,
    process_info = 17,
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

/// Raw syscall with 0-6 arguments
inline fn syscall0(num: u64) i64 {
    return asm volatile ("int $0x80"
        : [ret] "={rax}" (-> i64),
        : [num] "{rax}" (num),
        : "memory"
    );
}

inline fn syscall1(num: u64, a1: u64) i64 {
    return asm volatile ("int $0x80"
        : [ret] "={rax}" (-> i64),
        : [num] "{rax}" (num),
          [a1] "{rdi}" (a1),
        : "memory"
    );
}

inline fn syscall2(num: u64, a1: u64, a2: u64) i64 {
    return asm volatile ("int $0x80"
        : [ret] "={rax}" (-> i64),
        : [num] "{rax}" (num),
          [a1] "{rdi}" (a1),
          [a2] "{rsi}" (a2),
        : "memory"
    );
}

inline fn syscall3(num: u64, a1: u64, a2: u64, a3: u64) i64 {
    return asm volatile ("int $0x80"
        : [ret] "={rax}" (-> i64),
        : [num] "{rax}" (num),
          [a1] "{rdi}" (a1),
          [a2] "{rsi}" (a2),
          [a3] "{rdx}" (a3),
        : "memory"
    );
}

inline fn syscall4(num: u64, a1: u64, a2: u64, a3: u64, a4: u64) i64 {
    return asm volatile ("int $0x80"
        : [ret] "={rax}" (-> i64),
        : [num] "{rax}" (num),
          [a1] "{rdi}" (a1),
          [a2] "{rsi}" (a2),
          [a3] "{rdx}" (a3),
          [a4] "{r10}" (a4),
        : "memory"
    );
}

inline fn syscall5(num: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64) i64 {
    return asm volatile ("int $0x80"
        : [ret] "={rax}" (-> i64),
        : [num] "{rax}" (num),
          [a1] "{rdi}" (a1),
          [a2] "{rsi}" (a2),
          [a3] "{rdx}" (a3),
          [a4] "{r10}" (a4),
          [a5] "{r8}" (a5),
        : "memory"
    );
}

// ============================================================================
// High-level syscall wrappers
// ============================================================================

/// Print a debug message to the kernel console
pub fn debugPrint(msg: []const u8) i64 {
    return syscall2(
        @intFromEnum(SyscallNumber.debug_print),
        @intFromPtr(msg.ptr),
        msg.len,
    );
}

/// Exit the current thread
pub fn threadExit(code: i32) noreturn {
    _ = syscall1(
        @intFromEnum(SyscallNumber.thread_exit),
        @bitCast(@as(i64, code)),
    );
    unreachable;
}

/// Exit the current process
pub fn processExit(code: i32) noreturn {
    _ = syscall1(
        @intFromEnum(SyscallNumber.process_exit),
        @bitCast(@as(i64, code)),
    );
    unreachable;
}

/// Yield the current thread's time slice
pub fn threadYield() void {
    _ = syscall0(@intFromEnum(SyscallNumber.thread_yield));
}

/// Map memory (requires memory capability)
pub fn memMap(cap_slot: u32, vaddr: u64, size: u64, flags: u64) i64 {
    return syscall4(
        @intFromEnum(SyscallNumber.mem_map),
        cap_slot,
        vaddr,
        size,
        flags,
    );
}

/// Unmap memory
pub fn memUnmap(vaddr: u64, size: u64) i64 {
    return syscall2(
        @intFromEnum(SyscallNumber.mem_unmap),
        vaddr,
        size,
    );
}

/// Send a message via IPC capability
pub fn capSend(cap_slot: u32, msg_ptr: [*]const u8, msg_len: usize) i64 {
    return syscall3(
        @intFromEnum(SyscallNumber.cap_send),
        cap_slot,
        @intFromPtr(msg_ptr),
        msg_len,
    );
}

/// Receive a message via IPC capability
pub fn capRecv(cap_slot: u32, buf_ptr: [*]u8, buf_len: usize) i64 {
    return syscall3(
        @intFromEnum(SyscallNumber.cap_recv),
        cap_slot,
        @intFromPtr(buf_ptr),
        buf_len,
    );
}

/// Call and wait for reply (synchronous RPC)
pub fn capCall(cap_slot: u32, msg: []const u8, reply: []u8) i64 {
    return syscall5(
        @intFromEnum(SyscallNumber.cap_call),
        cap_slot,
        @intFromPtr(msg.ptr),
        msg.len,
        @intFromPtr(reply.ptr),
        reply.len,
    );
}

/// Copy capability with reduced rights
pub fn capCopy(src_slot: u32, dst_slot: u32, rights_mask: u8) i64 {
    return syscall3(
        @intFromEnum(SyscallNumber.cap_copy),
        src_slot,
        dst_slot,
        rights_mask,
    );
}

/// Delete a capability
pub fn capDelete(slot: u32) i64 {
    return syscall1(@intFromEnum(SyscallNumber.cap_delete), slot);
}

/// Revoke all derived capabilities
pub fn capRevoke(slot: u32) i64 {
    return syscall1(@intFromEnum(SyscallNumber.cap_revoke), slot);
}

/// Wait for IRQ (requires IRQ capability)
pub fn irqWait(cap_slot: u32) i64 {
    return syscall1(@intFromEnum(SyscallNumber.irq_wait), cap_slot);
}

/// Acknowledge IRQ
pub fn irqAck(cap_slot: u32) i64 {
    return syscall1(@intFromEnum(SyscallNumber.irq_ack), cap_slot);
}

// ============================================================================
// Helper functions
// ============================================================================

/// Print a string literal (compile-time known)
pub fn print(comptime msg: []const u8) void {
    _ = debugPrint(msg);
}

/// Check if syscall result is an error
pub fn isError(result: i64) bool {
    return result < 0;
}

/// Convert result to error enum
pub fn toError(result: i64) ?SyscallError {
    if (result >= 0) return null;
    return @enumFromInt(result);
}
