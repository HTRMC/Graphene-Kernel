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
const pmm = @import("pmm.zig");
const usermode = @import("usermode.zig");
const ipc = @import("ipc.zig");
const pic = @import("pic.zig");
const serial = @import("serial.zig");

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
    io_port_read = 18, // Read from I/O port
    io_port_write = 19, // Write to I/O port
    kbd_putchar = 20, // Keyboard driver sends character
    getchar = 21, // Read character from keyboard buffer (blocking)
    endpoint_create = 22, // Create IPC endpoint
    channel_create = 23, // Create IPC channel (bidirectional)
    process_count = 24, // Get count of active processes
    process_list = 25, // Get list of process info
    mem_info = 26, // Get memory statistics
    uptime = 27, // Get system uptime in ticks
    dma_alloc = 28, // Driver-only: allocate contiguous DMA buffer
    klog = 29, // Serial-only kernel log (no framebuffer)
    fb_info = 30, // Query framebuffer geometry
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

/// Process information entry (for process_list syscall)
pub const ProcessInfoEntry = extern struct {
    pid: u32,
    state: u8,
    thread_count: u8,
    _pad: [2]u8 = .{ 0, 0 },
    name: [32]u8,
};

/// Capability information returned by cap_info syscall. `addr` and `size`
/// hold type-specific data: physical base + size for memory/MMIO,
/// port base + count for I/O ports, IRQ number + 0 for IRQ caps.
pub const CapInfoResult = extern struct {
    object_type: u8,
    rights: u8,
    _pad: [6]u8 = .{ 0, 0, 0, 0, 0, 0 },
    addr: u64 = 0,
    size: u64 = 0,
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

/// Kernel RSP that the SYSCALL entry stub switches to. Updated by
/// gdt.setKernelStack on every context switch so that the running
/// thread's kernel stack is always installed.
pub export var syscall_kernel_rsp: u64 = 0;

/// Scratch slot used by the SYSCALL entry stub to stash the user RSP
/// while it switches to the kernel stack.
pub export var syscall_user_rsp: u64 = 0;

/// Update the kernel stack used by the SYSCALL entry path. Mirrors
/// gdt.setKernelStack so that both the IDT-based and fast-syscall
/// entry paths agree on the active kernel stack.
pub fn setKernelStack(stack: u64) void {
    syscall_kernel_rsp = stack;
}

/// Initialize syscall mechanism — installs the fast SYSCALL/SYSRET path
/// alongside the legacy int 0x80 entry, then enables SCE so user code
/// can issue the `syscall` instruction.
pub fn init() void {
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

    // Install the fast SYSCALL entry stub.
    wrmsr(IA32_LSTAR, @intFromPtr(&syscallEntryFast));

    // Set FMASK - flags to clear on syscall (clear IF — interrupts off inside entry)
    wrmsr(IA32_FMASK, 0x200);

    syscall_initialized = true;
}

/// SYSCALL entry point. The CPU has already:
///   - swapped CS/SS to kernel selectors (from STAR)
///   - put user RIP in RCX, user RFLAGS in R11
///   - left RSP pointing at the user stack
/// We switch to the running thread's kernel stack, build the same frame
/// shape that `int 0x80` produces, dispatch through `handle`, then
/// SYSRETQ back to user mode.
pub fn syscallEntryFast() callconv(.naked) noreturn {
    asm volatile (
        \\ // Stash user RSP, load kernel RSP.
        \\ mov %%rsp, syscall_user_rsp(%%rip)
        \\ mov syscall_kernel_rsp(%%rip), %%rsp
        \\
        \\ // Build an InterruptFrame-shaped record.
        \\ pushq $0x1b                     // SS = user data
        \\ pushq syscall_user_rsp(%%rip)   // user RSP
        \\ pushq %%r11                     // RFLAGS (CPU stashed user RFLAGS here)
        \\ pushq $0x23                     // CS = user code
        \\ pushq %%rcx                     // RIP (CPU stashed user RIP here)
        \\ pushq $0                        // error_code
        \\ pushq $0x80                     // vector — reuse the int 0x80 dispatch path
        \\
        \\ // Save all GPRs in the same order as interruptCommon.
        \\ pushq %%rax
        \\ pushq %%rbx
        \\ pushq %%rcx
        \\ pushq %%rdx
        \\ pushq %%rsi
        \\ pushq %%rdi
        \\ pushq %%rbp
        \\ pushq %%r8
        \\ pushq %%r9
        \\ pushq %%r10
        \\ pushq %%r11
        \\ pushq %%r12
        \\ pushq %%r13
        \\ pushq %%r14
        \\ pushq %%r15
        \\
        \\ movq %%rsp, %%rdi
    );
    asm volatile ("call %[handler:P]"
        :
        : [handler] "X" (&fastSyscallHandler),
    );
    asm volatile (
        \\ popq %%r15
        \\ popq %%r14
        \\ popq %%r13
        \\ popq %%r12
        \\ popq %%r11
        \\ popq %%r10
        \\ popq %%r9
        \\ popq %%r8
        \\ popq %%rbp
        \\ popq %%rdi
        \\ popq %%rsi
        \\ popq %%rdx
        \\ popq %%rcx
        \\ popq %%rbx
        \\ popq %%rax
        \\
        \\ addq $16, %%rsp        // pop error_code + vector
        \\ popq %%rcx              // RIP -> RCX (sysretq input)
        \\ addq $8, %%rsp          // skip CS
        \\ popq %%r11              // RFLAGS -> R11 (sysretq input)
        \\ popq %%rsp              // restore user RSP (SS slot left dangling above)
        \\ sysretq
    );
}

/// Bridge from the naked SYSCALL stub into the regular `handle` path.
/// Kept in Zig so the asm above stays minimal.
fn fastSyscallHandler(frame: *idt.InterruptFrame) callconv(.c) void {
    handle(frame);
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
        .io_port_read => sysIoPortRead(args),
        .io_port_write => sysIoPortWrite(args),
        .kbd_putchar => sysKbdPutchar(args),
        .getchar => sysGetchar(args),
        .endpoint_create => sysEndpointCreate(args),
        .channel_create => sysChannelCreate(args),
        .process_count => sysProcessCount(args),
        .process_list => sysProcessList(args),
        .mem_info => sysMemInfo(args),
        .uptime => sysUptime(args),
        .dma_alloc => sysDmaAlloc(args),
        .klog => sysKlog(args),
        .fb_info => sysFbInfo(args),
        _ => @intFromEnum(SyscallError.invalid_syscall),
    };
}

// ============================================================================
// Syscall Handlers (Phase 1: Stubs, to be implemented with scheduler/IPC)
// ============================================================================

fn sysCapSend(args: [6]u64) i64 {
    // cap_send(cap_slot, msg_ptr, msg_len)
    const cap_slot: capability.CapSlot = @truncate(args[0]);
    const msg_ptr = args[1];
    const msg_len = args[2];

    // Get current process
    const proc = process.getCurrentProcess() orelse {
        return @intFromEnum(SyscallError.invalid_capability);
    };

    const cap_table = proc.cap_table orelse {
        return @intFromEnum(SyscallError.invalid_capability);
    };

    // Validate user buffer
    if (msg_len > 0) {
        if (!usermode.isUserAddress(msg_ptr) or !usermode.isUserAddress(msg_ptr + msg_len - 1)) {
            return @intFromEnum(SyscallError.invalid_argument);
        }
    }

    if (msg_len > ipc.MAX_INLINE_DATA) {
        return @intFromEnum(SyscallError.invalid_argument);
    }

    // Look up endpoint capability with send rights
    const obj = capability.lookup(cap_table, cap_slot, .ipc_endpoint, capability.Rights.SEND) catch |err| {
        return switch (err) {
            capability.CapError.InvalidSlot => @intFromEnum(SyscallError.invalid_capability),
            capability.CapError.InvalidCapability => @intFromEnum(SyscallError.invalid_capability),
            capability.CapError.TypeMismatch => @intFromEnum(SyscallError.type_mismatch),
            capability.CapError.InsufficientRights => @intFromEnum(SyscallError.permission_denied),
            else => @intFromEnum(SyscallError.invalid_argument),
        };
    };

    // Get endpoint from object
    const endpoint: *ipc.Endpoint = @alignCast(@fieldParentPtr("base", obj));

    // Build message
    var msg = ipc.Message{};
    if (msg_len > 0) {
        const user_data: [*]const u8 = @ptrFromInt(msg_ptr);
        msg.setData(user_data[0..msg_len]);
    }

    // Send the message
    ipc.send(endpoint, &msg, cap_table) catch |err| {
        return switch (err) {
            ipc.IpcError.EndpointClosed => @intFromEnum(SyscallError.not_found),
            ipc.IpcError.QueueFull => @intFromEnum(SyscallError.would_block),
            ipc.IpcError.NotConnected => @intFromEnum(SyscallError.not_found),
            else => @intFromEnum(SyscallError.invalid_argument),
        };
    };

    return @intFromEnum(SyscallError.success);
}

fn sysCapRecv(args: [6]u64) i64 {
    // cap_recv(cap_slot, buf_ptr, buf_len)
    const cap_slot: capability.CapSlot = @truncate(args[0]);
    const buf_ptr = args[1];
    const buf_len = args[2];

    // Get current process
    const proc = process.getCurrentProcess() orelse {
        return @intFromEnum(SyscallError.invalid_capability);
    };

    const cap_table = proc.cap_table orelse {
        return @intFromEnum(SyscallError.invalid_capability);
    };

    // Validate user buffer
    if (buf_len > 0) {
        if (!usermode.isUserAddress(buf_ptr) or !usermode.isUserAddress(buf_ptr + buf_len - 1)) {
            return @intFromEnum(SyscallError.invalid_argument);
        }
    }

    // Look up endpoint capability with handle rights (for receiving)
    const obj = capability.lookup(cap_table, cap_slot, .ipc_endpoint, capability.Rights.HANDLE) catch |err| {
        return switch (err) {
            capability.CapError.InvalidSlot => @intFromEnum(SyscallError.invalid_capability),
            capability.CapError.InvalidCapability => @intFromEnum(SyscallError.invalid_capability),
            capability.CapError.TypeMismatch => @intFromEnum(SyscallError.type_mismatch),
            capability.CapError.InsufficientRights => @intFromEnum(SyscallError.permission_denied),
            else => @intFromEnum(SyscallError.invalid_argument),
        };
    };

    // Get endpoint from object
    const endpoint: *ipc.Endpoint = @alignCast(@fieldParentPtr("base", obj));

    // Receive message
    var msg = ipc.Message{};
    ipc.recv(endpoint, &msg, cap_table) catch |err| {
        return switch (err) {
            ipc.IpcError.EndpointClosed => @intFromEnum(SyscallError.not_found),
            ipc.IpcError.NotConnected => @intFromEnum(SyscallError.not_found),
            else => @intFromEnum(SyscallError.invalid_argument),
        };
    };

    // Copy message data to user buffer
    const data = msg.getData();
    const copy_len = @min(data.len, buf_len);
    if (copy_len > 0) {
        const user_buf: [*]u8 = @ptrFromInt(buf_ptr);
        for (0..copy_len) |i| {
            user_buf[i] = data[i];
        }
    }

    // Return length of received message
    return @intCast(data.len);
}

fn sysCapCall(args: [6]u64) i64 {
    // cap_call(cap_slot, msg_ptr, msg_len, reply_ptr, reply_len)
    const cap_slot: capability.CapSlot = @truncate(args[0]);
    const msg_ptr = args[1];
    const msg_len = args[2];
    const reply_ptr = args[3];
    const reply_len = args[4];

    // Get current process
    const proc = process.getCurrentProcess() orelse {
        return @intFromEnum(SyscallError.invalid_capability);
    };

    const cap_table = proc.cap_table orelse {
        return @intFromEnum(SyscallError.invalid_capability);
    };

    // Validate user buffers
    if (msg_len > 0) {
        if (!usermode.isUserAddress(msg_ptr) or !usermode.isUserAddress(msg_ptr + msg_len - 1)) {
            return @intFromEnum(SyscallError.invalid_argument);
        }
    }

    if (reply_len > 0) {
        if (!usermode.isUserAddress(reply_ptr) or !usermode.isUserAddress(reply_ptr + reply_len - 1)) {
            return @intFromEnum(SyscallError.invalid_argument);
        }
    }

    if (msg_len > ipc.MAX_INLINE_DATA) {
        return @intFromEnum(SyscallError.invalid_argument);
    }

    // Look up endpoint capability with send rights
    const obj = capability.lookup(cap_table, cap_slot, .ipc_endpoint, capability.Rights.SEND) catch |err| {
        return switch (err) {
            capability.CapError.InvalidSlot => @intFromEnum(SyscallError.invalid_capability),
            capability.CapError.InvalidCapability => @intFromEnum(SyscallError.invalid_capability),
            capability.CapError.TypeMismatch => @intFromEnum(SyscallError.type_mismatch),
            capability.CapError.InsufficientRights => @intFromEnum(SyscallError.permission_denied),
            else => @intFromEnum(SyscallError.invalid_argument),
        };
    };

    // Get endpoint from object
    const endpoint: *ipc.Endpoint = @alignCast(@fieldParentPtr("base", obj));

    // Build message
    var msg = ipc.Message{};
    if (msg_len > 0) {
        const user_data: [*]const u8 = @ptrFromInt(msg_ptr);
        msg.setData(user_data[0..msg_len]);
    }

    // Make the call (send + wait for reply)
    var reply_msg = ipc.Message{};
    ipc.call(endpoint, &msg, &reply_msg, cap_table) catch |err| {
        return switch (err) {
            ipc.IpcError.EndpointClosed => @intFromEnum(SyscallError.not_found),
            ipc.IpcError.QueueFull => @intFromEnum(SyscallError.would_block),
            ipc.IpcError.NotConnected => @intFromEnum(SyscallError.not_found),
            ipc.IpcError.Timeout => @intFromEnum(SyscallError.would_block),
            else => @intFromEnum(SyscallError.invalid_argument),
        };
    };

    // Copy reply to user buffer
    const reply_data = reply_msg.getData();
    const copy_len = @min(reply_data.len, reply_len);
    if (copy_len > 0) {
        const user_buf: [*]u8 = @ptrFromInt(reply_ptr);
        for (0..copy_len) |i| {
            user_buf[i] = reply_data[i];
        }
    }

    // Return length of reply
    return @intCast(reply_data.len);
}

fn sysCapCopy(args: [6]u64) i64 {
    // cap_copy(src_slot, dst_slot, rights_mask)
    const src_slot: capability.CapSlot = @truncate(args[0]);
    const dst_slot: capability.CapSlot = @truncate(args[1]);
    const rights_mask: capability.Rights = @bitCast(@as(u8, @truncate(args[2])));

    // Get current process
    const proc = process.getCurrentProcess() orelse {
        return @intFromEnum(SyscallError.invalid_capability);
    };

    const cap_table = proc.cap_table orelse {
        return @intFromEnum(SyscallError.invalid_capability);
    };

    // Copy capability with reduced rights
    capability.copy(cap_table, src_slot, dst_slot, rights_mask) catch |err| {
        return switch (err) {
            capability.CapError.InvalidSlot => @intFromEnum(SyscallError.invalid_capability),
            capability.CapError.InvalidCapability => @intFromEnum(SyscallError.invalid_capability),
            capability.CapError.SlotInUse => @intFromEnum(SyscallError.invalid_argument),
            else => @intFromEnum(SyscallError.invalid_argument),
        };
    };

    return @intFromEnum(SyscallError.success);
}

fn sysCapDelete(args: [6]u64) i64 {
    // cap_delete(slot)
    const slot: capability.CapSlot = @truncate(args[0]);

    // Get current process
    const proc = process.getCurrentProcess() orelse {
        return @intFromEnum(SyscallError.invalid_capability);
    };

    const cap_table = proc.cap_table orelse {
        return @intFromEnum(SyscallError.invalid_capability);
    };

    // Delete the capability
    capability.delete(cap_table, slot);

    return @intFromEnum(SyscallError.success);
}

fn sysCapRevoke(args: [6]u64) i64 {
    // cap_revoke(slot)
    const slot: capability.CapSlot = @truncate(args[0]);

    // Get current process
    const proc = process.getCurrentProcess() orelse {
        return @intFromEnum(SyscallError.invalid_capability);
    };

    const cap_table = proc.cap_table orelse {
        return @intFromEnum(SyscallError.invalid_capability);
    };

    // Revoke the capability (invalidates all derived capabilities)
    capability.revoke(cap_table, slot);

    return @intFromEnum(SyscallError.success);
}

/// Memory map flags (from user space)
const MemMapFlags = packed struct(u64) {
    read: bool = false,
    write: bool = false,
    execute: bool = false,
    _reserved: u61 = 0,
};

fn sysMemMap(args: [6]u64) i64 {
    // mem_map(cap_slot, vaddr, size, flags)
    const cap_slot: capability.CapSlot = @truncate(args[0]);
    const vaddr = args[1];
    const size = args[2];
    const flags: MemMapFlags = @bitCast(args[3]);

    // Get current process
    const proc = process.getCurrentProcess() orelse {
        return @intFromEnum(SyscallError.invalid_capability);
    };

    const cap_table = proc.cap_table orelse {
        return @intFromEnum(SyscallError.invalid_capability);
    };

    const address_space = proc.address_space orelse {
        return @intFromEnum(SyscallError.out_of_memory);
    };

    // Validate address is in user space
    if (!usermode.isUserAddress(vaddr) or !usermode.isUserAddress(vaddr + size - 1)) {
        return @intFromEnum(SyscallError.invalid_argument);
    }

    // W^X enforcement at syscall level
    if (flags.write and flags.execute) {
        return @intFromEnum(SyscallError.permission_denied);
    }

    // Build required rights based on flags
    var required_rights = capability.Rights{};
    if (flags.read) required_rights.read = true;
    if (flags.write) required_rights.write = true;
    if (flags.execute) required_rights.execute = true;

    // Look up memory capability and validate rights
    const obj = capability.lookup(cap_table, cap_slot, .memory, required_rights) catch |err| {
        return switch (err) {
            capability.CapError.InvalidSlot => @intFromEnum(SyscallError.invalid_capability),
            capability.CapError.InvalidCapability => @intFromEnum(SyscallError.invalid_capability),
            capability.CapError.TypeMismatch => @intFromEnum(SyscallError.type_mismatch),
            capability.CapError.InsufficientRights => @intFromEnum(SyscallError.permission_denied),
            else => @intFromEnum(SyscallError.invalid_argument),
        };
    };

    // Get the memory object
    const mem_obj = object.cast(object.MemoryObject, obj) orelse {
        return @intFromEnum(SyscallError.type_mismatch);
    };

    // Validate size doesn't exceed memory object bounds
    if (size > mem_obj.size) {
        return @intFromEnum(SyscallError.invalid_argument);
    }

    // Map the region
    const map_flags = vmm.VmFlags{
        .read = flags.read,
        .write = flags.write,
        .execute = flags.execute,
        .user = true,
    };

    vmm.mapRegion(address_space, vaddr, mem_obj.phys_start, size, map_flags) catch |err| {
        return switch (err) {
            vmm.VmmError.OutOfMemory => @intFromEnum(SyscallError.out_of_memory),
            vmm.VmmError.RegionOverlap => @intFromEnum(SyscallError.invalid_argument),
            vmm.VmmError.WxViolation => @intFromEnum(SyscallError.permission_denied),
            else => @intFromEnum(SyscallError.invalid_argument),
        };
    };

    // Increment map count on memory object
    mem_obj.map_count += 1;

    return @intFromEnum(SyscallError.success);
}

fn sysMemUnmap(args: [6]u64) i64 {
    // mem_unmap(vaddr, size)
    const vaddr = args[0];
    const size = args[1];

    // Get current process
    const proc = process.getCurrentProcess() orelse {
        return @intFromEnum(SyscallError.invalid_capability);
    };

    const address_space = proc.address_space orelse {
        return @intFromEnum(SyscallError.out_of_memory);
    };

    // Validate address is in user space
    if (!usermode.isUserAddress(vaddr) or (size > 0 and !usermode.isUserAddress(vaddr + size - 1))) {
        return @intFromEnum(SyscallError.invalid_argument);
    }

    // Find the region
    const region = address_space.findRegion(vaddr) orelse {
        return @intFromEnum(SyscallError.not_found);
    };

    // Only allow unmapping user regions
    if (!region.flags.user) {
        return @intFromEnum(SyscallError.permission_denied);
    }

    // Unmap the region (frees physical pages too)
    vmm.unmapRegion(address_space, region.start);

    return @intFromEnum(SyscallError.success);
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
    // Blocks until an IRQ fires. Returns 0 on success, negative on error.
    const cap_slot: capability.CapSlot = @truncate(args[0]);

    // Get current process
    const proc = process.getCurrentProcess() orelse {
        return @intFromEnum(SyscallError.invalid_capability);
    };

    const cap_table = proc.cap_table orelse {
        return @intFromEnum(SyscallError.invalid_capability);
    };

    // Look up IRQ capability with HANDLE rights
    const obj = capability.lookup(cap_table, cap_slot, .irq, capability.Rights.HANDLE) catch |err| {
        return switch (err) {
            capability.CapError.InvalidSlot => @intFromEnum(SyscallError.invalid_capability),
            capability.CapError.InvalidCapability => @intFromEnum(SyscallError.invalid_capability),
            capability.CapError.TypeMismatch => @intFromEnum(SyscallError.type_mismatch),
            capability.CapError.InsufficientRights => @intFromEnum(SyscallError.permission_denied),
            else => @intFromEnum(SyscallError.invalid_argument),
        };
    };

    // Get IRQ object from base object
    const irq_obj = object.cast(object.IrqObject, obj) orelse {
        return @intFromEnum(SyscallError.type_mismatch);
    };

    // Check if there's already a pending IRQ
    if (irq_obj.pending_count > 0) {
        irq_obj.pending_count -= 1;
        return @intFromEnum(SyscallError.success);
    }

    // No pending IRQ - block the current thread
    const current_thread = thread.getCurrentThreadUnsafe() orelse {
        return @intFromEnum(SyscallError.invalid_argument);
    };

    // Add to wait queue and block
    irq_obj.wait_queue.enqueue(current_thread);
    current_thread.state = .blocked;

    // Yield to scheduler - will resume when IRQ fires
    if (scheduler.isRunning()) {
        scheduler.yield();
    }

    // When we wake up, the IRQ has fired
    // Decrement pending count (was incremented by IRQ handler before waking us)
    if (irq_obj.pending_count > 0) {
        irq_obj.pending_count -= 1;
    }

    return @intFromEnum(SyscallError.success);
}

fn sysIrqAck(args: [6]u64) i64 {
    // irq_ack(cap_slot)
    // Acknowledges an IRQ and re-enables it in the PIC.
    const cap_slot: capability.CapSlot = @truncate(args[0]);

    // Get current process
    const proc = process.getCurrentProcess() orelse {
        return @intFromEnum(SyscallError.invalid_capability);
    };

    const cap_table = proc.cap_table orelse {
        return @intFromEnum(SyscallError.invalid_capability);
    };

    // Look up IRQ capability with HANDLE rights
    const obj = capability.lookup(cap_table, cap_slot, .irq, capability.Rights.HANDLE) catch |err| {
        return switch (err) {
            capability.CapError.InvalidSlot => @intFromEnum(SyscallError.invalid_capability),
            capability.CapError.InvalidCapability => @intFromEnum(SyscallError.invalid_capability),
            capability.CapError.TypeMismatch => @intFromEnum(SyscallError.type_mismatch),
            capability.CapError.InsufficientRights => @intFromEnum(SyscallError.permission_denied),
            else => @intFromEnum(SyscallError.invalid_argument),
        };
    };

    // Get IRQ object from base object
    const irq_obj = object.cast(object.IrqObject, obj) orelse {
        return @intFromEnum(SyscallError.type_mismatch);
    };

    // Unmask the IRQ to allow it to fire again
    pic.unmaskIrq(irq_obj.irq_num);

    return @intFromEnum(SyscallError.success);
}

/// klog: serial-only kernel log. Any process may call it. No framebuffer
/// side effects so it can never race with the tty service's screen.
fn sysKlog(args: [6]u64) i64 {
    const str_ptr = args[0];
    const str_len = args[1];

    if (str_len == 0) return @intFromEnum(SyscallError.success);
    if (str_len > 1024) return @intFromEnum(SyscallError.invalid_argument);

    if (!usermode.isUserAddress(str_ptr) or !usermode.isUserAddress(str_ptr + str_len - 1)) {
        return @intFromEnum(SyscallError.invalid_argument);
    }

    const str: [*]const u8 = @ptrFromInt(str_ptr);
    serial.puts(str[0..str_len]);
    return @intCast(str_len);
}

/// fb_info: return framebuffer geometry so the tty service knows how to
/// lay out glyphs in the MemoryObject it mapped.
fn sysFbInfo(args: [6]u64) i64 {
    const result_ptr = args[0];
    if (!usermode.isUserAddress(result_ptr)) {
        return @intFromEnum(SyscallError.invalid_argument);
    }

    if (framebuffer.getPhysAddr() == 0) {
        return @intFromEnum(SyscallError.not_found);
    }

    const out: *FbInfoResult = @ptrFromInt(result_ptr);
    out.* = .{
        .phys_base = framebuffer.getPhysAddr(),
        .size = framebuffer.getSize(),
        .width = framebuffer.getWidth(),
        .height = framebuffer.getHeight(),
        .pitch_bytes = framebuffer.getPitchBytes(),
        .bpp = framebuffer.getBpp(),
    };
    return @intFromEnum(SyscallError.success);
}

/// Debug print position (advances inline, only newline moves to next line)
/// Starts at Y=450 to avoid overlapping with kernel init messages (Y=150-430)
/// Wraps at Y=620 to avoid panic area (Y=640+)
var debug_x: u32 = 10;
var debug_y: u32 = 450;

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

    // Also print to serial console
    serial.puts(slice);

    // Print to framebuffer - continue from current position
    for (slice) |c| {
        if (c == '\n') {
            debug_x = 10;
            debug_y += 16;
        } else if (c == 8) {
            // Backspace - move cursor back and clear character
            if (debug_x > 10) {
                debug_x -= 8;
                // Clear the character by drawing a space (background color)
                framebuffer.putChar(' ', debug_x, debug_y, 0x001a1a2e);
            }
        } else if (c >= 32 and c < 127) {
            framebuffer.putChar(c, debug_x, debug_y, 0x0000ff00); // Green for user output
            debug_x += 8;
            if (debug_x > 780) {
                debug_x = 10;
                debug_y += 16;
            }
        }

        // Check for Y overflow after any line advance
        if (debug_y > 620) {
            clearUserOutputArea();
            debug_x = 10;
            debug_y = 450;
        }
    }

    return @intCast(str_len);
}

/// Clear the user output area (Y 450-620) to prepare for wrap-around
fn clearUserOutputArea() void {
    var py: u32 = 450;
    while (py < 630) : (py += 1) {
        var px: u32 = 0;
        while (px < 800) : (px += 1) {
            framebuffer.putPixel(px, py, 0x001a1a2e);
        }
    }
}

fn sysCapInfo(args: [6]u64) i64 {
    // cap_info(slot, result_ptr) -> fill CapInfoResult for the cap
    const slot: capability.CapSlot = @truncate(args[0]);
    const result_ptr = args[1];

    if (!usermode.isUserAddress(result_ptr)) {
        return @intFromEnum(SyscallError.invalid_argument);
    }

    const proc = process.getCurrentProcess() orelse {
        return @intFromEnum(SyscallError.invalid_capability);
    };
    const cap_table = proc.cap_table orelse {
        return @intFromEnum(SyscallError.invalid_capability);
    };

    if (slot >= capability.MAX_CAPS) {
        return @intFromEnum(SyscallError.invalid_capability);
    }
    if (!cap_table.isSlotUsed(slot)) {
        return @intFromEnum(SyscallError.invalid_capability);
    }

    const cap = &cap_table.slots[slot];
    if (!cap.isValid()) {
        return @intFromEnum(SyscallError.invalid_capability);
    }

    var info = CapInfoResult{
        .object_type = @intFromEnum(cap.object_type),
        .rights = @bitCast(cap.rights),
    };

    const obj = cap.obj.?;
    switch (cap.object_type) {
        .memory, .device_mmio => {
            if (object.cast(object.MemoryObject, obj)) |mem_obj| {
                info.addr = mem_obj.phys_start;
                info.size = mem_obj.size;
            } else if (object.cast(object.DeviceMmioObject, obj)) |mmio_obj| {
                info.addr = mmio_obj.phys_addr;
                info.size = mmio_obj.size;
            }
        },
        .ioport => {
            if (object.cast(object.IoPortObject, obj)) |io_obj| {
                info.addr = io_obj.port_start;
                info.size = io_obj.port_count;
            }
        },
        .irq => {
            if (object.cast(object.IrqObject, obj)) |irq_obj| {
                info.addr = irq_obj.irq_num;
                info.size = 0;
            }
        },
        else => {},
    }

    const out: *CapInfoResult = @ptrFromInt(result_ptr);
    out.* = info;
    return @intFromEnum(SyscallError.success);
}

fn sysProcessInfo(args: [6]u64) i64 {
    // process_info(pid, entry_ptr) -> fill ProcessInfoEntry for given PID
    const pid: u32 = @truncate(args[0]);
    const entry_ptr = args[1];

    // Validate user buffer
    if (!usermode.isUserAddress(entry_ptr)) {
        return @intFromEnum(SyscallError.invalid_argument);
    }

    // Find the process
    const proc = process.getByPid(pid) orelse {
        return @intFromEnum(SyscallError.not_found);
    };

    // Fill the entry
    const entry: *ProcessInfoEntry = @ptrFromInt(entry_ptr);
    entry.pid = proc.pid;
    entry.state = @intFromEnum(proc.state);
    entry.thread_count = @truncate(proc.thread_count);
    entry._pad = .{ 0, 0 };
    entry.name = proc.name;

    return @intFromEnum(SyscallError.success);
}

fn sysProcessCount(args: [6]u64) i64 {
    // process_count() -> returns count of active processes
    _ = args;
    return @intCast(process.countActive());
}

fn sysProcessList(args: [6]u64) i64 {
    // process_list(buf_ptr, max_count) -> fill array of ProcessInfoEntry
    const buf_ptr = args[0];
    const max_count = args[1];

    // Validate user buffer
    if (max_count > 0 and !usermode.isUserAddress(buf_ptr)) {
        return @intFromEnum(SyscallError.invalid_argument);
    }

    // Limit to reasonable size
    const actual_max = @min(max_count, 64);
    if (actual_max == 0) {
        return 0;
    }

    // Get process list
    var proc_buf: [64]*process.Process = undefined;
    const count = process.getActiveList(&proc_buf, actual_max);

    // Fill user buffer
    const entries: [*]ProcessInfoEntry = @ptrFromInt(buf_ptr);
    for (0..count) |i| {
        const proc = proc_buf[i];
        entries[i].pid = proc.pid;
        entries[i].state = @intFromEnum(proc.state);
        entries[i].thread_count = @truncate(proc.thread_count);
        entries[i]._pad = .{ 0, 0 };
        entries[i].name = proc.name;
    }

    return @intCast(count);
}

fn sysIoPortRead(args: [6]u64) i64 {
    // io_port_read(cap_slot, port, width)
    // Reads from an I/O port. Returns the value read or negative error.
    const cap_slot: capability.CapSlot = @truncate(args[0]);
    const port: u16 = @truncate(args[1]);
    const width: u8 = @truncate(args[2]); // 1, 2, or 4 bytes

    // Get current process
    const proc = process.getCurrentProcess() orelse {
        return @intFromEnum(SyscallError.invalid_capability);
    };

    const cap_table = proc.cap_table orelse {
        return @intFromEnum(SyscallError.invalid_capability);
    };

    // Look up I/O port capability with read rights
    const obj = capability.lookup(cap_table, cap_slot, .ioport, capability.Rights.RO) catch |err| {
        return switch (err) {
            capability.CapError.InvalidSlot => @intFromEnum(SyscallError.invalid_capability),
            capability.CapError.InvalidCapability => @intFromEnum(SyscallError.invalid_capability),
            capability.CapError.TypeMismatch => @intFromEnum(SyscallError.type_mismatch),
            capability.CapError.InsufficientRights => @intFromEnum(SyscallError.permission_denied),
            else => @intFromEnum(SyscallError.invalid_argument),
        };
    };

    // Get I/O port object from base object
    const ioport_obj = object.cast(object.IoPortObject, obj) orelse {
        return @intFromEnum(SyscallError.type_mismatch);
    };

    // Validate port is within capability's range
    if (port < ioport_obj.port_start or port >= ioport_obj.port_start + ioport_obj.port_count) {
        return @intFromEnum(SyscallError.permission_denied);
    }

    // Perform the I/O read based on width
    const value: u32 = switch (width) {
        1 => asm volatile ("inb %%dx, %%al"
            : [result] "={al}" (-> u8),
            : [port] "{dx}" (port),
        ),
        2 => asm volatile ("inw %%dx, %%ax"
            : [result] "={ax}" (-> u16),
            : [port] "{dx}" (port),
        ),
        4 => asm volatile ("inl %%dx, %%eax"
            : [result] "={eax}" (-> u32),
            : [port] "{dx}" (port),
        ),
        else => return @intFromEnum(SyscallError.invalid_argument),
    };

    return @intCast(value);
}

fn sysIoPortWrite(args: [6]u64) i64 {
    // io_port_write(cap_slot, port, value, width)
    // Writes to an I/O port. Returns 0 on success or negative error.
    const cap_slot: capability.CapSlot = @truncate(args[0]);
    const port: u16 = @truncate(args[1]);
    const value: u32 = @truncate(args[2]);
    const width: u8 = @truncate(args[3]); // 1, 2, or 4 bytes

    // Get current process
    const proc = process.getCurrentProcess() orelse {
        return @intFromEnum(SyscallError.invalid_capability);
    };

    const cap_table = proc.cap_table orelse {
        return @intFromEnum(SyscallError.invalid_capability);
    };

    // Look up I/O port capability with write rights
    const obj = capability.lookup(cap_table, cap_slot, .ioport, .{ .write = true }) catch |err| {
        return switch (err) {
            capability.CapError.InvalidSlot => @intFromEnum(SyscallError.invalid_capability),
            capability.CapError.InvalidCapability => @intFromEnum(SyscallError.invalid_capability),
            capability.CapError.TypeMismatch => @intFromEnum(SyscallError.type_mismatch),
            capability.CapError.InsufficientRights => @intFromEnum(SyscallError.permission_denied),
            else => @intFromEnum(SyscallError.invalid_argument),
        };
    };

    // Get I/O port object from base object
    const ioport_obj = object.cast(object.IoPortObject, obj) orelse {
        return @intFromEnum(SyscallError.type_mismatch);
    };

    // Validate port is within capability's range
    if (port < ioport_obj.port_start or port >= ioport_obj.port_start + ioport_obj.port_count) {
        return @intFromEnum(SyscallError.permission_denied);
    }

    // Perform the I/O write based on width
    switch (width) {
        1 => asm volatile ("outb %%al, %%dx"
            :
            : [value] "{al}" (@as(u8, @truncate(value))),
              [port] "{dx}" (port),
        ),
        2 => asm volatile ("outw %%ax, %%dx"
            :
            : [value] "{ax}" (@as(u16, @truncate(value))),
              [port] "{dx}" (port),
        ),
        4 => asm volatile ("outl %%eax, %%dx"
            :
            : [value] "{eax}" (value),
              [port] "{dx}" (port),
        ),
        else => return @intFromEnum(SyscallError.invalid_argument),
    }

    return @intFromEnum(SyscallError.success);
}

// ============================================================================
// Keyboard Input Buffer (for shell input)
// ============================================================================

const KBD_BUFFER_SIZE: usize = 256;
var kbd_buffer: [KBD_BUFFER_SIZE]u8 = undefined;
var kbd_read_pos: usize = 0;
var kbd_write_pos: usize = 0;
var kbd_count: usize = 0;
var kbd_wait_queue: thread.WaitQueue = .{};

fn sysKbdPutchar(args: [6]u64) i64 {
    // kbd_putchar(char) - keyboard driver sends a character to the buffer
    const c: u8 = @truncate(args[0]);

    // Only allow driver processes to call this
    const proc = process.getCurrentProcess() orelse {
        return @intFromEnum(SyscallError.permission_denied);
    };
    if (!proc.flags.driver_process) {
        return @intFromEnum(SyscallError.permission_denied);
    }

    // Check if buffer is full
    if (kbd_count >= KBD_BUFFER_SIZE) {
        return @intFromEnum(SyscallError.would_block);
    }

    // Add character to buffer
    kbd_buffer[kbd_write_pos] = c;
    kbd_write_pos = (kbd_write_pos + 1) % KBD_BUFFER_SIZE;
    kbd_count += 1;

    // Wake up any waiting reader
    if (kbd_wait_queue.dequeue()) |waiting_thread| {
        scheduler.wake(waiting_thread);
    }

    return @intFromEnum(SyscallError.success);
}

fn sysGetchar(args: [6]u64) i64 {
    // getchar() - read a character from keyboard buffer, blocks if empty
    _ = args;

    // If buffer is empty, block until a character is available
    while (kbd_count == 0) {
        scheduler.blockCurrent(&kbd_wait_queue);
    }

    // Read character from buffer
    const c = kbd_buffer[kbd_read_pos];
    kbd_read_pos = (kbd_read_pos + 1) % KBD_BUFFER_SIZE;
    kbd_count -= 1;

    return @as(i64, c);
}

// ============================================================================
// IPC Endpoint/Channel Creation
// ============================================================================

fn sysEndpointCreate(args: [6]u64) i64 {
    // endpoint_create() - create a new IPC endpoint, returns capability slot
    _ = args;

    const proc = process.getCurrentProcess() orelse {
        return @intFromEnum(SyscallError.permission_denied);
    };

    const cap_table = proc.cap_table orelse {
        return @intFromEnum(SyscallError.invalid_capability);
    };

    // Create endpoint
    const endpoint = ipc.createEndpoint() orelse {
        return @intFromEnum(SyscallError.out_of_memory);
    };

    // Find free slot
    const slot = cap_table.findFreeSlot() orelse {
        return @intFromEnum(SyscallError.table_full);
    };

    // Insert capability with full rights (send + handle)
    capability.insertAt(cap_table, slot, &endpoint.base, capability.Rights.ALL) catch {
        return @intFromEnum(SyscallError.table_full);
    };

    return @as(i64, slot);
}

fn sysChannelCreate(args: [6]u64) i64 {
    // channel_create(slot1_ptr, slot2_ptr) - create bidirectional channel
    // Returns two endpoint capability slots via pointers
    const slot1_ptr = args[0];
    const slot2_ptr = args[1];

    const proc = process.getCurrentProcess() orelse {
        return @intFromEnum(SyscallError.permission_denied);
    };

    const cap_table = proc.cap_table orelse {
        return @intFromEnum(SyscallError.invalid_capability);
    };

    // Validate user pointers
    if (!usermode.isUserAddress(slot1_ptr) or !usermode.isUserAddress(slot2_ptr)) {
        return @intFromEnum(SyscallError.invalid_argument);
    }

    // Create channel (two connected endpoints)
    const channel = ipc.createChannel() orelse {
        return @intFromEnum(SyscallError.out_of_memory);
    };

    // Find two free slots
    const slot1 = cap_table.findFreeSlot() orelse {
        return @intFromEnum(SyscallError.table_full);
    };

    const slot2 = cap_table.findFreeSlot() orelse {
        return @intFromEnum(SyscallError.table_full);
    };

    // Insert capabilities for both endpoints
    capability.insertAt(cap_table, slot1, &channel.endpoints[0].base, capability.Rights.ALL) catch {
        return @intFromEnum(SyscallError.table_full);
    };

    capability.insertAt(cap_table, slot2, &channel.endpoints[1].base, capability.Rights.ALL) catch {
        capability.delete(cap_table, slot1);
        return @intFromEnum(SyscallError.table_full);
    };

    // Write slots to user space
    const user_slot1: *u32 = @ptrFromInt(slot1_ptr);
    const user_slot2: *u32 = @ptrFromInt(slot2_ptr);
    user_slot1.* = slot1;
    user_slot2.* = slot2;

    return @intFromEnum(SyscallError.success);
}

/// Memory info structure returned by mem_info syscall
pub const MemInfoResult = extern struct {
    total_bytes: u64,
    free_bytes: u64,
    used_bytes: u64,
};

/// Framebuffer geometry returned by fb_info syscall. `phys_base` is the
/// raw physical base address of the linear framebuffer — needed only
/// by the tty service, which holds the framebuffer MemoryObject cap and
/// maps it with mem_map.
pub const FbInfoResult = extern struct {
    phys_base: u64,
    size: u64,
    width: u32,
    height: u32,
    pitch_bytes: u32,
    bpp: u32,
};

fn sysMemInfo(args: [6]u64) i64 {
    // mem_info(result_ptr) - get memory statistics
    // Returns memory info via pointer
    const result_ptr = args[0];

    // Validate user pointer
    if (!usermode.isUserAddress(result_ptr)) {
        return @intFromEnum(SyscallError.invalid_argument);
    }

    // Get memory stats from PMM
    const total = pmm.getTotalMemory();
    const free = pmm.getFreeMemory();
    const used = total - free;

    // Write to user space
    const user_result: *MemInfoResult = @ptrFromInt(result_ptr);
    user_result.total_bytes = total;
    user_result.free_bytes = free;
    user_result.used_bytes = used;

    return @intFromEnum(SyscallError.success);
}

fn sysUptime(args: [6]u64) i64 {
    // uptime() - get system uptime in scheduler ticks
    // Returns tick count directly
    _ = args;

    const ticks = scheduler.getTicks();
    return @as(i64, @intCast(ticks));
}

/// dma_alloc(vaddr, size) -> phys_addr on success, negative on error.
///
/// Allocates `size` (rounded up to page granularity) of physically-
/// contiguous frames, zeros them, and maps them into the calling
/// process at `vaddr` as user-RW. The physical base address is
/// returned in rax so the driver can program it into the device.
/// Restricted to processes flagged as `driver_process`.
fn sysDmaAlloc(args: [6]u64) i64 {
    const vaddr = args[0];
    const size = args[1];

    if (size == 0) return @intFromEnum(SyscallError.invalid_argument);

    const proc = process.getCurrentProcess() orelse {
        return @intFromEnum(SyscallError.permission_denied);
    };
    if (!proc.flags.driver_process) {
        return @intFromEnum(SyscallError.permission_denied);
    }

    const space = proc.address_space orelse {
        return @intFromEnum(SyscallError.out_of_memory);
    };

    // Align and validate target vaddr.
    const aligned_vaddr = vaddr & ~@as(u64, pmm.PAGE_SIZE - 1);
    const aligned_size = ((size + pmm.PAGE_SIZE - 1) / pmm.PAGE_SIZE) * pmm.PAGE_SIZE;
    if (!usermode.isUserAddress(aligned_vaddr) or
        !usermode.isUserAddress(aligned_vaddr + aligned_size - 1))
    {
        return @intFromEnum(SyscallError.invalid_argument);
    }

    const num_pages = aligned_size / pmm.PAGE_SIZE;
    const phys_base = pmm.allocFrames(num_pages) orelse {
        return @intFromEnum(SyscallError.out_of_memory);
    };

    // Zero the backing memory via HHDM before exposing to the device.
    var p: usize = 0;
    while (p < num_pages) : (p += 1) {
        const v: [*]u8 = @ptrFromInt(pmm.physToVirt(phys_base + p * pmm.PAGE_SIZE));
        for (0..pmm.PAGE_SIZE) |i| v[i] = 0;
    }

    vmm.mapRegion(space, aligned_vaddr, phys_base, aligned_size, vmm.VmFlags.USER_RW) catch {
        pmm.freeFrames(phys_base, num_pages);
        return @intFromEnum(SyscallError.out_of_memory);
    };

    return @as(i64, @intCast(phys_base));
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
        .io_port_read => "io_port_read",
        .io_port_write => "io_port_write",
        .kbd_putchar => "kbd_putchar",
        .getchar => "getchar",
        .endpoint_create => "endpoint_create",
        .channel_create => "channel_create",
        .process_count => "process_count",
        .process_list => "process_list",
        .mem_info => "mem_info",
        .uptime => "uptime",
        .dma_alloc => "dma_alloc",
        .klog => "klog",
        .fb_info => "fb_info",
        _ => "unknown",
    };
}
