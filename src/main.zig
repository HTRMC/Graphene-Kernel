// Graphene Kernel - Main Entry Point
// Hybrid Microkernel with Capability-Based Security

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

// Limine request markers - placed in special section
export var requests_start linksection(".limine_requests_start") = limine.RequestsStartMarker{};
export var requests_end linksection(".limine_requests_end") = limine.RequestsEndMarker{};

// Limine requests - these are read by the bootloader
pub export var base_revision linksection(".limine_requests") = limine.BaseRevision{ .revision = 3 };
pub export var framebuffer_request linksection(".limine_requests") = limine.FramebufferRequest{};
pub export var memmap_request linksection(".limine_requests") = limine.MemoryMapRequest{};
pub export var hhdm_request linksection(".limine_requests") = limine.HhdmRequest{};
pub export var module_request linksection(".limine_requests") = limine.ModuleRequest{};

// Status display Y position
var status_y: u32 = 150;

fn printStatus(msg: []const u8, color: u32) void {
    framebuffer.puts(msg, 10, status_y, color);
    status_y += 20;
}

fn printOk(msg: []const u8) void {
    framebuffer.puts("[OK] ", 10, status_y, 0x0000ff00);
    framebuffer.puts(msg, 50, status_y, 0x00ffffff);
    status_y += 20;
}

fn printFail(msg: []const u8) void {
    framebuffer.puts("[!!] ", 10, status_y, 0x00ff0000);
    framebuffer.puts(msg, 50, status_y, 0x00ff0000);
    status_y += 20;
}

fn printInfo(msg: []const u8) void {
    framebuffer.puts("     ", 10, status_y, 0x00888888);
    framebuffer.puts(msg, 50, status_y, 0x00888888);
    status_y += 20;
}

// Kernel entry point
export fn _start() callconv(.c) noreturn {
    // Verify Limine protocol version
    if (!base_revision.is_supported()) {
        halt();
    }

    // ========================================
    // Phase 1: CPU Structures
    // ========================================
    gdt.init();
    pic.init();
    pic.maskAll();
    idt.init();

    // ========================================
    // Phase 2: Framebuffer Setup
    // ========================================
    if (framebuffer_request.response) |fb_response| {
        const fbs = fb_response.framebuffers();
        if (fbs.len > 0) {
            framebuffer.init(fbs[0]);
            framebuffer.clear(0x001a1a2e);

            // Header
            framebuffer.puts("Graphene Kernel v0.1.0", 10, 10, 0x00ffffff);
            framebuffer.puts("======================", 10, 30, 0x00888888);
            framebuffer.puts("Hybrid Microkernel | Capability-Based Security", 10, 60, 0x0000ff88);
            framebuffer.puts("Phase 1 Complete", 10, 80, 0x00f7a41d);
            framebuffer.puts("", 10, 110, 0x00ffffff);
            framebuffer.puts("Initialization:", 10, 130, 0x00ffffff);
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
    status_y += 10;
    printStatus("All Phase 1 subsystems initialized!", 0x0000ff00);

    // Load boot modules
    var init_loaded = false;
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
                if (loadDriverProcess(module, "kbd", driver.DriverType.keyboard, 1, 0x60, 5)) {
                    printOk("Loaded: kbd (IRQ 1, ports 0x60-0x64)");
                }
            } else if (strEql(module_name, "shell")) {
                // Load shell as a user process
                if (loadUserProcess(module, "shell")) {
                    printOk("Loaded: shell");
                }
            } else {
                // Unknown module - try to load as generic driver
                printInfo("Skipping unknown module");
            }
        }
    }

    if (init_loaded) {
        printOk("Init process loaded");
        status_y += 10;
        printStatus("Starting scheduler...", 0x00ffffff);

        // Enable interrupts and start scheduler
        idt.enable();
        scheduler.start(); // Never returns
    } else {
        printInfo("No init module found - kernel standalone mode");
        status_y += 10;
        printStatus("Kernel ready (no user space).", 0x00ffffff);
        halt();
    }
}

/// Load init process from boot module
fn loadInitProcess(module: *limine.File) bool {
    // Get module data
    const module_addr: u64 = @intFromPtr(module.address);
    const module_size = module.size;

    if (module_size == 0) {
        printFail("Init module is empty");
        return false;
    }

    // Create slice from module data
    const module_data: [*]const u8 = @ptrFromInt(module_addr);
    const data_slice = module_data[0..module_size];

    // Validate ELF
    if (!elf.isElf(data_slice)) {
        printFail("Init module is not a valid ELF");
        return false;
    }

    // Create init process
    const init_proc = process.create(null) orelse {
        printFail("Failed to create init process");
        return false;
    };

    init_proc.setName("init");
    init_proc.flags.init_process = true;

    // Get address space
    const space = init_proc.address_space orelse {
        printFail("Init process has no address space");
        return false;
    };

    // Load ELF into address space
    const load_result = elf.load(space, data_slice) catch {
        printFail("Failed to load init ELF");
        process.destroy(init_proc);
        return false;
    };

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
    // Try to display panic message
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

/// Load a driver process from boot module and register it with the driver framework
fn loadDriverProcess(
    module: *limine.File,
    name: []const u8,
    driver_type: driver.DriverType,
    irq: ?u8,
    io_port_start: ?u16,
    io_port_count: u16,
) bool {
    // Get module data
    const module_addr: u64 = @intFromPtr(module.address);
    const module_size = module.size;

    if (module_size == 0) {
        printFail("Driver module is empty");
        return false;
    }

    // Create slice from module data
    const module_data: [*]const u8 = @ptrFromInt(module_addr);
    const data_slice = module_data[0..module_size];

    // Validate ELF
    if (!elf.isElf(data_slice)) {
        printFail("Driver module is not a valid ELF");
        return false;
    }

    // Create driver process
    const drv_proc = process.create(null) orelse {
        printFail("Failed to create driver process");
        return false;
    };

    drv_proc.setName(name);
    drv_proc.flags.driver_process = true;

    // Get address space
    const space = drv_proc.address_space orelse {
        printFail("Driver process has no address space");
        process.destroy(drv_proc);
        return false;
    };

    // Load ELF into address space
    const load_result = elf.load(space, data_slice) catch {
        printFail("Failed to load driver ELF");
        process.destroy(drv_proc);
        return false;
    };

    // Allocate user stack
    _ = usermode.allocateUserStack(space) catch {
        printFail("Failed to allocate driver stack");
        process.destroy(drv_proc);
        return false;
    };

    // Create main thread for driver
    const drv_thread = thread.createUser(drv_proc, load_result.entry_point, usermode.USER_STACK_TOP - 8) orelse {
        printFail("Failed to create driver thread");
        process.destroy(drv_proc);
        return false;
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
        return false;
    }

    // Add to scheduler
    scheduler.enqueue(drv_thread);

    return true;
}
