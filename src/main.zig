// Graphene Kernel - Main Entry Point
// Hybrid Microkernel with Capability-Based Security

const builtin = @import("builtin");

fn refAllRecursive(comptime T: type) void {
    switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => {},
        else => return,
    }
    inline for (comptime std.meta.declarations(T)) |decl| {
        if (@TypeOf(@field(T, decl.name)) == type) {
            refAllRecursive(@field(T, decl.name));
        }
        _ = &@field(T, decl.name);
    }
}

comptime {
    refAllRecursive(@This());
}

const std = @import("std");
const limine = @import("lib/limine.zig");
const framebuffer = @import("lib/framebuffer.zig");
const gdt = @import("lib/gdt.zig");
const idt = @import("lib/idt.zig");
const pic = @import("lib/pic.zig");
const pmm = @import("lib/pmm.zig");
const vmm = @import("lib/vmm.zig");
const heap = @import("lib/heap.zig");
const process = @import("lib/process.zig");
const scheduler = @import("lib/scheduler.zig");
const syscall = @import("lib/syscall.zig");
const thread = @import("lib/thread.zig");
const elf = @import("lib/elf.zig");
const usermode = @import("lib/usermode.zig");
const driver = @import("lib/driver.zig");
const serial = @import("lib/serial.zig");
const apic = @import("lib/apic.zig");
const ipc = @import("lib/ipc.zig");
const capability = @import("lib/capability.zig");
const object = @import("lib/object.zig");
const pci = @import("lib/pci.zig");

/// Debug logging - only enabled in Debug builds
const debug_enabled = builtin.mode == .Debug;

fn debugPrint(comptime msg: []const u8) void {
    if (debug_enabled) {
        serial.println(msg);
    }
}

fn debugPuts(str: []const u8) void {
    if (debug_enabled) {
        serial.puts(str);
    }
}

fn debugHex(value: u64) void {
    if (debug_enabled) {
        serial.putHex(value);
    }
}

fn debugDec(value: u64) void {
    if (debug_enabled) {
        serial.putDec(value);
    }
}

// Limine request markers - placed in special section
export var requests_start linksection(".limine_requests_start") = limine.RequestsStartMarker{};
export var requests_end linksection(".limine_requests_end") = limine.RequestsEndMarker{};

// Limine requests - these are read by the bootloader
pub export var base_revision linksection(".limine_requests") = limine.BaseRevision{ .revision = 3 };
pub export var framebuffer_request linksection(".limine_requests") = limine.FramebufferRequest{};
pub export var memmap_request linksection(".limine_requests") = limine.MemoryMapRequest{};
pub export var hhdm_request linksection(".limine_requests") = limine.HhdmRequest{};
pub export var module_request linksection(".limine_requests") = limine.ModuleRequest{};

// Boot diagnostics go to serial only — the framebuffer belongs to the
// user-space tty service once it starts. No kernel code draws glyphs
// outside of the panic handler.
fn printStatus(msg: []const u8, color: u32) void {
    _ = color;
    serial.println(msg);
}

fn printOk(msg: []const u8) void {
    serial.puts("[OK] ");
    serial.println(msg);
}

fn printFail(msg: []const u8) void {
    serial.puts("[!!] ");
    serial.println(msg);
}

fn printInfo(msg: []const u8) void {
    serial.puts("     ");
    serial.println(msg);
}

// Kernel entry point
export fn _start() callconv(.c) noreturn {
    // Initialize serial console first for early debug output
    serial.init();
    serial.println("");
    serial.println("=====================================");
    serial.println("  Graphene Kernel v0.1.0");
    serial.println("  Serial Console Initialized");
    serial.println("=====================================");
    serial.println("");

    // Verify Limine protocol version
    if (!base_revision.is_supported()) {
        serial.println("[FATAL] Limine protocol version not supported!");
        halt();
    }

    // ========================================
    // Phase 1: CPU Structures
    // ========================================
    serial.println("[BOOT] Phase 1: CPU Structures");
    gdt.init();
    pic.init();
    pic.maskAll();
    idt.init();
    serial.println("[OK] GDT, PIC, IDT initialized");

    // ========================================
    // Phase 2: Framebuffer Setup
    // ========================================
    // Capture framebuffer geometry so user-space (tty service) can
    // query it via fb_info and map the bytes via mem_map. The kernel
    // does NOT draw any text — that's tty's job once it starts.
    if (framebuffer_request.response) |fb_response| {
        const fbs = fb_response.framebuffers();
        if (fbs.len > 0) {
            framebuffer.init(fbs[0]);
            framebuffer.clear(0x001a1a2e);
        }
    }

    // ========================================
    // Phase 3: Memory Management
    // ========================================

    // Initialize PMM
    if (memmap_request.response) |mmap_response| {
        if (hhdm_request.response) |hhdm_response| {
            pmm.init(mmap_response, hhdm_response);
            printOk("Physical Memory Manager");

            // Display memory stats
            const total_mb = pmm.getTotalMemory() / (1024 * 1024);
            const free_mb = pmm.getFreeMemory() / (1024 * 1024);
            _ = total_mb;
            _ = free_mb;
            // Note: Would need number-to-string conversion for display
            printInfo("Memory initialized");
        } else {
            printFail("HHDM not available");
        }
    } else {
        printFail("Memory map not available");
    }

    // Initialize VMM
    vmm.init();
    printOk("Virtual Memory Manager");

    // Enumerate PCI bus 0 — needed to locate virtio-blk and other devices
    // before any driver process is loaded.
    pci.init();
    if (pci.findVirtioBlk() != null) {
        printOk("PCI bus enumerated (virtio-blk present)");
    } else {
        printOk("PCI bus enumerated");
    }

    // Try to initialize APIC (modern interrupt controller)
    // Must be after PMM init since APIC uses physToVirt for MMIO mapping
    if (apic.init()) {
        // Don't start timer yet - will be started after scheduler is ready
        printOk("APIC initialized (modern interrupts)");
    } else {
        // Fall back to legacy PIC
        printInfo("Using legacy PIC (APIC not available)");
    }

    // Initialize Heap
    heap.init();
    printOk("Kernel Heap Allocator");

    // ========================================
    // Phase 4: Process & Scheduler
    // ========================================

    // Initialize process subsystem
    process.init();
    printOk("Process Subsystem");

    // Initialize syscall
    syscall.init();
    printOk("Syscall Interface");

    // Initialize scheduler
    scheduler.init();
    printOk("Scheduler");

    // Initialize driver framework
    driver.init();
    printOk("Driver Framework");

    // ========================================
    // Phase 5: User Space Initialization
    // ========================================
    printStatus("All Phase 1 subsystems initialized!", 0x0000ff00);

    // Load boot modules
    var init_loaded = false;
    var ramfs_proc: ?*process.Process = null;
    var shell_proc: ?*process.Process = null;
    var logger_proc: ?*process.Process = null;
    var devfs_proc: ?*process.Process = null;
    var virtioblk_proc: ?*process.Process = null;
    var fatfs_proc: ?*process.Process = null;
    var tty_proc: ?*process.Process = null;
    var kbd_proc: ?*process.Process = null;
    var serial_proc: ?*process.Process = null;
    if (module_request.response) |mod_response| {
        const modules = mod_response.getModules();
        printInfo("Loading boot modules..."); // TODO: make sure this text doesnt overlap. the text Running in user mode!

        for (modules) |module| {
            const module_name = parseModuleCmdline(module.string);

            if (strEql(module_name, "init")) {
                // Load init process
                if (loadInitProcess(module)) {
                    init_loaded = true;
                    printOk("Loaded: init");
                }
            } else if (strEql(module_name, "kbd")) {
                // Load kbd as driver with IRQ 1 and I/O ports 0x60-0x64
                kbd_proc = loadDriverProcess(module, "kbd", driver.DriverType.keyboard, 1, 0x60, 5);
                if (kbd_proc != null) {
                    printOk("Loaded: kbd (IRQ 1, ports 0x60-0x64)");
                }
            } else if (strEql(module_name, "shell")) {
                // Load shell as a user process
                shell_proc = loadUserProcessP(module, "shell");
                if (shell_proc != null) printOk("Loaded: shell");
            } else if (strEql(module_name, "ramfs")) {
                // Load ramfs as a filesystem service
                ramfs_proc = loadUserProcessP(module, "ramfs");
                if (ramfs_proc != null) printOk("Loaded: ramfs (filesystem service)");
            } else if (strEql(module_name, "logger")) {
                // Load logger as a text-logging service
                logger_proc = loadUserProcessP(module, "logger");
                if (logger_proc != null) printOk("Loaded: logger (text-logging service)");
            } else if (strEql(module_name, "devfs")) {
                // Load devfs as a device filesystem service
                devfs_proc = loadUserProcessP(module, "devfs");
                if (devfs_proc != null) printOk("Loaded: devfs (device filesystem)");
            } else if (strEql(module_name, "virtioblk")) {
                // Load virtio-blk as a PCI driver bound to the device discovered
                // by pci.findVirtioBlk(). Skip silently if no device present.
                if (pci.findVirtioBlk()) |pci_dev| {
                    virtioblk_proc = loadPciDriverProcess(
                        module,
                        "virtioblk",
                        driver.DriverType.storage,
                        pci_dev,
                    );
                    if (virtioblk_proc != null) printOk("Loaded: virtioblk (PCI block driver)");
                } else {
                    printInfo("Skipping virtioblk (no virtio-blk PCI device)");
                }
            } else if (strEql(module_name, "fatfs")) {
                // Load fatfs as a filesystem service that reads /dev/vda.
                fatfs_proc = loadUserProcessP(module, "fatfs");
                if (fatfs_proc != null) printOk("Loaded: fatfs (FAT32 filesystem)");
            } else if (strEql(module_name, "tty")) {
                // Load tty as the user-space terminal service. It needs
                // the framebuffer cap (granted below) and HANDLE on the
                // TTY endpoint.
                tty_proc = loadUserProcessP(module, "tty");
                if (tty_proc != null) printOk("Loaded: tty (terminal service)");
            } else if (strEql(module_name, "serial")) {
                // Load serial as a driver process with IRQ 4 + I/O ports
                // 0x3F8..0x3FF. Owns COM1; bridges UART RX into tty's
                // input queue and accepts tty's output mirror via VFS.
                serial_proc = loadDriverProcess(module, "serial", driver.DriverType.serial, 4, 0x3F8, 8);
                if (serial_proc != null) {
                    printOk("Loaded: serial (IRQ 4, ports 0x3F8-0x3FF)");
                }
            } else {
                // Unknown module - try to load as generic driver
                printInfo("Skipping unknown module");
            }
        }
    }

    // Wire VFS endpoint: ramfs gets HANDLE, shell gets SEND, at VFS_CAP_SLOT.
    if (ramfs_proc != null and shell_proc != null) {
        if (wireVfsEndpoint(ramfs_proc.?, shell_proc.?)) {
            printOk("VFS endpoint wired (slot 1)");
        } else {
            printFail("VFS endpoint wire failed");
        }
    }

    // Wire LOG endpoint: logger gets HANDLE, shell gets SEND, at LOG_CAP_SLOT.
    if (logger_proc != null and shell_proc != null) {
        if (wireServiceEndpoint(logger_proc.?, shell_proc.?, LOG_CAP_SLOT) != null) {
            printOk("LOG endpoint wired (slot 2)");
        } else {
            printFail("LOG endpoint wire failed");
        }
    }

    // Wire DEVFS endpoint: devfs gets HANDLE, shell gets SEND, at DEVFS_CAP_SLOT.
    if (devfs_proc != null and shell_proc != null) {
        if (wireServiceEndpoint(devfs_proc.?, shell_proc.?, DEVFS_CAP_SLOT) != null) {
            printOk("DEVFS endpoint wired (slot 3)");
        } else {
            printFail("DEVFS endpoint wire failed");
        }
    }

    // Wire BLK endpoint: virtioblk gets HANDLE, devfs gets SEND, at BLK_CAP_SLOT.
    // Save the endpoint so we can also grant fatfs a SEND cap on it.
    var blk_endpoint: ?*ipc.Endpoint = null;
    if (virtioblk_proc != null and devfs_proc != null) {
        blk_endpoint = wireServiceEndpoint(virtioblk_proc.?, devfs_proc.?, BLK_CAP_SLOT);
        if (blk_endpoint != null) {
            printOk("BLK endpoint wired (slot 4)");
        } else {
            printFail("BLK endpoint wire failed");
        }
    }

    // Wire FATFS endpoint: fatfs gets HANDLE, shell gets SEND, at FATFS_CAP_SLOT.
    if (fatfs_proc != null and shell_proc != null) {
        if (wireServiceEndpoint(fatfs_proc.?, shell_proc.?, FATFS_CAP_SLOT) != null) {
            printOk("FATFS endpoint wired (slot 5)");
        } else {
            printFail("FATFS endpoint wire failed");
        }
    }

    // Grant fatfs a SEND cap on the existing BLK endpoint so it can
    // read sectors from /dev/vda.
    if (fatfs_proc != null and blk_endpoint != null) {
        if (grantSendCap(fatfs_proc.?, blk_endpoint.?, BLK_CAP_SLOT)) {
            printOk("BLK send cap granted to fatfs");
        } else {
            printFail("BLK send cap grant failed");
        }
    }

    // Wire TTY endpoint: tty gets HANDLE, shell gets SEND, at TTY_CAP_SLOT.
    // Also grant SEND on the same endpoint to kbd (so it can push input)
    // and devfs (so /dev/tty0 reads/writes can be forwarded).
    var tty_endpoint: ?*ipc.Endpoint = null;
    if (tty_proc != null and shell_proc != null) {
        tty_endpoint = wireServiceEndpoint(tty_proc.?, shell_proc.?, TTY_CAP_SLOT);
        if (tty_endpoint != null) {
            printOk("TTY endpoint wired (slot 6)");
        } else {
            printFail("TTY endpoint wire failed");
        }
    }
    // devfs still uses TTY_CAP_SLOT for /dev/tty0 forwarding (it does
    // not race because devfs only sends in response to shell requests,
    // never asynchronously into shell's parked recv).
    if (tty_endpoint != null and devfs_proc != null) {
        if (grantSendCap(devfs_proc.?, tty_endpoint.?, TTY_CAP_SLOT)) {
            printOk("TTY send cap granted to devfs");
        } else {
            printFail("TTY send cap grant to devfs failed");
        }
    }

    // TTY_INPUT endpoint (async): tty HANDLE, kbd+serial SEND. This is
    // the fire-and-forget channel for `.tty_input` so async pushes from
    // kbd/serial cannot direct-hand-off into shell's parked recv on
    // TTY_CAP_SLOT (a race that mis-parsed a request as a reply).
    if (tty_proc != null and kbd_proc != null) {
        const input_ep = ipc.createEndpoint();
        if (input_ep) |ep| {
            ep.flags.async_mode = true;
            const tty_tbl = tty_proc.?.cap_table.?;
            const kbd_tbl = kbd_proc.?.cap_table.?;
            capability.insertAt(tty_tbl, TTY_INPUT_SLOT, &ep.base, capability.Rights{ .handle = true }) catch {};
            capability.insertAt(kbd_tbl, TTY_INPUT_SLOT, &ep.base, capability.Rights{ .send = true }) catch {};
            if (tty_tbl.isSlotUsed(TTY_INPUT_SLOT) and kbd_tbl.isSlotUsed(TTY_INPUT_SLOT)) {
                printOk("TTY_INPUT endpoint wired (slot 8, async)");
                // Also grant serial a SEND cap on the same endpoint.
                if (serial_proc) |sp| {
                    if (grantSendCap(sp, ep, TTY_INPUT_SLOT)) {
                        printOk("TTY_INPUT send cap granted to serial");
                    } else {
                        printFail("TTY_INPUT send cap grant to serial failed");
                    }
                }
            } else {
                printFail("TTY_INPUT endpoint wire failed");
            }
        }
    }

    // Wire SERIAL endpoint: serial gets HANDLE, tty gets SEND, at
    // SERIAL_CAP_SLOT. Async-mode so tty's write fan-out never blocks
    // — bytes pile in the pending ring until serial's poll loop drains.
    if (serial_proc != null and tty_proc != null) {
        const serial_endpoint = wireServiceEndpoint(serial_proc.?, tty_proc.?, SERIAL_CAP_SLOT);
        if (serial_endpoint) |ep| {
            ep.flags.async_mode = true;
            printOk("SERIAL endpoint wired (slot 9, async)");
        } else {
            printFail("SERIAL endpoint wire failed");
        }
    }

    // Hand the framebuffer to the tty service as a MemoryObject cap.
    // tty maps it via mem_map and renders glyphs into it directly.
    if (tty_proc != null and framebuffer.getPhysAddr() != 0) {
        const fb_obj = object.createMmioMemoryObject(framebuffer.getPhysAddr(), framebuffer.getSize());
        if (fb_obj != null) {
            const tty_table = tty_proc.?.cap_table;
            if (tty_table) |tbl| {
                capability.insertAt(tbl, FB_CAP_SLOT, &fb_obj.?.base, capability.Rights.RW) catch {
                    printFail("FB cap grant to tty failed");
                };
                if (tbl.isSlotUsed(FB_CAP_SLOT)) {
                    printOk("Framebuffer cap granted to tty (slot 7)");
                }
            }
        } else {
            printFail("Framebuffer MemoryObject alloc failed");
        }
    }

    if (init_loaded) {
        printOk("Init process loaded");
        printStatus("Starting scheduler...", 0x00ffffff);

        // Enable interrupts
        idt.enable();

        // Now start APIC timer if APIC is enabled
        if (apic.isEnabled()) {
            apic.initTimer(100);
        } else {
            // Unmask PIC timer for fallback
            pic.unmaskIrq(0);
        }

        scheduler.start(); // Never returns
    } else {
        printInfo("No init module found - kernel standalone mode");
        printStatus("Kernel ready (no user space).", 0x00ffffff);
        halt();
    }
}

/// Load init process from boot module
fn loadInitProcess(module: *limine.File) bool {
    debugPrint("[DEBUG] loadInitProcess: starting");

    // Get module data
    const module_addr: u64 = @intFromPtr(module.address);
    const module_size = module.size;

    debugPuts("[DEBUG] Module addr: ");
    debugHex(module_addr);
    debugPuts(", size: ");
    debugDec(module_size);
    debugPuts("\n");

    if (module_size == 0) {
        printFail("Init module is empty");
        return false;
    }

    // Create slice from module data
    const module_data: [*]const u8 = @ptrFromInt(module_addr);
    const data_slice = module_data[0..module_size];

    debugPrint("[DEBUG] Checking if valid ELF...");

    // Validate ELF
    if (!elf.isElf(data_slice)) {
        printFail("Init module is not a valid ELF");
        return false;
    }

    debugPrint("[DEBUG] Creating process...");

    // Create init process
    const init_proc = process.create(null) orelse {
        printFail("Failed to create init process");
        return false;
    };

    debugPrint("[DEBUG] Process created, setting name...");

    init_proc.setName("init");
    init_proc.flags.init_process = true;

    // Get address space
    const space = init_proc.address_space orelse {
        printFail("Init process has no address space");
        return false;
    };

    debugPrint("[DEBUG] Loading ELF into address space...");

    // Load ELF into address space
    const load_result = elf.load(space, data_slice) catch {
        printFail("Failed to load init ELF");
        process.destroy(init_proc);
        return false;
    };

    debugPrint("[DEBUG] ELF loaded successfully");

    // Allocate user stack
    const stack_result = usermode.allocateUserStack(space) catch {
        printFail("Failed to allocate user stack");
        process.destroy(init_proc);
        return false;
    };
    _ = stack_result;

    // Create main thread for init
    const init_thread = thread.createUser(init_proc, load_result.entry_point, usermode.USER_STACK_TOP - 8) orelse {
        printFail("Failed to create init thread");
        process.destroy(init_proc);
        return false;
    };

    // Add thread to process
    _ = init_proc.addThread(init_thread);

    // Add to scheduler
    scheduler.enqueue(init_thread);

    return true;
}

fn halt() noreturn {
    asm volatile ("cli");
    while (true) {
        asm volatile ("hlt");
    }
}

// Panic handler for Zig runtime
pub fn panic(msg: []const u8, _: ?*@import("std").builtin.StackTrace, _: ?usize) noreturn {
    // Output to serial first (most reliable)
    serial.println("");
    serial.println("!!! KERNEL PANIC !!!");
    serial.puts("Message: ");
    serial.println(msg);
    serial.println("");

    // Try to display panic message on framebuffer
    if (framebuffer_request.response != null) {
        framebuffer.puts("KERNEL PANIC: ", 10, 400, 0x00ff0000);
        framebuffer.puts(msg, 130, 400, 0x00ff0000);
    }
    halt();
}

/// Parse module cmdline to get module name
fn parseModuleCmdline(cmdline: [*:0]const u8) []const u8 {
    // Get length of null-terminated string
    var len: usize = 0;
    while (cmdline[len] != 0 and len < 256) {
        len += 1;
    }
    return cmdline[0..len];
}

/// Simple string equality check
fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (ac != bc) return false;
    }
    return true;
}

/// Well-known capability slots for user-space service endpoints.
/// Must match the constants in user/lib/vfs.zig, user/lib/log.zig, and user/lib/blk.zig.
const VFS_CAP_SLOT: u32 = 1;
const LOG_CAP_SLOT: u32 = 2;
const DEVFS_CAP_SLOT: u32 = 3;
const BLK_CAP_SLOT: u32 = 4;
const FATFS_CAP_SLOT: u32 = 5;
const TTY_CAP_SLOT: u32 = 6;
const FB_CAP_SLOT: u32 = 7;
/// Async tty-input endpoint. tty holds HANDLE; kbd and serial hold
/// SEND and push `.tty_input` requests fire-and-forget. Kept off the
/// shell↔tty (TTY_CAP_SLOT) endpoint so kbd/serial sends never
/// direct-hand-off into shell's parked recv for a TTY reply.
const TTY_INPUT_SLOT: u32 = 8;
const SERIAL_CAP_SLOT: u32 = 9;

/// Create a VFS endpoint and inject the cap into ramfs (HANDLE) and shell (SEND).
fn wireVfsEndpoint(ramfs: *process.Process, shell: *process.Process) bool {
    return wireServiceEndpoint(ramfs, shell, VFS_CAP_SLOT) != null;
}

/// Create an IPC endpoint and give server HANDLE+SEND, client SEND+HANDLE
/// at the same well-known slot in both cap tables. Returns the endpoint
/// pointer so additional clients can be attached via `grantSendCap`.
fn wireServiceEndpoint(server: *process.Process, client: *process.Process, slot: u32) ?*ipc.Endpoint {
    const endpoint = ipc.createEndpoint() orelse return null;

    const server_table = server.cap_table orelse return null;
    const client_table = client.cap_table orelse return null;

    const server_rights = capability.Rights{ .handle = true, .send = true };
    capability.insertAt(server_table, slot, &endpoint.base, server_rights) catch return null;

    const client_rights = capability.Rights{ .send = true, .handle = true };
    capability.insertAt(client_table, slot, &endpoint.base, client_rights) catch {
        capability.delete(server_table, slot);
        return null;
    };

    return endpoint;
}

/// Add a SEND-only capability for an existing endpoint to another
/// process's cap table at `slot`. Used to attach extra clients (e.g.
/// fatfs as a second BLK client alongside devfs).
fn grantSendCap(proc: *process.Process, endpoint: *ipc.Endpoint, slot: u32) bool {
    const tbl = proc.cap_table orelse return false;
    const rights = capability.Rights{ .send = true };
    capability.insertAt(tbl, slot, &endpoint.base, rights) catch return false;
    return true;
}

/// Load a generic user process from boot module, return process pointer.
fn loadUserProcessP(module: *limine.File, name: []const u8) ?*process.Process {
    const module_addr: u64 = @intFromPtr(module.address);
    const module_size = module.size;

    if (module_size == 0) {
        printFail("User module is empty");
        return null;
    }

    const module_data: [*]const u8 = @ptrFromInt(module_addr);
    const data_slice = module_data[0..module_size];

    if (!elf.isElf(data_slice)) {
        printFail("User module is not a valid ELF");
        return null;
    }

    const user_proc = process.create(null) orelse {
        printFail("Failed to create user process");
        return null;
    };

    user_proc.setName(name);

    const space = user_proc.address_space orelse {
        printFail("User process has no address space");
        process.destroy(user_proc);
        return null;
    };

    const load_result = elf.load(space, data_slice) catch {
        printFail("Failed to load user ELF");
        process.destroy(user_proc);
        return null;
    };

    _ = usermode.allocateUserStack(space) catch {
        printFail("Failed to allocate user stack");
        process.destroy(user_proc);
        return null;
    };

    const user_thread = thread.createUser(user_proc, load_result.entry_point, usermode.USER_STACK_TOP - 8) orelse {
        printFail("Failed to create user thread");
        process.destroy(user_proc);
        return null;
    };

    _ = user_proc.addThread(user_thread);
    scheduler.enqueue(user_thread);

    return user_proc;
}

/// Load a generic user process from boot module
fn loadUserProcess(module: *limine.File, name: []const u8) bool {
    const module_addr: u64 = @intFromPtr(module.address);
    const module_size = module.size;

    if (module_size == 0) {
        printFail("User module is empty");
        return false;
    }

    const module_data: [*]const u8 = @ptrFromInt(module_addr);
    const data_slice = module_data[0..module_size];

    if (!elf.isElf(data_slice)) {
        printFail("User module is not a valid ELF");
        return false;
    }

    const user_proc = process.create(null) orelse {
        printFail("Failed to create user process");
        return false;
    };

    user_proc.setName(name);

    const space = user_proc.address_space orelse {
        printFail("User process has no address space");
        process.destroy(user_proc);
        return false;
    };

    const load_result = elf.load(space, data_slice) catch {
        printFail("Failed to load user ELF");
        process.destroy(user_proc);
        return false;
    };

    _ = usermode.allocateUserStack(space) catch {
        printFail("Failed to allocate user stack");
        process.destroy(user_proc);
        return false;
    };

    const user_thread = thread.createUser(user_proc, load_result.entry_point, usermode.USER_STACK_TOP - 8) orelse {
        printFail("Failed to create user thread");
        process.destroy(user_proc);
        return false;
    };

    _ = user_proc.addThread(user_thread);
    scheduler.enqueue(user_thread);

    return true;
}

/// Load a PCI driver process: ELF → driver_process → registerPciDriver
/// (which grants IRQ + MMIO BAR + I/O port caps from the discovered PCI device).
fn loadPciDriverProcess(
    module: *limine.File,
    name: []const u8,
    driver_type: driver.DriverType,
    pci_dev: *const pci.Device,
) ?*process.Process {
    const module_addr: u64 = @intFromPtr(module.address);
    const module_size = module.size;

    if (module_size == 0) {
        printFail("PCI driver module is empty");
        return null;
    }

    const module_data: [*]const u8 = @ptrFromInt(module_addr);
    const data_slice = module_data[0..module_size];

    if (!elf.isElf(data_slice)) {
        printFail("PCI driver module is not a valid ELF");
        return null;
    }

    const drv_proc = process.create(null) orelse {
        printFail("Failed to create PCI driver process");
        return null;
    };

    drv_proc.setName(name);
    drv_proc.flags.driver_process = true;

    const space = drv_proc.address_space orelse {
        printFail("PCI driver process has no address space");
        process.destroy(drv_proc);
        return null;
    };

    const load_result = elf.load(space, data_slice) catch {
        printFail("Failed to load PCI driver ELF");
        process.destroy(drv_proc);
        return null;
    };

    _ = usermode.allocateUserStack(space) catch {
        printFail("Failed to allocate PCI driver stack");
        process.destroy(drv_proc);
        return null;
    };

    const drv_thread = thread.createUser(drv_proc, load_result.entry_point, usermode.USER_STACK_TOP - 8) orelse {
        printFail("Failed to create PCI driver thread");
        process.destroy(drv_proc);
        return null;
    };

    _ = drv_proc.addThread(drv_thread);

    const entry = driver.registerPciDriver(name, driver_type, drv_proc, pci_dev);
    if (entry == null) {
        printFail("Failed to register PCI driver");
        process.destroy(drv_proc);
        return null;
    }

    scheduler.enqueue(drv_thread);
    return drv_proc;
}

/// Load a driver process from boot module and register it with the driver framework
fn loadDriverProcess(
    module: *limine.File,
    name: []const u8,
    driver_type: driver.DriverType,
    irq: ?u8,
    io_port_start: ?u16,
    io_port_count: u16,
) ?*process.Process {
    // Get module data
    const module_addr: u64 = @intFromPtr(module.address);
    const module_size = module.size;

    if (module_size == 0) {
        printFail("Driver module is empty");
        return null;
    }

    // Create slice from module data
    const module_data: [*]const u8 = @ptrFromInt(module_addr);
    const data_slice = module_data[0..module_size];

    // Validate ELF
    if (!elf.isElf(data_slice)) {
        printFail("Driver module is not a valid ELF");
        return null;
    }

    // Create driver process
    const drv_proc = process.create(null) orelse {
        printFail("Failed to create driver process");
        return null;
    };

    drv_proc.setName(name);
    drv_proc.flags.driver_process = true;

    // Get address space
    const space = drv_proc.address_space orelse {
        printFail("Driver process has no address space");
        process.destroy(drv_proc);
        return null;
    };

    // Load ELF into address space
    const load_result = elf.load(space, data_slice) catch {
        printFail("Failed to load driver ELF");
        process.destroy(drv_proc);
        return null;
    };

    // Allocate user stack
    _ = usermode.allocateUserStack(space) catch {
        printFail("Failed to allocate driver stack");
        process.destroy(drv_proc);
        return null;
    };

    // Create main thread for driver
    const drv_thread = thread.createUser(drv_proc, load_result.entry_point, usermode.USER_STACK_TOP - 8) orelse {
        printFail("Failed to create driver thread");
        process.destroy(drv_proc);
        return null;
    };

    // Add thread to process
    _ = drv_proc.addThread(drv_thread);

    // Register driver and grant capabilities
    const entry = driver.registerDriver(
        name,
        driver_type,
        drv_proc,
        irq,
        io_port_start,
        io_port_count,
    );

    if (entry == null) {
        printFail("Failed to register driver");
        process.destroy(drv_proc);
        return null;
    }

    // Add to scheduler
    scheduler.enqueue(drv_thread);

    return drv_proc;
}
