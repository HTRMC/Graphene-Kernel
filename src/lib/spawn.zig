// Graphene Kernel - Process Spawn Helper
//
// Shared ELF -> runnable-process core used by both the boot wiring in
// src/main.zig and (later) the process_spawn syscall. This module is
// deliberately policy-free: it validates an ELF image, creates a process
// and its main thread, and enqueues it on the scheduler. It performs
// NO capability grants — the caller decides what caps the new process
// gets. That separation is what lets init become the capability issuer
// instead of the kernel.

const elf = @import("elf.zig");
const process = @import("process.zig");
const thread = @import("thread.zig");
const usermode = @import("usermode.zig");
const scheduler = @import("scheduler.zig");

/// Options for spawning a process from an ELF image.
pub const SpawnOptions = struct {
    /// Human-readable name copied into the PCB (truncated to 31 chars).
    name: []const u8,

    /// Mark the process as a driver (sets the driver_process flag, which
    /// gates dma_alloc and other driver-only syscalls). Mirrors the
    /// behavior of loadDriverProcess / loadPciDriverProcess in main.zig.
    driver: bool = false,

    /// Mark the process as the capability minter. Only the boot-loaded
    /// init process should pass true here — minting authority is meant
    /// to be non-delegable, and there is no syscall to set this bit.
    minter: bool = false,
};

/// Load an ELF image into a fresh process and enqueue it on the
/// scheduler. Returns the process pointer on success, null on any
/// failure (bad ELF, OOM, etc.). The caller owns any capability
/// wiring — this function grants nothing.
///
/// This is the exact core of main.zig's loadUserProcessP /
/// loadDriverProcess / loadPciDriverProcess, with the per-caller
/// cap-wiring stripped out.
pub fn fromElf(elf_bytes: []const u8, opts: SpawnOptions) ?*process.Process {
    if (elf_bytes.len == 0) return null;
    if (!elf.isElf(elf_bytes)) return null;

    const proc = process.create(null) orelse return null;
    proc.setName(opts.name);

    if (opts.driver) proc.flags.driver_process = true;
    if (opts.minter) proc.flags.minter_process = true;

    const space = proc.address_space orelse {
        process.destroy(proc);
        return null;
    };

    const load_result = elf.load(space, elf_bytes) catch {
        process.destroy(proc);
        return null;
    };

    _ = usermode.allocateUserStack(space) catch {
        process.destroy(proc);
        return null;
    };

    // Initial RSP leaves 8 bytes of slack below USER_STACK_TOP, matching
    // every existing loader (SysV ABI expects a pushed return address on
    // the stack at entry; the slack stands in for one).
    const main_thread = thread.createUser(
        proc,
        load_result.entry_point,
        usermode.USER_STACK_TOP - 8,
    ) orelse {
        process.destroy(proc);
        return null;
    };

    _ = proc.addThread(main_thread);
    scheduler.enqueue(main_thread);

    return proc;
}
