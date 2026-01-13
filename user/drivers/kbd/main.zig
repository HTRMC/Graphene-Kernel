// Graphene PS/2 Keyboard Driver - Minimal Test Version

const syscall = @import("syscall");

/// Main entry point for keyboard driver
pub fn main() i32 {
    syscall.print("kbd: started\n");

    // Test 1: Just yield in a loop (no IRQ)
    var count: u32 = 0;
    while (count < 5) {
        syscall.print("kbd: loop\n");
        syscall.threadYield();
        count += 1;
    }

    syscall.print("kbd: yield test passed\n");

    // Test 2: Try irqWait
    syscall.print("kbd: trying irqWait...\n");
    const wait_result = syscall.irqWait(0);
    if (wait_result < 0) {
        syscall.print("kbd: irqWait returned error\n");
    } else {
        syscall.print("kbd: irqWait returned ok\n");
    }

    syscall.print("kbd: done\n");
    return 0;
}
