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

// Limine request markers - placed in special section
export var requests_start linksection(".limine_requests_start") = limine.RequestsStartMarker{};
export var requests_end linksection(".limine_requests_end") = limine.RequestsEndMarker{};

// Limine requests - these are read by the bootloader
pub export var base_revision linksection(".limine_requests") = limine.BaseRevision{ .revision = 3 };
pub export var framebuffer_request linksection(".limine_requests") = limine.FramebufferRequest{};
pub export var memmap_request linksection(".limine_requests") = limine.MemoryMapRequest{};
pub export var hhdm_request linksection(".limine_requests") = limine.HhdmRequest{};

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

    // ========================================
    // Phase 5: Ready
    // ========================================
    status_y += 10;
    printStatus("All Phase 1 subsystems initialized!", 0x0000ff00);
    status_y += 10;
    printStatus("Kernel ready.", 0x00ffffff);

    // For Phase 1, we don't start the scheduler yet
    // (no user processes to run)
    // scheduler.start() would be called here once we have processes

    halt();
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
