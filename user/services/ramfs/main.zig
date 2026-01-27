// Graphene Ramfs Service - RAM Filesystem Server
// A user-space filesystem service that stores files in memory

const syscall = @import("syscall");

// ============================================================================
// Filesystem Protocol Constants
// ============================================================================

/// Maximum filename length
const MAX_NAME_LEN: usize = 64;

/// Maximum file size (64KB per file for now)
const MAX_FILE_SIZE: usize = 64 * 1024;

/// Maximum number of files in ramfs
const MAX_FILES: usize = 64;

/// Maximum data per IPC message
const MAX_MSG_DATA: usize = 256;

/// Filesystem operation codes
const FsOp = enum(u8) {
    open = 1,
    close = 2,
    read = 3,
    write = 4,
    stat = 5,
    readdir = 6,
    create = 7,
    delete = 8,
    mkdir = 9,
    ping = 255,
};

/// Filesystem error codes
const FsError = enum(i32) {
    success = 0,
    not_found = -1,
    exists = -2,
    no_space = -3,
    invalid_arg = -4,
    is_directory = -5,
    not_directory = -6,
    not_empty = -7,
    io_error = -8,
    permission = -9,
};

/// File type
const FileType = enum(u8) {
    regular = 1,
    directory = 2,
};

// ============================================================================
// Filesystem Data Structures
// ============================================================================

/// File entry in ramfs
const FileEntry = struct {
    name: [MAX_NAME_LEN]u8 = [_]u8{0} ** MAX_NAME_LEN,
    name_len: u8 = 0,
    file_type: FileType = .regular,
    parent: u8 = 0, // Index of parent directory (0 = root)
    size: u32 = 0,
    data: [MAX_FILE_SIZE]u8 = undefined,
    in_use: bool = false,
};

/// File stat result
const FileStat = extern struct {
    size: u32,
    file_type: u8,
    _pad: [3]u8 = .{ 0, 0, 0 },
};

// ============================================================================
// Global Filesystem State
// ============================================================================

var files: [MAX_FILES]FileEntry = undefined;
var fs_initialized: bool = false;

// ============================================================================
// Filesystem Operations
// ============================================================================

fn initFs() void {
    // Initialize all file entries
    for (&files) |*f| {
        f.* = FileEntry{};
    }

    // Create root directory at index 0
    files[0].in_use = true;
    files[0].file_type = .directory;
    files[0].name[0] = '/';
    files[0].name_len = 1;
    files[0].parent = 0; // Root is its own parent

    fs_initialized = true;
    _ = syscall.debugPrint("[ramfs] Filesystem initialized\n");
}

fn findFile(name: []const u8, parent: u8) ?u8 {
    for (&files, 0..) |*f, i| {
        if (f.in_use and f.parent == parent) {
            if (strEql(f.name[0..f.name_len], name)) {
                return @intCast(i);
            }
        }
    }
    return null;
}

fn allocFile() ?u8 {
    // Start at 1 (0 is root)
    for (1..MAX_FILES) |i| {
        if (!files[i].in_use) {
            return @intCast(i);
        }
    }
    return null;
}

fn createFile(name: []const u8, parent: u8, file_type: FileType) FsError {
    if (name.len == 0 or name.len > MAX_NAME_LEN) {
        return .invalid_arg;
    }

    // Check parent is a directory
    if (!files[parent].in_use or files[parent].file_type != .directory) {
        return .not_directory;
    }

    // Check if file already exists
    if (findFile(name, parent) != null) {
        return .exists;
    }

    // Allocate new file entry
    const idx = allocFile() orelse return .no_space;

    files[idx].in_use = true;
    files[idx].file_type = file_type;
    files[idx].parent = parent;
    files[idx].size = 0;

    // Copy name
    for (0..name.len) |i| {
        files[idx].name[i] = name[i];
    }
    files[idx].name_len = @intCast(name.len);

    return .success;
}

fn deleteFile(idx: u8) FsError {
    if (idx == 0) {
        return .permission; // Cannot delete root
    }

    if (!files[idx].in_use) {
        return .not_found;
    }

    // If directory, check if empty
    if (files[idx].file_type == .directory) {
        for (&files) |*f| {
            if (f.in_use and f.parent == idx) {
                return .not_empty;
            }
        }
    }

    files[idx].in_use = false;
    return .success;
}

fn readFile(idx: u8, offset: u32, buf: []u8) FsError {
    if (!files[idx].in_use) {
        return .not_found;
    }

    if (files[idx].file_type != .regular) {
        return .is_directory;
    }

    if (offset >= files[idx].size) {
        return .success; // EOF
    }

    const available = files[idx].size - offset;
    const to_read = @min(buf.len, available);

    for (0..to_read) |i| {
        buf[i] = files[idx].data[offset + i];
    }

    return .success;
}

fn writeFile(idx: u8, offset: u32, data: []const u8) FsError {
    if (!files[idx].in_use) {
        return .not_found;
    }

    if (files[idx].file_type != .regular) {
        return .is_directory;
    }

    const end_pos = offset + @as(u32, @intCast(data.len));
    if (end_pos > MAX_FILE_SIZE) {
        return .no_space;
    }

    for (0..data.len) |i| {
        files[idx].data[offset + i] = data[i];
    }

    // Update size if needed
    if (end_pos > files[idx].size) {
        files[idx].size = end_pos;
    }

    return .success;
}

// ============================================================================
// IPC Request Handling
// ============================================================================

/// Request header (in message data)
const RequestHeader = extern struct {
    op: u8,
    flags: u8,
    name_len: u8,
    _pad: u8 = 0,
    offset: u32,
    size: u32,
};

/// Response header
const ResponseHeader = extern struct {
    error_code: i32,
    size: u32,
};

fn handleRequest(req_data: []const u8, resp_data: []u8) usize {
    if (req_data.len < @sizeOf(RequestHeader)) {
        // Invalid request
        const resp: *ResponseHeader = @ptrCast(@alignCast(resp_data.ptr));
        resp.error_code = @intFromEnum(FsError.invalid_arg);
        resp.size = 0;
        return @sizeOf(ResponseHeader);
    }

    const req: *const RequestHeader = @ptrCast(@alignCast(req_data.ptr));
    const op: FsOp = @enumFromInt(req.op);

    // Name follows header if name_len > 0
    var name: []const u8 = &.{};
    if (req.name_len > 0 and req_data.len >= @sizeOf(RequestHeader) + req.name_len) {
        name = req_data[@sizeOf(RequestHeader)..][0..req.name_len];
    }

    // Data follows name
    const data_offset = @sizeOf(RequestHeader) + req.name_len;
    var data: []const u8 = &.{};
    if (req_data.len > data_offset) {
        data = req_data[data_offset..];
    }

    const resp: *ResponseHeader = @ptrCast(@alignCast(resp_data.ptr));
    const resp_payload = resp_data[@sizeOf(ResponseHeader)..];

    switch (op) {
        .ping => {
            resp.error_code = 0;
            resp.size = 4;
            if (resp_payload.len >= 4) {
                resp_payload[0] = 'P';
                resp_payload[1] = 'O';
                resp_payload[2] = 'N';
                resp_payload[3] = 'G';
            }
            return @sizeOf(ResponseHeader) + 4;
        },
        .create => {
            const result = createFile(name, 0, .regular); // Create in root for now
            resp.error_code = @intFromEnum(result);
            resp.size = 0;
            return @sizeOf(ResponseHeader);
        },
        .mkdir => {
            const result = createFile(name, 0, .directory);
            resp.error_code = @intFromEnum(result);
            resp.size = 0;
            return @sizeOf(ResponseHeader);
        },
        .delete => {
            if (findFile(name, 0)) |idx| {
                const result = deleteFile(idx);
                resp.error_code = @intFromEnum(result);
            } else {
                resp.error_code = @intFromEnum(FsError.not_found);
            }
            resp.size = 0;
            return @sizeOf(ResponseHeader);
        },
        .stat => {
            if (findFile(name, 0)) |idx| {
                resp.error_code = 0;
                resp.size = @sizeOf(FileStat);
                if (resp_payload.len >= @sizeOf(FileStat)) {
                    const stat: *FileStat = @ptrCast(@alignCast(resp_payload.ptr));
                    stat.size = files[idx].size;
                    stat.file_type = @intFromEnum(files[idx].file_type);
                }
            } else {
                resp.error_code = @intFromEnum(FsError.not_found);
                resp.size = 0;
            }
            return @sizeOf(ResponseHeader) + resp.size;
        },
        .read => {
            if (findFile(name, 0)) |idx| {
                const max_read = @min(req.size, @as(u32, @intCast(resp_payload.len)));
                const result = readFile(idx, req.offset, resp_payload[0..max_read]);
                resp.error_code = @intFromEnum(result);
                if (result == .success) {
                    const available = if (files[idx].size > req.offset)
                        files[idx].size - req.offset
                    else
                        0;
                    resp.size = @min(max_read, available);
                } else {
                    resp.size = 0;
                }
            } else {
                resp.error_code = @intFromEnum(FsError.not_found);
                resp.size = 0;
            }
            return @sizeOf(ResponseHeader) + resp.size;
        },
        .write => {
            if (findFile(name, 0)) |idx| {
                const result = writeFile(idx, req.offset, data);
                resp.error_code = @intFromEnum(result);
                resp.size = if (result == .success) @intCast(data.len) else 0;
            } else {
                resp.error_code = @intFromEnum(FsError.not_found);
                resp.size = 0;
            }
            return @sizeOf(ResponseHeader);
        },
        .readdir => {
            // List files in root directory
            var count: u32 = 0;
            var pos: usize = 0;
            for (&files) |*f| {
                if (f.in_use and f.parent == 0 and f != &files[0]) {
                    // Write entry: name_len (1 byte) + type (1 byte) + name
                    if (pos + 2 + f.name_len <= resp_payload.len) {
                        resp_payload[pos] = f.name_len;
                        resp_payload[pos + 1] = @intFromEnum(f.file_type);
                        for (0..f.name_len) |i| {
                            resp_payload[pos + 2 + i] = f.name[i];
                        }
                        pos += 2 + f.name_len;
                        count += 1;
                    }
                }
            }
            resp.error_code = @intCast(count);
            resp.size = @intCast(pos);
            return @sizeOf(ResponseHeader) + pos;
        },
        else => {
            resp.error_code = @intFromEnum(FsError.invalid_arg);
            resp.size = 0;
            return @sizeOf(ResponseHeader);
        },
    }
}

// ============================================================================
// Helper Functions
// ============================================================================

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (ac != bc) return false;
    }
    return true;
}

// ============================================================================
// Main Entry Point
// ============================================================================

pub fn main() i32 {
    _ = syscall.debugPrint("[ramfs] RAM Filesystem service starting...\n");

    // Initialize the filesystem
    initFs();

    // Create some test files
    _ = createFile("hello.txt", 0, .regular);
    if (findFile("hello.txt", 0)) |idx| {
        _ = writeFile(idx, 0, "Hello from ramfs!");
    }

    _ = createFile("test", 0, .directory);
    _ = createFile("readme.txt", 0, .regular);
    if (findFile("readme.txt", 0)) |idx| {
        _ = writeFile(idx, 0, "Graphene Ramfs v0.1\nA simple RAM filesystem.\n");
    }

    _ = syscall.debugPrint("[ramfs] Test files created\n");
    _ = syscall.debugPrint("[ramfs] Filesystem ready, waiting for requests...\n");

    // Main service loop - for now just idle
    // In future: create IPC endpoint and handle requests
    while (true) {
        syscall.threadYield();
    }

    // This is unreachable, but needed for return type
    return 0;
}
