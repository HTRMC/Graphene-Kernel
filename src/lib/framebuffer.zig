const limine = @import("limine.zig");

var fb_addr: [*]u32 = undefined;
var fb_width: u32 = 0;
var fb_height: u32 = 0;
var fb_pitch: u32 = 0;

pub fn init(fb: *limine.Framebuffer) void {
    fb_addr = @ptrCast(@alignCast(fb.address));
    fb_width = @intCast(fb.width);
    fb_height = @intCast(fb.height);
    fb_pitch = @intCast(fb.pitch / 4); // Convert to pixel pitch
}

pub fn clear(color: u32) void {
    var y: u32 = 0;
    while (y < fb_height) : (y += 1) {
        var x: u32 = 0;
        while (x < fb_width) : (x += 1) {
            putPixel(x, y, color);
        }
    }
}

pub fn putPixel(x: u32, y: u32, color: u32) void {
    if (x >= fb_width or y >= fb_height) return;
    fb_addr[y * fb_pitch + x] = color;
}

// Simple 8x8 bitmap font
const font = @import("font.zig").font;

/// Background color for text (dark blue to match screen clear)
const TEXT_BG: u32 = 0x001a1a2e;

pub fn putChar(c: u8, x: u32, y: u32, color: u32) void {
    if (c < 32 or c > 126) return;
    const glyph = font[c - 32];

    var row: u32 = 0;
    while (row < 8) : (row += 1) {
        var col: u32 = 0;
        while (col < 8) : (col += 1) {
            if ((glyph[row] >> @intCast(7 - col)) & 1 == 1) {
                putPixel(x + col, y + row, color);
            } else {
                putPixel(x + col, y + row, TEXT_BG);
            }
        }
    }
}

pub fn puts(str: []const u8, x: u32, y: u32, color: u32) void {
    var offset: u32 = 0;
    for (str) |c| {
        putChar(c, x + offset * 8, y, color);
        offset += 1;
    }
}
