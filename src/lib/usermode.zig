// Graphene Kernel - User Mode Transition
// Handles Ring 0 to Ring 3 transitions via iretq

const gdt = @import("gdt.zig");
const vmm = @import("vmm.zig");

/// User stack size (64KB)
pub const USER_STACK_SIZE: u64 = 64 * 1024;

/// Default user stack top (grows down from here)
pub const USER_STACK_TOP: u64 = 0x7FFFFFF00000;

/// User stack bottom (USER_STACK_TOP - USER_STACK_SIZE)
pub const USER_STACK_BOTTOM: u64 = USER_STACK_TOP - USER_STACK_SIZE;

/// Jump to user mode at the specified entry point with given stack
/// This function never returns (from kernel perspective)
pub fn jumpToUser(entry: u64, user_stack: u64, arg: u64) noreturn {
    // Validate addresses are in user space
    if (entry < vmm.USER_BASE or entry >= vmm.USER_TOP) {
        // Invalid entry point - halt
        asm volatile ("cli");
        while (true) {
            asm volatile ("hlt");
        }
    }

    if (user_stack < vmm.USER_BASE or user_stack >= vmm.USER_TOP) {
        // Invalid stack - halt
        asm volatile ("cli");
        while (true) {
            asm volatile ("hlt");
        }
    }

    // Set up the iretq frame on the current kernel stack:
    // [SS]      - User data segment selector (0x1B)
    // [RSP]     - User stack pointer
    // [RFLAGS]  - Flags with IF set (interrupts enabled)
    // [CS]      - User code segment selector (0x23)
    // [RIP]     - Entry point

    // The argument goes in RDI (System V ABI first argument)
    asm volatile (
        \\mov %[arg], %%rdi
        \\push %[ss]
        \\push %[stack]
        \\pushfq
        \\orq $0x200, (%%rsp)
        \\push %[cs]
        \\push %[entry]
        \\iretq
        :
        : [entry] "r" (entry),
          [stack] "r" (user_stack),
          [arg] "r" (arg),
          [cs] "i" (@as(u64, gdt.Selector.USER_CODE)),
          [ss] "i" (@as(u64, gdt.Selector.USER_DATA)),
        : .{ .rdi = true });

    unreachable;
}

/// Jump to user mode with multiple arguments (up to 6, following System V ABI)
pub fn jumpToUserArgs(
    entry: u64,
    user_stack: u64,
    arg1: u64,
    arg2: u64,
    arg3: u64,
    arg4: u64,
) noreturn {
    // Validate addresses
    if (entry < vmm.USER_BASE or entry >= vmm.USER_TOP) {
        asm volatile ("cli");
        while (true) {
            asm volatile ("hlt");
        }
    }

    if (user_stack < vmm.USER_BASE or user_stack >= vmm.USER_TOP) {
        asm volatile ("cli");
        while (true) {
            asm volatile ("hlt");
        }
    }

    // Set up arguments in registers (System V ABI: rdi, rsi, rdx, rcx, r8, r9)
    // Then perform iretq
    asm volatile (
        \\mov %[a1], %%rdi
        \\mov %[a2], %%rsi
        \\mov %[a3], %%rdx
        \\mov %[a4], %%rcx
        \\push %[ss]
        \\push %[stack]
        \\pushfq
        \\orq $0x200, (%%rsp)
        \\push %[cs]
        \\push %[entry]
        \\iretq
        :
        : [entry] "r" (entry),
          [stack] "r" (user_stack),
          [a1] "r" (arg1),
          [a2] "r" (arg2),
          [a3] "r" (arg3),
          [a4] "r" (arg4),
          [cs] "i" (@as(u64, gdt.Selector.USER_CODE)),
          [ss] "i" (@as(u64, gdt.Selector.USER_DATA)),
        : .{ .rdi = true, .rsi = true, .rdx = true, .rcx = true });

    unreachable;
}

/// Return from syscall to user mode (restores context from interrupt frame)
/// This is used when returning from a syscall handler
pub fn returnToUser(frame: *anyopaque) noreturn {
    // The interrupt frame already has the correct values
    // We just need to restore registers and iretq
    // This is normally done by the interrupt_common handler
    // but this function allows for explicit returns

    // Cast to interrupt frame pointer
    const iframe = @as(*const InterruptFrameMinimal, @ptrCast(@alignCast(frame)));

    asm volatile (
        \\mov %[frame], %%rsp
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
        \\add $16, %%rsp
        \\iretq
        :
        : [frame] "r" (iframe),
    );

    unreachable;
}

/// Minimal interrupt frame structure for return
const InterruptFrameMinimal = extern struct {
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
    vector: u64,
    error_code: u64,
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

/// Allocate and map a user stack in the given address space
pub fn allocateUserStack(space: *vmm.AddressSpace) !u64 {
    return space.allocateRegion(
        USER_STACK_BOTTOM,
        USER_STACK_SIZE,
        .{
            .user = true,
            .writable = true,
            .executable = false,
        },
    );
}

/// Check if an address is in user space
pub fn isUserAddress(addr: u64) bool {
    return addr >= vmm.USER_BASE and addr < vmm.USER_TOP;
}

/// Validate a user buffer (check if entire range is accessible)
pub fn validateUserBuffer(space: *vmm.AddressSpace, ptr: u64, len: u64, needs_write: bool) bool {
    if (len == 0) return true;

    // Check bounds
    if (ptr < vmm.USER_BASE or ptr >= vmm.USER_TOP) return false;
    if (ptr + len < ptr) return false; // Overflow check
    if (ptr + len > vmm.USER_TOP) return false;

    // Check each page is mapped with correct permissions
    var addr = ptr & ~@as(u64, 0xFFF); // Page-align down
    const end = (ptr + len + 0xFFF) & ~@as(u64, 0xFFF); // Page-align up

    while (addr < end) : (addr += 0x1000) {
        // Check if page is mapped
        if (space.translate(addr) == null) {
            return false;
        }

        // For write access, check writable flag
        if (needs_write) {
            // In full implementation, would check page table flags
            // For now, we trust the mapping
        }
    }

    return true;
}

/// Copy data from user space to kernel buffer
pub fn copyFromUser(space: *vmm.AddressSpace, dest: []u8, user_src: u64) bool {
    if (!validateUserBuffer(space, user_src, dest.len, false)) {
        return false;
    }

    // For now, direct copy (assumes HHDM makes user space accessible)
    // In full implementation, would need proper page table walking
    const src_ptr: [*]const u8 = @ptrFromInt(user_src);
    for (dest, 0..) |*byte, i| {
        byte.* = src_ptr[i];
    }

    return true;
}

/// Copy data from kernel buffer to user space
pub fn copyToUser(space: *vmm.AddressSpace, user_dest: u64, src: []const u8) bool {
    if (!validateUserBuffer(space, user_dest, src.len, true)) {
        return false;
    }

    // Direct copy (assumes HHDM)
    const dest_ptr: [*]u8 = @ptrFromInt(user_dest);
    for (src, 0..) |byte, i| {
        dest_ptr[i] = byte;
    }

    return true;
}
