// Graphene User Library - Program Entry Point
// Provides _start that calls main and handles exit

const std = @import("std");
const syscall = @import("syscall");
const main_module = @import("main");

// Optional per-process name. Programs may declare:
//   pub const proc_name: []const u8 = "name";
// and start.zig's panic handler will include it in the user-panic log
// so we can tell which process aborted.
const proc_name: []const u8 = if (@hasDecl(main_module, "proc_name"))
    main_module.proc_name
else
    "user";

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
    refAllRecursive(syscall);
    refAllRecursive(main_module);
}

/// Program entry point (called by kernel)
export fn _start() callconv(.c) noreturn {
    // Call user's main function
    const exit_code = main_module.main();

    // Exit with the return code
    syscall.processExit(exit_code);
}

/// Panic handler for Zig runtime in user space
pub fn panic(msg: []const u8, _: ?*@import("std").builtin.StackTrace, _: ?usize) noreturn {
    _ = syscall.klog("USER PANIC [");
    _ = syscall.klog(proc_name);
    _ = syscall.klog("]: ");
    _ = syscall.klog(msg);
    _ = syscall.klog("\n");
    syscall.processExit(1);
}
