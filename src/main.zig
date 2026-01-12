const limine = @import("lib/limine.zig");
const framebuffer = @import("lib/framebuffer.zig");
const gdt = @import("lib/gdt.zig");
const idt = @import("lib/idt.zig");
const pic = @import("lib/pic.zig");

// Limine request markers and requests - placed in special section
export var requests_start linksection(".limine_requests_start") = limine.RequestsStartMarker{};
export var requests_end linksection(".limine_requests_end") = limine.RequestsEndMarker{};

// Limine requests - these are read by the bootloader
pub export var base_revision linksection(".limine_requests") = limine.BaseRevision{ .revision = 3 };
pub export var framebuffer_request linksection(".limine_requests") = limine.FramebufferRequest{};

// Kernel entry point (must match linker ENTRY)
export fn _start() callconv(.c) noreturn {
    // Verify Limine protocol version
    if (!base_revision.is_supported()) {
        halt();
    }

    // Initialize core CPU structures
    gdt.init(); // Global Descriptor Table + TSS
    pic.init(); // Remap PIC interrupts to vectors 32-47
    pic.maskAll(); // Mask all IRQs until we have handlers
    idt.init(); // Interrupt Descriptor Table

    // Get framebuffer
    if (framebuffer_request.response) |fb_response| {
        const fbs = fb_response.framebuffers();
        if (fbs.len > 0) {
            const fb = fbs[0];
            framebuffer.init(fb);
            framebuffer.clear(0x001a1a2e); // Dark blue background

            // Display welcome message
            framebuffer.puts("Graphene Kernel v0.1.0", 10, 10, 0x00ffffff);
            framebuffer.puts("======================", 10, 30, 0x00888888);
            framebuffer.puts("Hybrid Microkernel Architecture", 10, 60, 0x0000ff88);
            framebuffer.puts("Capability-Based Security", 10, 80, 0x0000ff88);
            framebuffer.puts("Written in Zig", 10, 100, 0x00f7a41d);
            framebuffer.puts("", 10, 130, 0x00ffffff);
            framebuffer.puts("[OK] GDT initialized", 10, 150, 0x0000ff00);
            framebuffer.puts("[OK] IDT initialized", 10, 170, 0x0000ff00);
            framebuffer.puts("[OK] PIC remapped", 10, 190, 0x0000ff00);
            framebuffer.puts("", 10, 220, 0x00ffffff);
            framebuffer.puts("Kernel ready.", 10, 240, 0x00ffffff);
        }
    }

    // Enable interrupts (once we have proper handlers)
    // idt.enable();

    halt();
}

fn halt() noreturn {
    // Disable interrupts and halt
    asm volatile ("cli");
    while (true) {
        asm volatile ("hlt");
    }
}

// Panic handler for Zig runtime
pub fn panic(msg: []const u8, _: ?*@import("std").builtin.StackTrace, _: ?usize) noreturn {
    _ = msg;
    halt();
}
