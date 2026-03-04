// Render cache — dirty rectangle tracking and command buffering
// Zig port of rencache.c from Lite-XL
//
// All drawing operations are stored as commands. At end of frame we hash them
// into a grid, detect changed cells, merge into dirty rectangles and redraw.

const std = @import("std");
const renderer = @import("renderer.zig");
const rw = @import("renwindow.zig");

const RenRect = renderer.RenRect;
const RenColor = renderer.RenColor;
const RenFont = renderer.RenFont;
const RenWindow = renderer.RenWindow;
const RenTab = renderer.RenTab;
const FONT_FALLBACK_MAX = renderer.FONT_FALLBACK_MAX;

// ── Constants ────────────────────────────────────────────────────────────

const CELLS_X = 80;
const CELLS_Y = 50;
const CELL_SIZE = 96;
const CMD_BUF_RESIZE_RATE = 1.2;
const CMD_BUF_INIT_SIZE = 1024 * 512;

const CommandType = enum(u8) { set_clip, draw_text, draw_rect };

const CommandHeader = struct {
    cmd_type: CommandType,
    size: u32,
    rect: RenRect,
};

// ── State ────────────────────────────────────────────────────────────────

var cells_buf1: [CELLS_X * CELLS_Y]u32 = [_]u32{HASH_INITIAL} ** (CELLS_X * CELLS_Y);
var cells_buf2: [CELLS_X * CELLS_Y]u32 = [_]u32{HASH_INITIAL} ** (CELLS_X * CELLS_Y);
var cells_prev: *[CELLS_X * CELLS_Y]u32 = &cells_buf1;
var cells: *[CELLS_X * CELLS_Y]u32 = &cells_buf2;
var rect_buf: [CELLS_X * CELLS_Y / 2]RenRect = undefined;
var resize_issue: bool = false;
var screen_rect: RenRect = .{};
var last_clip_rect: RenRect = .{};
var show_debug: bool = false;

const allocator = std.heap.c_allocator;

// ── Helpers ──────────────────────────────────────────────────────────────

fn cellIdx(x: usize, y: usize) usize {
    return x + y * CELLS_X;
}

fn rectsOverlap(a: RenRect, b: RenRect) bool {
    return b.x + b.width >= a.x and b.x <= a.x + a.width and
        b.y + b.height >= a.y and b.y <= a.y + a.height;
}

fn intersectRects(a: RenRect, b: RenRect) RenRect {
    const x1 = @max(a.x, b.x);
    const y1 = @max(a.y, b.y);
    const x2 = @min(a.x + a.width, b.x + b.width);
    const y2 = @min(a.y + a.height, b.y + b.height);
    return .{ .x = x1, .y = y1, .width = @max(0, x2 - x1), .height = @max(0, y2 - y1) };
}

fn mergeRects(a: RenRect, b: RenRect) RenRect {
    const x1 = @min(a.x, b.x);
    const y1 = @min(a.y, b.y);
    const x2 = @max(a.x + a.width, b.x + b.width);
    const y2 = @max(a.y + a.height, b.y + b.height);
    return .{ .x = x1, .y = y1, .width = x2 - x1, .height = y2 - y1 };
}

// ── FNV-1a hash ──────────────────────────────────────────────────────────

const HASH_INITIAL: u32 = 2166136261;

fn hashData(h: *u32, data: []const u8) void {
    for (data) |byte| {
        h.* = (h.* ^ byte) *% 16777619;
    }
}

// ── Command buffer management ────────────────────────────────────────────

fn expandCommandBuffer(win: *RenWindow) bool {
    const new_size = if (win.command_buf_size == 0)
        CMD_BUF_INIT_SIZE
    else
        @as(usize, @intFromFloat(@as(f64, @floatFromInt(win.command_buf_size)) * CMD_BUF_RESIZE_RATE));

    const new_buf = allocator.alloc(u8, new_size) catch return false;
    if (win.command_buf) |old_buf| {
        @memcpy(new_buf[0..win.command_buf_idx], old_buf[0..win.command_buf_idx]);
        allocator.free(old_buf[0..win.command_buf_size]);
    }
    win.command_buf = new_buf.ptr;
    win.command_buf_size = new_size;
    return true;
}

fn pushCommand(win: *RenWindow, cmd_type: CommandType, rect: RenRect, extra_data: []const u8) void {
    if (resize_issue) return;
    const header_size = @sizeOf(CommandHeader);
    const total_size = header_size + extra_data.len;
    const aligned_size = (total_size + 15) & ~@as(usize, 15);

    while (win.command_buf_idx + aligned_size > win.command_buf_size) {
        if (!expandCommandBuffer(win)) {
            resize_issue = true;
            return;
        }
    }

    const buf = win.command_buf orelse return;
    const header: *CommandHeader = @ptrCast(@alignCast(&buf[win.command_buf_idx]));
    header.cmd_type = cmd_type;
    header.size = @intCast(aligned_size);
    header.rect = rect;

    if (extra_data.len > 0) {
        @memcpy(buf[win.command_buf_idx + header_size .. win.command_buf_idx + header_size + extra_data.len], extra_data);
    }
    win.command_buf_idx += aligned_size;
}

// ── Public API ───────────────────────────────────────────────────────────

pub fn showDebug(enable: bool) void {
    show_debug = enable;
}

pub fn setClipRectCmd(win: *RenWindow, rect: RenRect) void {
    const clipped = intersectRects(rect, screen_rect);
    last_clip_rect = clipped;
    pushCommand(win, .set_clip, clipped, &[0]u8{});
}

pub fn drawRectCmd(win: *RenWindow, rect: RenRect, color: RenColor) void {
    if (rect.width == 0 or rect.height == 0 or !rectsOverlap(last_clip_rect, rect)) return;
    pushCommand(win, .draw_rect, rect, std.mem.asBytes(&color));
}

pub fn drawTextCmd(win: *RenWindow, fonts: [*]?*RenFont, text: [*]const u8, len: usize, x: f64, y: c_int, color: RenColor, tab: RenTab) f64 {
    const width = renderer.fontGroupGetWidth(fonts, text, len, tab);
    const height = renderer.fontGroupGetHeight(fonts);
    const rect = RenRect{
        .x = @intFromFloat(x),
        .y = y,
        .width = @intFromFloat(width),
        .height = height,
    };
    if (rectsOverlap(last_clip_rect, rect)) {
        // Layout: [fonts: FONT_FALLBACK_MAX * ptr_size][color: 4][x: 8][tab_offset: 8][text_len: 8][text bytes]
        const ptr_size = @sizeOf(?*RenFont);
        const fonts_size = FONT_FALLBACK_MAX * ptr_size;
        const fixed_size = fonts_size + @sizeOf(RenColor) + @sizeOf(f64) + @sizeOf(f64) + @sizeOf(usize);
        const extra_total = fixed_size + len;
        var extra_data = allocator.alloc(u8, extra_total) catch return x + width;
        defer allocator.free(extra_data);

        var off: usize = 0;
        // Fonts array
        for (0..FONT_FALLBACK_MAX) |i| {
            @memcpy(extra_data[off .. off + ptr_size], std.mem.asBytes(&fonts[i]));
            off += ptr_size;
        }
        // Color
        @memcpy(extra_data[off .. off + @sizeOf(RenColor)], std.mem.asBytes(&color));
        off += @sizeOf(RenColor);
        // X position
        @memcpy(extra_data[off .. off + @sizeOf(f64)], std.mem.asBytes(&x));
        off += @sizeOf(f64);
        // Tab offset
        @memcpy(extra_data[off .. off + @sizeOf(f64)], std.mem.asBytes(&tab.offset));
        off += @sizeOf(f64);
        // Text length
        @memcpy(extra_data[off .. off + @sizeOf(usize)], std.mem.asBytes(&len));
        off += @sizeOf(usize);
        // Text bytes
        @memcpy(extra_data[off .. off + len], text[0..len]);

        pushCommand(win, .draw_text, rect, extra_data);
    }
    return x + width;
}

pub fn invalidate() void {
    @memset(cells_prev, 0xFF);
}

pub fn beginFrame(win: *RenWindow) void {
    resize_issue = false;
    var w: c_int = 0;
    var h: c_int = 0;
    renderer.getSize(win, &w, &h);
    if (screen_rect.width != w or screen_rect.height != h) {
        screen_rect.width = w;
        screen_rect.height = h;
        invalidate();
    }
    last_clip_rect = screen_rect;
}

fn updateOverlappingCells(r: RenRect, h: u32) void {
    const x1: usize = @intCast(@max(0, @divTrunc(r.x, CELL_SIZE)));
    const y1: usize = @intCast(@max(0, @divTrunc(r.y, CELL_SIZE)));
    const x2: usize = @intCast(@min(CELLS_X - 1, @divTrunc(r.x + r.width, CELL_SIZE)));
    const y2: usize = @intCast(@min(CELLS_Y - 1, @divTrunc(r.y + r.height, CELL_SIZE)));

    for (y1..y2 + 1) |y| {
        for (x1..x2 + 1) |x| {
            const idx = cellIdx(x, y);
            hashData(&cells[idx], std.mem.asBytes(&h));
        }
    }
}

fn pushRect(r: RenRect, count: *usize) void {
    var i: i32 = @as(i32, @intCast(count.*)) - 1;
    while (i >= 0) : (i -= 1) {
        const ui: usize = @intCast(i);
        if (rectsOverlap(rect_buf[ui], r)) {
            rect_buf[ui] = mergeRects(rect_buf[ui], r);
            return;
        }
    }
    rect_buf[count.*] = r;
    count.* += 1;
}

pub fn endFrame(win: *RenWindow) void {
    // Update cells from command buffer by hashing commands
    if (win.command_buf) |buf| {
        var offset: usize = 0;
        var cr = screen_rect;
        while (offset < win.command_buf_idx) {
            const header: *const CommandHeader = @ptrCast(@alignCast(&buf[offset]));
            if (header.cmd_type == .set_clip) cr = header.rect;
            const r = intersectRects(header.rect, cr);
            if (r.width > 0 and r.height > 0) {
                var h: u32 = HASH_INITIAL;
                hashData(&h, buf[offset .. offset + header.size]);
                updateOverlappingCells(r, h);
            }
            offset += header.size;
        }
    }

    // Find changed cells
    var rect_count: usize = 0;
    const max_x: usize = @intCast(@min(CELLS_X, @divTrunc(screen_rect.width, CELL_SIZE) + 1));
    const max_y: usize = @intCast(@min(CELLS_Y, @divTrunc(screen_rect.height, CELL_SIZE) + 1));
    for (0..max_y) |y| {
        for (0..max_x) |x| {
            const idx = cellIdx(x, y);
            if (cells[idx] != cells_prev[idx]) {
                pushRect(.{
                    .x = @intCast(x),
                    .y = @intCast(y),
                    .width = 1,
                    .height = 1,
                }, &rect_count);
            }
            cells_prev[idx] = HASH_INITIAL;
        }
    }

    // Expand rects from cell coords to pixel coords
    for (0..rect_count) |i| {
        rect_buf[i].x *= CELL_SIZE;
        rect_buf[i].y *= CELL_SIZE;
        rect_buf[i].width *= CELL_SIZE;
        rect_buf[i].height *= CELL_SIZE;
        rect_buf[i] = intersectRects(rect_buf[i], screen_rect);
    }

    var rs = rw.getSurface(win);

    // Redraw changed regions
    for (0..rect_count) |i| {
        const r = rect_buf[i];
        renderer.setClipRect(win, r);

        // Replay commands
        if (win.command_buf) |buf| {
            var offset: usize = 0;
            while (offset < win.command_buf_idx) {
                const header: *const CommandHeader = @ptrCast(@alignCast(&buf[offset]));
                switch (header.cmd_type) {
                    .set_clip => renderer.setClipRect(win, intersectRects(header.rect, r)),
                    .draw_rect => {
                        const color_ptr: *const RenColor = @ptrCast(@alignCast(&buf[offset + @sizeOf(CommandHeader)]));
                        renderer.drawRect(&rs, header.rect, color_ptr.*);
                    },
                    .draw_text => {
                        const ptr_size = @sizeOf(?*RenFont);
                        const fonts_size = FONT_FALLBACK_MAX * ptr_size;
                        const extra_base = offset + @sizeOf(CommandHeader);

                        // Decode fonts array (pointers are aligned in the 16-byte-aligned command buffer)
                        var text_fonts: [FONT_FALLBACK_MAX]?*RenFont = undefined;
                        for (0..FONT_FALLBACK_MAX) |fi| {
                            const foff = extra_base + fi * ptr_size;
                            @memcpy(std.mem.asBytes(&text_fonts[fi]), buf[foff .. foff + ptr_size]);
                        }
                        // Read remaining fields with memcpy to avoid alignment issues
                        var doff = extra_base + fonts_size;
                        var text_color: RenColor = undefined;
                        @memcpy(std.mem.asBytes(&text_color), buf[doff .. doff + @sizeOf(RenColor)]);
                        doff += @sizeOf(RenColor);
                        var text_x: f64 = undefined;
                        @memcpy(std.mem.asBytes(&text_x), buf[doff .. doff + @sizeOf(f64)]);
                        doff += @sizeOf(f64);
                        var tab_off: f64 = undefined;
                        @memcpy(std.mem.asBytes(&tab_off), buf[doff .. doff + @sizeOf(f64)]);
                        doff += @sizeOf(f64);
                        var text_len: usize = undefined;
                        @memcpy(std.mem.asBytes(&text_len), buf[doff .. doff + @sizeOf(usize)]);
                        doff += @sizeOf(usize);
                        const text_ptr: [*]const u8 = @ptrCast(&buf[doff]);

                        _ = renderer.drawText(&rs, &text_fonts, text_ptr, text_len, @floatCast(text_x), header.rect.y, text_color, .{ .offset = tab_off });
                    },
                }
                offset += header.size;
            }
        }

        if (show_debug) {
            const debug_color = RenColor{ .r = 100, .g = 100, .b = 255, .a = 50 };
            renderer.drawRect(&rs, r, debug_color);
        }
    }

    // Update dirty rects on screen
    if (rect_count > 0) {
        renderer.updateRects(win, &rect_buf, @intCast(rect_count));
    }

    // Swap cell buffers
    const tmp = cells;
    cells = cells_prev;
    cells_prev = tmp;
    win.command_buf_idx = 0;
}
