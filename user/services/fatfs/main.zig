// Graphene FAT32 Service - Read-only FAT32 filesystem server
//
// Holds a SEND capability on the BLK endpoint (slot 4) and reads sectors
// from /dev/vda via the chunked block protocol. Parses the FAT32 boot
// sector, indexes the root directory (8.3 names only, no LFN), and
// serves VFS open/read/stat/readdir/close requests on FATFS_CAP_SLOT.

const syscall = @import("syscall");
const vfs = @import("vfs");
const blk = @import("blk");

// ---------------------------------------------------------------------------
// Capability slots used by this process
// ---------------------------------------------------------------------------
// Slot 4: SEND cap to BLK endpoint (set up by kernel boot wiring).
// Slot 5: HANDLE cap on FATFS endpoint (also set up by boot wiring).
const BLK_SLOT: u32 = vfs.BLK_CAP_SLOT;
const FATFS_SLOT: u32 = vfs.FATFS_CAP_SLOT;

// ---------------------------------------------------------------------------
// FAT32 on-disk layout constants
// ---------------------------------------------------------------------------
const SECTOR_SIZE: u32 = 512;
const DIR_ENTRY_SIZE: u32 = 32;

const ATTR_READ_ONLY: u8 = 0x01;
const ATTR_HIDDEN: u8 = 0x02;
const ATTR_SYSTEM: u8 = 0x04;
const ATTR_VOLUME_ID: u8 = 0x08;
const ATTR_DIRECTORY: u8 = 0x10;
const ATTR_ARCHIVE: u8 = 0x20;
const ATTR_LFN: u8 = 0x0F; // long-filename component, skipped here

// FAT32 cluster value sentinels (low 28 bits).
const CLUSTER_EOF: u32 = 0x0FFFFFF8;

// ---------------------------------------------------------------------------
// Driver state
// ---------------------------------------------------------------------------
var sectors_per_cluster: u32 = 0;
var reserved_sectors: u32 = 0;
var num_fats: u32 = 0;
var sectors_per_fat: u32 = 0;
var root_cluster: u32 = 0;
var fat_start: u64 = 0; // sector index where FAT1 begins
var data_start: u64 = 0; // sector index where cluster 2 begins

// One-sector read cache. Sector index of cached data, or u64-max if invalid.
var cached_sector: u64 = 0xFFFFFFFFFFFFFFFF;
var sector_buf: [SECTOR_SIZE]u8 = undefined;

// In-memory root-directory index. Keeps lookups O(N) over a tiny N.
const MAX_FILES: usize = 64;
const MAX_NAME_BYTES: usize = 13; // 8 + 1 dot + 3 + null
const DirEntry = struct {
    name: [MAX_NAME_BYTES]u8 = [_]u8{0} ** MAX_NAME_BYTES,
    name_len: u8 = 0,
    start_cluster: u32 = 0,
    size: u32 = 0,
    is_dir: bool = false,
    in_use: bool = false,
};
var root_entries: [MAX_FILES]DirEntry = [_]DirEntry{.{}} ** MAX_FILES;
var root_entry_count: usize = 0;

// ---------------------------------------------------------------------------
// Block-device sector I/O via the BLK chunked protocol
// ---------------------------------------------------------------------------
fn readSector(sector: u64) bool {
    if (cached_sector == sector) return true;

    var off: u32 = 0;
    while (off < SECTOR_SIZE) {
        const want = @min(SECTOR_SIZE - off, @as(u32, blk.MAX_CHUNK));
        var req_buf: [@sizeOf(blk.BlkRequest)]u8 = undefined;
        var reply_buf: [@sizeOf(blk.BlkResponse) + blk.MAX_CHUNK]u8 = undefined;
        const req_len = blk.buildReadRequest(&req_buf, sector, off, want);
        if (req_len == 0) return false;
        const r = blk.callSlot(BLK_SLOT, req_buf[0..req_len], &reply_buf);
        if (r.err != .success) return false;
        const n: u32 = @intCast(r.payload.len);
        if (n == 0) return false;
        for (0..n) |i| sector_buf[off + i] = r.payload[i];
        off += n;
    }

    cached_sector = sector;
    return true;
}

// ---------------------------------------------------------------------------
// Little-endian field readers
// ---------------------------------------------------------------------------
fn rdU16(buf: []const u8, off: usize) u16 {
    return @as(u16, buf[off]) | (@as(u16, buf[off + 1]) << 8);
}
fn rdU32(buf: []const u8, off: usize) u32 {
    return @as(u32, buf[off]) |
        (@as(u32, buf[off + 1]) << 8) |
        (@as(u32, buf[off + 2]) << 16) |
        (@as(u32, buf[off + 3]) << 24);
}

// ---------------------------------------------------------------------------
// Mount: parse BPB, derive layout, index root directory.
// ---------------------------------------------------------------------------
fn mount() bool {
    if (!readSector(0)) {
        _ = syscall.klog("[fatfs] boot sector read failed\n");
        return false;
    }

    const bps = rdU16(&sector_buf, 0x0B);
    if (bps != SECTOR_SIZE) {
        _ = syscall.klog("[fatfs] non-512 sector unsupported\n");
        return false;
    }
    sectors_per_cluster = sector_buf[0x0D];
    reserved_sectors = rdU16(&sector_buf, 0x0E);
    num_fats = sector_buf[0x10];
    sectors_per_fat = rdU32(&sector_buf, 0x24);
    root_cluster = rdU32(&sector_buf, 0x2C);

    if (sectors_per_cluster == 0 or num_fats == 0 or sectors_per_fat == 0 or root_cluster < 2) {
        _ = syscall.klog("[fatfs] bad BPB\n");
        return false;
    }

    fat_start = reserved_sectors;
    data_start = @as(u64, reserved_sectors) + @as(u64, num_fats) * @as(u64, sectors_per_fat);

    return indexRootDirectory();
}

fn clusterFirstSector(cluster: u32) u64 {
    return data_start + (@as(u64, cluster) - 2) * @as(u64, sectors_per_cluster);
}

// Walk the FAT chain — returns the next cluster after `cluster`, or null
// for EOF/free/bad markers.
fn nextCluster(cluster: u32) ?u32 {
    const fat_byte_offset = @as(u64, cluster) * 4;
    const sector = fat_start + (fat_byte_offset / SECTOR_SIZE);
    const offset_in_sector: usize = @intCast(fat_byte_offset % SECTOR_SIZE);
    if (!readSector(sector)) return null;
    const val = rdU32(&sector_buf, offset_in_sector) & 0x0FFFFFFF;
    if (val < 2) return null;
    if (val >= CLUSTER_EOF) return null;
    return val;
}

// ---------------------------------------------------------------------------
// 8.3 name decoding
// ---------------------------------------------------------------------------
// Raw bytes 0..7 = base name, 8..10 = extension. Spaces are padding.
// Output format: "name.ext" (or just "name" if no extension), lower-cased.
fn decode83(raw: []const u8, out: []u8) u8 {
    var len: u8 = 0;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const c = raw[i];
        if (c == ' ') break;
        if (len < out.len) {
            out[len] = if (c >= 'A' and c <= 'Z') c + 32 else c;
            len += 1;
        }
    }
    var has_ext = false;
    i = 8;
    while (i < 11) : (i += 1) {
        if (raw[i] != ' ') {
            has_ext = true;
            break;
        }
    }
    if (has_ext) {
        if (len < out.len) {
            out[len] = '.';
            len += 1;
        }
        i = 8;
        while (i < 11) : (i += 1) {
            const c = raw[i];
            if (c == ' ') break;
            if (len < out.len) {
                out[len] = if (c >= 'A' and c <= 'Z') c + 32 else c;
                len += 1;
            }
        }
    }
    return len;
}

// ---------------------------------------------------------------------------
// Walk the root-directory cluster chain and capture each non-LFN entry.
// ---------------------------------------------------------------------------
fn indexRootDirectory() bool {
    root_entry_count = 0;
    var cluster = root_cluster;

    while (true) {
        const first_sector = clusterFirstSector(cluster);
        var s: u32 = 0;
        while (s < sectors_per_cluster) : (s += 1) {
            if (!readSector(first_sector + s)) return false;

            // Copy the sector into a local buffer — subsequent calls
            // through readSector below would overwrite sector_buf.
            var sec: [SECTOR_SIZE]u8 = undefined;
            for (0..SECTOR_SIZE) |i| sec[i] = sector_buf[i];

            var off: u32 = 0;
            while (off + DIR_ENTRY_SIZE <= SECTOR_SIZE) : (off += DIR_ENTRY_SIZE) {
                const e = sec[off .. off + DIR_ENTRY_SIZE];
                const first = e[0];
                if (first == 0x00) return true; // end of directory
                if (first == 0xE5) continue; // deleted
                const attr = e[0x0B];
                if (attr == ATTR_LFN) continue; // long-filename component
                if ((attr & ATTR_VOLUME_ID) != 0) continue;
                if (root_entry_count >= MAX_FILES) return true;

                var entry: DirEntry = .{};
                entry.in_use = true;
                entry.is_dir = (attr & ATTR_DIRECTORY) != 0;
                entry.name_len = decode83(e[0..11], &entry.name);
                const hi: u32 = rdU16(e, 0x14);
                const lo: u32 = rdU16(e, 0x1A);
                entry.start_cluster = (hi << 16) | lo;
                entry.size = rdU32(e, 0x1C);
                root_entries[root_entry_count] = entry;
                root_entry_count += 1;
            }
        }

        const next = nextCluster(cluster) orelse return true;
        cluster = next;
    }
}

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| if (ac != bc) return false;
    return true;
}

fn findEntry(name: []const u8) ?*const DirEntry {
    var i: usize = 0;
    while (i < root_entry_count) : (i += 1) {
        const e = &root_entries[i];
        if (!e.in_use) continue;
        if (strEql(e.name[0..e.name_len], name)) return e;
    }
    return null;
}

// ---------------------------------------------------------------------------
// File read: walk the FAT chain from start_cluster, skip `offset`, and
// copy up to `count` bytes into `dst`. Returns bytes written.
// ---------------------------------------------------------------------------
fn readFile(start_cluster: u32, file_size: u32, offset: u32, count: u32, dst: []u8) u32 {
    if (offset >= file_size or start_cluster < 2) return 0;
    const cluster_bytes: u32 = sectors_per_cluster * SECTOR_SIZE;
    var remaining: u32 = @min(count, file_size - offset);
    if (remaining > dst.len) remaining = @intCast(dst.len);

    // Skip whole clusters up to `offset`.
    var skip_clusters: u32 = offset / cluster_bytes;
    var byte_in_cluster: u32 = offset % cluster_bytes;
    var cluster = start_cluster;
    while (skip_clusters > 0) : (skip_clusters -= 1) {
        cluster = nextCluster(cluster) orelse return 0;
    }

    var written: u32 = 0;
    while (remaining > 0) {
        const first_sector = clusterFirstSector(cluster);
        const sector_in_cluster = byte_in_cluster / SECTOR_SIZE;
        const byte_in_sector = byte_in_cluster % SECTOR_SIZE;

        var s: u32 = sector_in_cluster;
        while (s < sectors_per_cluster and remaining > 0) : (s += 1) {
            if (!readSector(first_sector + s)) return written;
            const start: u32 = if (s == sector_in_cluster) byte_in_sector else 0;
            const avail: u32 = SECTOR_SIZE - start;
            const take: u32 = @min(remaining, avail);
            for (0..take) |i| dst[written + i] = sector_buf[start + i];
            written += take;
            remaining -= take;
        }

        if (remaining == 0) break;
        cluster = nextCluster(cluster) orelse break;
        byte_in_cluster = 0;
    }

    return written;
}

// ---------------------------------------------------------------------------
// VFS request handler
// ---------------------------------------------------------------------------
fn handleRequest(req_data: []const u8, resp_data: []u8) usize {
    const hdr_sz = @sizeOf(vfs.ResponseHeader);
    const resp: *vfs.ResponseHeader = @ptrCast(@alignCast(resp_data.ptr));
    const resp_payload = resp_data[hdr_sz..];

    if (req_data.len < @sizeOf(vfs.RequestHeader)) {
        resp.* = .{ .error_code = @intFromEnum(vfs.FsError.invalid_arg), .size = 0 };
        return hdr_sz;
    }

    const req: *const vfs.RequestHeader = @ptrCast(@alignCast(req_data.ptr));
    const op: vfs.FsOp = @enumFromInt(req.op);

    var name: []const u8 = &.{};
    if (req.name_len > 0 and req_data.len >= @sizeOf(vfs.RequestHeader) + req.name_len) {
        name = req_data[@sizeOf(vfs.RequestHeader)..][0..req.name_len];
    }

    switch (op) {
        .tty_input => {
            resp.* = .{ .error_code = @intFromEnum(vfs.FsError.invalid_arg), .size = 0 };
            return hdr_sz;
        },
        .ping => {
            resp.* = .{ .error_code = 0, .size = 4 };
            if (resp_payload.len >= 4) {
                resp_payload[0] = 'P';
                resp_payload[1] = 'O';
                resp_payload[2] = 'N';
                resp_payload[3] = 'G';
            }
            return hdr_sz + 4;
        },
        .create, .mkdir, .delete, .write => {
            // Read-only mount.
            resp.* = .{ .error_code = @intFromEnum(vfs.FsError.permission), .size = 0 };
            return hdr_sz;
        },
        .open => {
            const e = findEntry(name) orelse {
                resp.* = .{ .error_code = @intFromEnum(vfs.FsError.not_found), .size = 0 };
                return hdr_sz;
            };
            _ = e;
            resp.* = .{ .error_code = 0, .size = 0 };
            return hdr_sz;
        },
        .close => {
            resp.* = .{ .error_code = 0, .size = 0 };
            return hdr_sz;
        },
        .stat => {
            const e = findEntry(name) orelse {
                resp.* = .{ .error_code = @intFromEnum(vfs.FsError.not_found), .size = 0 };
                return hdr_sz;
            };
            resp.* = .{ .error_code = 0, .size = @sizeOf(vfs.FileStat) };
            if (resp_payload.len >= @sizeOf(vfs.FileStat)) {
                const stat: *vfs.FileStat = @ptrCast(@alignCast(resp_payload.ptr));
                stat.size = e.size;
                stat.file_type = @intFromEnum(if (e.is_dir) vfs.FileType.directory else vfs.FileType.regular);
                stat._pad = .{ 0, 0, 0 };
            }
            return hdr_sz + @sizeOf(vfs.FileStat);
        },
        .read => {
            const e = findEntry(name) orelse {
                resp.* = .{ .error_code = @intFromEnum(vfs.FsError.not_found), .size = 0 };
                return hdr_sz;
            };
            if (e.is_dir) {
                resp.* = .{ .error_code = @intFromEnum(vfs.FsError.is_directory), .size = 0 };
                return hdr_sz;
            }
            const want = @min(req.size, @as(u32, @intCast(resp_payload.len)));
            const got = readFile(e.start_cluster, e.size, req.offset, want, resp_payload);
            resp.* = .{ .error_code = 0, .size = got };
            return hdr_sz + got;
        },
        .readdir => {
            // Only the root directory is exposed.
            var count: i32 = 0;
            var pos: usize = 0;
            var i: usize = 0;
            while (i < root_entry_count) : (i += 1) {
                const e = &root_entries[i];
                if (!e.in_use) continue;
                if (pos + 2 + e.name_len > resp_payload.len) break;
                resp_payload[pos] = e.name_len;
                resp_payload[pos + 1] = @intFromEnum(if (e.is_dir) vfs.FileType.directory else vfs.FileType.regular);
                for (0..e.name_len) |k| resp_payload[pos + 2 + k] = e.name[k];
                pos += 2 + @as(usize, e.name_len);
                count += 1;
            }
            resp.* = .{ .error_code = count, .size = @intCast(pos) };
            return hdr_sz + pos;
        },
    }
}

pub fn main() i32 {
    _ = syscall.klog("[fatfs] starting...\n");

    if (!mount()) {
        _ = syscall.klog("[fatfs] mount failed\n");
        return 1;
    }

    _ = syscall.klog("[fatfs] mounted, root indexed\n");

    var req_buf: [vfs.MAX_MSG_DATA]u8 = undefined;
    var resp_buf: [vfs.MAX_MSG_DATA]u8 = undefined;

    while (true) {
        const recv_len = syscall.capRecv(FATFS_SLOT, &req_buf, req_buf.len);
        if (recv_len < 0) {
            syscall.threadYield();
            continue;
        }
        const req_slice = req_buf[0..@intCast(recv_len)];
        const resp_len = handleRequest(req_slice, &resp_buf);
        _ = syscall.capSend(FATFS_SLOT, &resp_buf, resp_len);
    }

    return 0;
}
