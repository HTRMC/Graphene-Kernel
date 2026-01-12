// Graphene User Library - Program Entry Point
// Provides _start that calls main and handles exit

const syscall = @import("syscall");
const main_module = @import("main");

/// Program entry point (called by kernel)
export fn _start() callconv(.c) noreturn {
    // Call user's main function
    const exit_code = main_module.main();

    // Exit with the return code
    syscall.processExit(exit_code);
}

/// Panic handler for Zig runtime in user space
pub fn panic(msg: []const u8, _: ?*@import("std").builtin.StackTrace, _: ?usize) noreturn {
    // Print panic message
    _ = syscall.debugPrint("USER PANIC: ");
    _ = syscall.debugPrint(msg);
    _ = syscall.debugPrint("\n");

    // Exit with error code
    syscall.processExit(1);
}
