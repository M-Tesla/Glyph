// Renderer — FreeType font management, glyph caching, text/rect drawing
// Zig port of renderer.c from Lite-XL

const std = @import("std");
const c = @import("c.zig");
const rw = @import("renwindow.zig");

const SDL = c.SDL;
const ft = c.ft;

pub const RenRect = rw.RenRect;
pub const RenColor = rw.RenColor;
pub const RenSurface = rw.RenSurface;
pub const RenWindow = rw.RenWindow;

// ── Constants ────────────────────────────────────────────────────────────

pub const FONT_FALLBACK_MAX = 10;
const GLYPHS_PER_ATLAS = 96;
const FONT_HEIGHT_OVERFLOW_PX = 0;
const FONT_WIDTH_OVERFLOW_PX = 9;
const MAX_UNICODE = 0x10FFFF;
const CHARMAP_ROW = 128;
const CHARMAP_COL = (MAX_UNICODE + CHARMAP_ROW - 1) / CHARMAP_ROW;
const MAX_GLYPHS = 65535;
const GLYPHMAP_ROW = 128;
const GLYPHMAP_COL = (MAX_GLYPHS + GLYPHMAP_ROW - 1) / GLYPHMAP_ROW;
const SUBPIXEL_BITMAPS_CACHED = 3;

// ── Enums ────────────────────────────────────────────────────────────────

pub const ERenFontHinting = enum(c_int) { none = 0, slight = 1, full = 2 };
pub const ERenFontAntialiasing = enum(c_int) { none = 0, grayscale = 1, subpixel = 2 };

pub const RenTab = struct { offset: f64 = std.math.nan(f64) };

// ── Glyph metric ─────────────────────────────────────────────────────────

const EGlyphFormat = enum(u8) { grayscale = 0, subpixel = 1 };
const EGLYPH_FORMAT_SIZE = 2;

const GlyphMetric = struct {
    xadvance: f32 = 0,
    atlas_idx: u16 = 0,
    surface_idx: u16 = 0,
    bitmap_left: c_int = 0,
    bitmap_top: c_int = 0,
    x1: u32 = 0,
    y0: u32 = 0,
    y1: u32 = 0,
    flags: u16 = 0,
    format: EGlyphFormat = .grayscale,

    const FLAG_XADVANCE: u16 = 1;
    const FLAG_BITMAP: u16 = 2;
};

const GlyphAtlas = struct {
    surfaces: ?[*]*SDL.SDL_Surface = null,
    width: u32 = 0,
    nsurface: u32 = 0,
};

const CharMap = struct {
    rows: [CHARMAP_ROW]?[*]u32 = [_]?[*]u32{null} ** CHARMAP_ROW,
};

const GlyphMap = struct {
    metrics: [SUBPIXEL_BITMAPS_CACHED][GLYPHMAP_ROW]?[*]GlyphMetric =
        [_][GLYPHMAP_ROW]?[*]GlyphMetric{[_]?[*]GlyphMetric{null} ** GLYPHMAP_ROW} ** SUBPIXEL_BITMAPS_CACHED,
    atlas: [EGLYPH_FORMAT_SIZE]?[*]GlyphAtlas = [_]?[*]GlyphAtlas{null} ** EGLYPH_FORMAT_SIZE,
    natlas: [EGLYPH_FORMAT_SIZE]usize = [_]usize{0} ** EGLYPH_FORMAT_SIZE,
    bytesize: usize = 0,
};

// ── Font ─────────────────────────────────────────────────────────────────

pub const RenFont = struct {
    face: ft.FT_Face = null,
    charmap: CharMap = .{},
    glyphs: GlyphMap = .{},
    size: f32 = 0,
    space_advance: f32 = 0,
    baseline: u16 = 0,
    height: u16 = 0,
    tab_size: u16 = 2,
    underline_thickness: u16 = 0,
    antialiasing: ERenFontAntialiasing = .subpixel,
    hinting: ERenFontHinting = .slight,
    style: u8 = 0,
    path: [512]u8 = undefined,
    path_len: usize = 0,
};

// ── Module state ─────────────────────────────────────────────────────────

var library: ft.FT_Library = null;
var draw_rect_surface: ?*SDL.SDL_Surface = null;
var window_list: std.ArrayList(*RenWindow) = undefined;
var target_window: ?*RenWindow = null;
var inited: bool = false;

const allocator = std.heap.c_allocator;

// ── Init / Deinit ────────────────────────────────────────────────────────

pub fn videoInit() c_int {
    const S = struct { var done: bool = false; };
    if (!S.done) {
        if (!SDL.SDL_InitSubSystem(SDL.SDL_INIT_VIDEO)) return -1;
        _ = SDL.SDL_EnableScreenSaver();
        _ = SDL.SDL_SetHint(SDL.SDL_HINT_VIDEO_X11_NET_WM_BYPASS_COMPOSITOR, "0");
        _ = SDL.SDL_SetHint(SDL.SDL_HINT_MOUSE_FOCUS_CLICKTHROUGH, "1");
        _ = SDL.SDL_SetHint(SDL.SDL_HINT_IME_IMPLEMENTED_UI, "1");
        _ = SDL.SDL_SetHint("SDL_BORDERLESS_WINDOWED_STYLE", "1");
        _ = SDL.SDL_SetHint("SDL_BORDERLESS_RESIZABLE_STYLE", "1");
        _ = SDL.SDL_SetHint("SDL_MOUSE_DOUBLE_CLICK_RADIUS", "4");
        _ = SDL.SDL_SetHint(SDL.SDL_HINT_RENDER_DRIVER, "software");
        S.done = true;
    }
    return 0;
}

pub fn init() c_int {
    draw_rect_surface = SDL.SDL_CreateSurface(1, 1, SDL.SDL_PIXELFORMAT_RGBA32);
    if (draw_rect_surface == null) return -1;
    if (ft.FT_Init_FreeType(&library) != 0) return -1;
    window_list = .empty;
    inited = true;
    return 0;
}

pub fn deinit() void {
    if (!inited) return;
    if (draw_rect_surface) |s| { SDL.SDL_DestroySurface(s); draw_rect_surface = null; }
    if (library != null) { _ = ft.FT_Done_FreeType(library); library = null; }
    window_list.deinit(allocator);
    inited = false;
}

// ── Window management ────────────────────────────────────────────────────

pub fn create(win: *SDL.SDL_Window) *RenWindow {
    const ren = allocator.create(RenWindow) catch {
        std.log.err("Failed to allocate RenWindow", .{});
        std.process.exit(1);
    };
    ren.* = RenWindow{ .window = win };
    rw.initSurface(ren);
    rw.initCommandBuf(ren);
    rw.clipToSurface(ren);
    window_list.append(allocator, ren) catch {};
    return ren;
}

pub fn destroy(ren: *RenWindow) void {
    for (window_list.items, 0..) |item, i| {
        if (item == ren) { _ = window_list.orderedRemove(i); break; }
    }
    rw.free(ren);
    if (ren.command_buf) |buf| allocator.free(buf[0..ren.command_buf_size]);
    allocator.destroy(ren);
}

pub fn resizeWindow(ren: *RenWindow) void {
    rw.resizeSurface(ren);
    rw.updateScale(ren);
}

pub fn updateRects(ren: *RenWindow, rects: [*]RenRect, count: c_int) void {
    const S = struct { var initial_frame: bool = true; };
    rw.updateRects(ren, rects, count);
    if (S.initial_frame) { rw.showWindow(ren); S.initial_frame = false; }
}

pub fn setClipRect(ren: *RenWindow, rect: RenRect) void {
    rw.setClipRect(ren, rect);
}

pub fn getSize(ren: *RenWindow, x: *c_int, y: *c_int) void {
    const rs = rw.getSurface(ren);
    x.* = rs.surface.w;
    y.* = rs.surface.h;
}

pub fn getWindowList() []*RenWindow { return window_list.items; }

pub fn findWindow(window: *SDL.SDL_Window) ?*RenWindow {
    for (window_list.items) |ren| { if (ren.window == window) return ren; }
    return null;
}

pub fn findWindowFromId(id: u32) ?*RenWindow {
    const window = SDL.SDL_GetWindowFromID(id) orelse return null;
    return findWindow(window);
}

pub fn getTargetWindow() ?*RenWindow { return target_window; }
pub fn setTargetWindow(window: ?*RenWindow) void { target_window = window; }

// ── UTF-8 decode ─────────────────────────────────────────────────────────

fn utf8ToCp(p: [*]const u8, endp: [*]const u8, dst: *u32) [*]const u8 {
    const b0 = p[0];
    if (b0 < 0x80) { dst.* = b0; return p + 1; }
    if (b0 < 0xC0) { dst.* = b0; return p + 1; }
    if (b0 < 0xE0) {
        var res: u32 = b0 & 0x1F;
        if (@intFromPtr(p + 1) < @intFromPtr(endp)) res = (res << 6) | ((p + 1)[0] & 0x3F);
        dst.* = res; return p + 2;
    }
    if (b0 < 0xF0) {
        var res: u32 = b0 & 0x0F;
        if (@intFromPtr(p + 1) < @intFromPtr(endp)) res = (res << 6) | ((p + 1)[0] & 0x3F);
        if (@intFromPtr(p + 2) < @intFromPtr(endp)) res = (res << 6) | ((p + 2)[0] & 0x3F);
        dst.* = res; return p + 3;
    }
    var res: u32 = b0 & 0x07;
    if (@intFromPtr(p + 1) < @intFromPtr(endp)) res = (res << 6) | ((p + 1)[0] & 0x3F);
    if (@intFromPtr(p + 2) < @intFromPtr(endp)) res = (res << 6) | ((p + 2)[0] & 0x3F);
    if (@intFromPtr(p + 3) < @intFromPtr(endp)) res = (res << 6) | ((p + 3)[0] & 0x3F);
    dst.* = res; return p + 4;
}

fn isWhitespace(cp: u32) bool {
    return switch (cp) {
        0x20, 0x85, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        0x9...0xD => true,
        0x2000...0x200A => true,
        else => false,
    };
}

// ── Font internals ───────────────────────────────────────────────────────

fn fontSetLoadOptions(font: *RenFont) c_int {
    const load_target: c_int = if (font.antialiasing == .none)
        ft.FT_LOAD_TARGET_MONO
    else if (font.hinting == .slight)
        ft.FT_LOAD_TARGET_LIGHT
    else
        ft.FT_LOAD_TARGET_NORMAL;
    const hinting_flag: c_int = if (font.hinting == .none) ft.FT_LOAD_NO_HINTING else ft.FT_LOAD_FORCE_AUTOHINT;
    return load_target | hinting_flag;
}

fn fontSetRenderOptions(font: *RenFont) c_int {
    if (font.antialiasing == .none) return ft.FT_RENDER_MODE_MONO;
    if (font.antialiasing == .subpixel) {
        var weights = [_]u8{ 0x10, 0x40, 0x70, 0x40, 0x10 };
        switch (font.hinting) {
            .none => {},
            .slight, .full => _ = ft.FT_Library_SetLcdFilterWeights(library, &weights),
        }
        return ft.FT_RENDER_MODE_LCD;
    }
    return switch (font.hinting) {
        .none => ft.FT_RENDER_MODE_NORMAL,
        .slight, .full => ft.FT_RENDER_MODE_LIGHT,
    };
}

fn fontSetFaceMetrics(font: *RenFont, face: ft.FT_Face) c_int {
    const pixel_size: c_int = @intFromFloat(font.size);
    const err = ft.FT_Set_Pixel_Sizes(face, 0, @intCast(pixel_size));
    if (err != 0) return err;

    font.face = face;
    if (face.*.face_flags & ft.FT_FACE_FLAG_SCALABLE != 0) {
        const upm: f32 = @floatFromInt(face.*.units_per_EM);
        font.height = @intFromFloat(@as(f32, @floatFromInt(face.*.height)) / upm * font.size);
        font.baseline = @intFromFloat(@as(f32, @floatFromInt(face.*.ascender)) / upm * font.size);
        font.underline_thickness = @intFromFloat(@as(f32, @floatFromInt(face.*.underline_thickness)) / upm * font.size);
    } else {
        font.height = @intFromFloat(@as(f32, @floatFromInt(face.*.size.*.metrics.height)) / 64.0);
        font.baseline = @intFromFloat(@as(f32, @floatFromInt(face.*.size.*.metrics.ascender)) / 64.0);
    }
    if (font.underline_thickness == 0)
        font.underline_thickness = @intFromFloat(@ceil(@as(f64, @floatFromInt(font.height)) / 14.0));

    const load_opts: c_int = (fontSetLoadOptions(font) | ft.FT_LOAD_BITMAP_METRICS_ONLY | ft.FT_LOAD_NO_HINTING) & ~@as(c_int, ft.FT_LOAD_FORCE_AUTOHINT);
    const err2 = ft.FT_Load_Char(face, ' ', load_opts);
    if (err2 != 0) return err2;
    font.space_advance = @as(f32, @floatFromInt(face.*.glyph.*.advance.x)) / 64.0;
    return 0;
}

fn fontSetStyle(outline: *ft.FT_Outline, x_translation: c_int, style: u8) c_int {
    ft.FT_Outline_Translate(outline, x_translation, 0);
    if (style & 0x08 != 0) _ = ft.FT_Outline_Embolden(outline, 1 << 5);
    if (style & 0x01 != 0) _ = ft.FT_Outline_EmboldenXY(outline, 1 << 5, 0);
    if (style & 0x02 != 0) {
        var matrix = ft.FT_Matrix{ .xx = 1 << 16, .xy = 1 << 14, .yx = 0, .yy = 1 << 16 };
        ft.FT_Outline_Transform(outline, &matrix);
    }
    return 0;
}

fn fontGetGlyphId(font: *RenFont, codepoint: u32) u32 {
    if (codepoint > MAX_UNICODE) return 0;
    const row = codepoint / CHARMAP_COL;
    const col = codepoint - (row * CHARMAP_COL);
    if (font.charmap.rows[row] == null) {
        font.charmap.rows[row] = (allocator.alloc(u32, CHARMAP_COL) catch return 0).ptr;
        @memset(font.charmap.rows[row].?[0..CHARMAP_COL], 0);
    }
    const row_ptr = font.charmap.rows[row].?;
    if (row_ptr[col] == 0) {
        const glyph_id = ft.FT_Get_Char_Index(font.face, codepoint);
        row_ptr[col] = if (glyph_id != 0) glyph_id else 0xFFFFFFFF;
    }
    return if (row_ptr[col] == 0xFFFFFFFF) 0 else row_ptr[col];
}

fn fontLoadGlyphMetric(font: *RenFont, glyph_id: u32, bitmap_idx: u32) ?*GlyphMetric {
    const load_option = fontSetLoadOptions(font);
    const row = glyph_id / GLYPHMAP_COL;
    const col = glyph_id - (row * GLYPHMAP_COL);
    const bitmaps: u32 = if (font.antialiasing == .subpixel) SUBPIXEL_BITMAPS_CACHED else 1;

    if (font.glyphs.metrics[0][row] == null or (font.glyphs.metrics[0][row].?[col].flags & GlyphMetric.FLAG_XADVANCE) == 0) {
        const load_flags: c_int = (load_option | ft.FT_LOAD_BITMAP_METRICS_ONLY | ft.FT_LOAD_NO_HINTING) & ~@as(c_int, ft.FT_LOAD_FORCE_AUTOHINT);
        if (ft.FT_Load_Glyph(font.face, glyph_id, load_flags) != 0) return null;
        for (0..bitmaps) |i| {
            if (font.glyphs.metrics[i][row] == null) {
                font.glyphs.metrics[i][row] = (allocator.alloc(GlyphMetric, GLYPHMAP_COL) catch return null).ptr;
                @memset(font.glyphs.metrics[i][row].?[0..GLYPHMAP_COL], GlyphMetric{});
                font.glyphs.bytesize += @sizeOf(GlyphMetric) * GLYPHMAP_COL;
            }
            const metric = &font.glyphs.metrics[i][row].?[col];
            metric.flags |= GlyphMetric.FLAG_XADVANCE;
            metric.xadvance = @as(f32, @floatFromInt(font.face.*.glyph.*.advance.x)) / 64.0;
        }
    }
    return &font.glyphs.metrics[bitmap_idx][row].?[col];
}

fn fontAllocateGlyphSurface(font: *RenFont, slot: ft.FT_GlyphSlot, metric: *GlyphMetric) ?*SDL.SDL_Surface {
    const glyph_format: usize = @intFromEnum(metric.format);

    var atlas_idx_opt: ?usize = null;
    if (font.glyphs.atlas[glyph_format]) |atlas_arr| {
        for (0..font.glyphs.natlas[glyph_format]) |i| {
            if (atlas_arr[i].width >= metric.x1) { atlas_idx_opt = i; break; }
        }
    }
    if (atlas_idx_opt == null) {
        const new_natlas = font.glyphs.natlas[glyph_format] + 1;
        const new_arr = allocator.alloc(GlyphAtlas, new_natlas) catch return null;
        if (font.glyphs.atlas[glyph_format]) |old_arr| {
            @memcpy(new_arr[0 .. new_natlas - 1], old_arr[0 .. new_natlas - 1]);
            allocator.free(old_arr[0 .. new_natlas - 1]);
        }
        new_arr[new_natlas - 1] = GlyphAtlas{ .width = metric.x1 + FONT_WIDTH_OVERFLOW_PX };
        font.glyphs.atlas[glyph_format] = new_arr.ptr;
        atlas_idx_opt = new_natlas - 1;
        font.glyphs.natlas[glyph_format] = new_natlas;
    }
    const atlas_idx = atlas_idx_opt.?;
    metric.atlas_idx = @intCast(atlas_idx);
    const atlas = &font.glyphs.atlas[glyph_format].?[atlas_idx];

    var surface_idx_opt: ?usize = null;
    if (atlas.surfaces) |surfaces| {
        var min_waste: i32 = std.math.maxInt(i32);
        var i: i32 = @as(i32, @intCast(atlas.nsurface)) - 1;
        while (i >= 0) : (i -= 1) {
            const ui: usize = @intCast(i);
            const sh: i32 = surfaces[ui].h;
            const props = SDL.SDL_GetSurfaceProperties(surfaces[ui]);
            const m_ptr = SDL.SDL_GetPointerProperty(props, "metric", null);
            if (m_ptr) |mp| {
                const m: *GlyphMetric = @ptrCast(@alignCast(mp));
                const new_waste: i32 = sh - @as(i32, @intCast(m.y1));
                if (new_waste >= @as(i32, @intCast(metric.y1)) and new_waste < min_waste) {
                    surface_idx_opt = ui;
                    min_waste = new_waste;
                }
            }
        }
    }

    if (surface_idx_opt == null) {
        var h: i32 = @intFromFloat(@as(f64, @floatFromInt(font.face.*.size.*.metrics.height)) / 64.0);
        h += FONT_HEIGHT_OVERFLOW_PX;
        if (h <= FONT_HEIGHT_OVERFLOW_PX) h += @intCast(slot.*.bitmap.rows);
        if (h <= FONT_HEIGHT_OVERFLOW_PX) h += @intFromFloat(font.size);
        const format: SDL.SDL_PixelFormat = if (metric.format == .subpixel) SDL.SDL_PIXELFORMAT_RGB24 else SDL.SDL_PIXELFORMAT_INDEX8;
        const new_nsurface = atlas.nsurface + 1;
        const new_surfaces = allocator.alloc(*SDL.SDL_Surface, new_nsurface) catch return null;
        if (atlas.surfaces) |old_surfaces| {
            @memcpy(new_surfaces[0 .. new_nsurface - 1], old_surfaces[0 .. new_nsurface - 1]);
            allocator.free(old_surfaces[0 .. new_nsurface - 1]);
        }
        const new_surf = SDL.SDL_CreateSurface(@intCast(atlas.width), GLYPHS_PER_ATLAS * h, format) orelse return null;
        new_surfaces[new_nsurface - 1] = new_surf;
        atlas.surfaces = new_surfaces.ptr;
        const props = SDL.SDL_GetSurfaceProperties(new_surf);
        _ = SDL.SDL_SetPointerProperty(props, "metric", null);
        surface_idx_opt = new_nsurface - 1;
        atlas.nsurface = @intCast(new_nsurface);
    }

    const surface_idx = surface_idx_opt.?;
    metric.surface_idx = @intCast(surface_idx);
    const surface = atlas.surfaces.?[surface_idx];
    const props = SDL.SDL_GetSurfaceProperties(surface);
    const m_ptr = SDL.SDL_GetPointerProperty(props, "metric", null);
    if (m_ptr) |mp| {
        const last_metric: *GlyphMetric = @ptrCast(@alignCast(mp));
        metric.y0 = last_metric.y1;
        metric.y1 += last_metric.y1;
    }
    _ = SDL.SDL_SetPointerProperty(props, "metric", @ptrCast(metric));
    return surface;
}

fn fontLoadGlyphBitmap(font: *RenFont, glyph_id: u32, bitmap_idx: u32) ?*SDL.SDL_Surface {
    const metric = fontLoadGlyphMetric(font, glyph_id, bitmap_idx) orelse return null;
    if (metric.flags & GlyphMetric.FLAG_BITMAP != 0) {
        const gf: usize = @intFromEnum(metric.format);
        if (font.glyphs.atlas[gf]) |atlas_arr| return atlas_arr[metric.atlas_idx].surfaces.?[metric.surface_idx];
        return null;
    }

    const load_option: c_int = fontSetLoadOptions(font) | ft.FT_LOAD_BITMAP_METRICS_ONLY;
    const render_option: u32 = @intCast(fontSetRenderOptions(font));
    const slot = font.face.*.glyph;

    if (ft.FT_Load_Glyph(font.face, glyph_id, load_option) != 0) return null;
    _ = fontSetStyle(&slot.*.outline, @intCast(bitmap_idx * (64 / SUBPIXEL_BITMAPS_CACHED)), font.style);
    if (ft.FT_Render_Glyph(slot, render_option) != 0) return null;

    if (slot.*.bitmap.width == 0 or slot.*.bitmap.rows == 0 or slot.*.bitmap.buffer == null) return null;

    const bitmaps: u32 = if (font.antialiasing == .subpixel) SUBPIXEL_BITMAPS_CACHED else 1;
    var glyph_width = slot.*.bitmap.width / bitmaps;
    if (slot.*.bitmap.pixel_mode == ft.FT_PIXEL_MODE_MONO) glyph_width *= 8;

    metric.x1 = glyph_width;
    metric.y1 = slot.*.bitmap.rows;
    metric.bitmap_left = slot.*.bitmap_left;
    metric.bitmap_top = slot.*.bitmap_top;
    metric.flags |= GlyphMetric.FLAG_BITMAP;
    metric.format = if (slot.*.bitmap.pixel_mode == ft.FT_PIXEL_MODE_LCD) .subpixel else .grayscale;

    const surface = fontAllocateGlyphSurface(font, slot, metric) orelse return null;
    const pixels: [*]u8 = @ptrCast(surface.pixels);
    const bitmap_buf: [*]const u8 = @ptrCast(slot.*.bitmap.buffer);

    for (0..slot.*.bitmap.rows) |line| {
        const target_offset: usize = @intCast(@as(i64, surface.pitch) * @as(i64, @intCast(line + metric.y0)));
        const source_offset: usize = line * @as(usize, @intCast(slot.*.bitmap.pitch));
        if (font.antialiasing == .none) {
            for (0..slot.*.bitmap.width) |column| {
                const source_pixel = bitmap_buf[source_offset + column / 8];
                pixels[target_offset + column] = if ((source_pixel >> @intCast(7 - (column % 8))) & 0x1 != 0) 0xFF else 0;
            }
        } else {
            @memcpy(pixels[target_offset .. target_offset + slot.*.bitmap.width], bitmap_buf[source_offset .. source_offset + slot.*.bitmap.width]);
        }
    }
    return surface;
}

fn fontClearGlyphCache(font: *RenFont) void {
    for (0..EGLYPH_FORMAT_SIZE) |gfi| {
        const natlas = font.glyphs.natlas[gfi];
        if (font.glyphs.atlas[gfi]) |atlas_arr| {
            for (0..natlas) |ai| {
                const atl = &atlas_arr[ai];
                if (atl.surfaces) |surfaces| {
                    for (0..atl.nsurface) |si| SDL.SDL_DestroySurface(surfaces[si]);
                    allocator.free(surfaces[0..atl.nsurface]);
                }
            }
            allocator.free(atlas_arr[0..natlas]);
        }
        font.glyphs.atlas[gfi] = null;
        font.glyphs.natlas[gfi] = 0;
    }
    const bitmaps: usize = if (font.antialiasing == .subpixel) SUBPIXEL_BITMAPS_CACHED else 1;
    for (0..bitmaps) |spi| {
        for (0..GLYPHMAP_ROW) |gr| {
            if (font.glyphs.metrics[spi][gr]) |ptr| {
                allocator.free(ptr[0..GLYPHMAP_COL]);
                font.glyphs.metrics[spi][gr] = null;
            }
        }
    }
    font.glyphs.bytesize = 0;
}

// ── Font public API ──────────────────────────────────────────────────────

pub fn fontLoad(path_ptr: [*:0]const u8, size: f32, antialiasing: ERenFontAntialiasing, hinting: ERenFontHinting, style: u8) ?*RenFont {
    var face: ft.FT_Face = null;
    if (ft.FT_New_Face(library, path_ptr, 0, &face) != 0) return null;

    var font = allocator.create(RenFont) catch return null;
    font.* = RenFont{};
    font.size = size;
    font.antialiasing = antialiasing;
    font.hinting = hinting;
    font.style = style;
    font.tab_size = 2;

    const path_slice = std.mem.sliceTo(path_ptr, 0);
    const copy_len = @min(path_slice.len, font.path.len - 1);
    @memcpy(font.path[0..copy_len], path_slice[0..copy_len]);
    font.path[copy_len] = 0;
    font.path_len = copy_len;

    if (fontSetFaceMetrics(font, face) != 0) {
        if (face != null) _ = ft.FT_Done_Face(face);
        allocator.destroy(font);
        return null;
    }
    return font;
}

pub fn fontCopy(src: *RenFont, size: f32, antialiasing: ERenFontAntialiasing, hinting: ERenFontHinting, style_in: c_int) ?*RenFont {
    const aa = if (@as(c_int, @intFromEnum(antialiasing)) == -1) src.antialiasing else antialiasing;
    const h = if (@as(c_int, @intFromEnum(hinting)) == -1) src.hinting else hinting;
    const s: u8 = if (style_in == -1) src.style else @intCast(@as(u32, @bitCast(style_in)));
    return fontLoad(@ptrCast(&src.path), size, aa, h, s);
}

pub fn fontGetPath(font: *RenFont) [*:0]const u8 {
    return @ptrCast(&font.path);
}

pub fn fontFree(font: *RenFont) void {
    fontClearGlyphCache(font);
    for (&font.charmap.rows) |*row| {
        if (row.*) |ptr| { allocator.free(ptr[0..CHARMAP_COL]); row.* = null; }
    }
    if (font.face != null) _ = ft.FT_Done_Face(font.face);
    allocator.destroy(font);
}

// ── Font group operations ────────────────────────────────────────────────

fn fontGroupGetGlyph(fonts: [*]?*RenFont, codepoint: u32, subpixel_idx_in: i32, surface_out: ?*?*SDL.SDL_Surface, metric_out: ?*?*GlyphMetric) ?*RenFont {
    var subpixel_idx: u32 = if (subpixel_idx_in < 0) @intCast(@as(i32, subpixel_idx_in) + SUBPIXEL_BITMAPS_CACHED) else @intCast(subpixel_idx_in);
    var font: ?*RenFont = null;
    var glyph_id: u32 = 0;

    for (0..FONT_FALLBACK_MAX) |i| {
        if (fonts[i]) |f| {
            font = f;
            glyph_id = fontGetGlyphId(f, codepoint);
            if (glyph_id != 0 or isWhitespace(codepoint)) break;
        } else break;
    }
    if (font == null) return null;
    const f = font.?;

    if (f.antialiasing != .subpixel) subpixel_idx = 0;
    const m = fontLoadGlyphMetric(f, glyph_id, subpixel_idx);
    if ((m == null or (m != null and m.?.flags == 0)) and codepoint != 0x25A1 and !isWhitespace(codepoint))
        return fontGroupGetGlyph(fonts, 0x25A1, @intCast(subpixel_idx), surface_out, metric_out);

    if (metric_out) |mo| mo.* = m;
    if (surface_out) |so| { if (m != null) so.* = fontLoadGlyphBitmap(f, glyph_id, subpixel_idx); }
    return f;
}

fn fontGetXadvance(font: *RenFont, codepoint: u32, metric: ?*GlyphMetric, curr_x: f64, tab: RenTab) f32 {
    if (!isWhitespace(codepoint)) {
        if (metric) |m| { if (m.xadvance != 0) return m.xadvance; }
    }
    if (codepoint != '\t') return font.space_advance;
    const tab_size: f64 = @as(f64, font.space_advance) * @as(f64, @floatFromInt(font.tab_size));
    if (std.math.isNan(tab.offset)) return @floatCast(tab_size);
    const offset = @mod(curr_x + tab.offset, tab_size);
    var adv: f64 = tab_size - offset;
    if (adv < font.space_advance) adv += tab_size;
    return @floatCast(adv);
}

pub fn fontGroupSetTabSize(fonts: [*]?*RenFont, n: c_int) void {
    for (0..FONT_FALLBACK_MAX) |j| { if (fonts[j]) |f| { f.tab_size = @intCast(n); } else break; }
}

pub fn fontGroupGetTabSize(fonts: [*]?*RenFont) c_int {
    return if (fonts[0]) |f| @intCast(f.tab_size) else 2;
}

pub fn fontGroupGetSize(fonts: [*]?*RenFont) f32 {
    return if (fonts[0]) |f| f.size else 0;
}

pub fn fontGroupSetSize(fonts: [*]?*RenFont, size: f32) void {
    for (0..FONT_FALLBACK_MAX) |i| {
        if (fonts[i]) |f| {
            fontClearGlyphCache(f);
            f.size = size;
            f.tab_size = 2;
            _ = fontSetFaceMetrics(f, f.face);
        } else break;
    }
}

pub fn fontGroupGetHeight(fonts: [*]?*RenFont) c_int {
    return if (fonts[0]) |f| @intCast(f.height) else 0;
}

pub fn fontGroupGetWidth(fonts: [*]?*RenFont, text: [*]const u8, len: usize, tab: RenTab) f64 {
    var width: f64 = 0;
    var ptr = text;
    const endp = text + len;
    while (@intFromPtr(ptr) < @intFromPtr(endp)) {
        var codepoint: u32 = 0;
        ptr = utf8ToCp(ptr, endp, &codepoint);
        var metric: ?*GlyphMetric = null;
        _ = fontGroupGetGlyph(fonts, codepoint, 0, null, &metric);
        width += fontGetXadvance(fonts[0].?, codepoint, metric, width, tab);
    }
    return width;
}

// ── Draw text ────────────────────────────────────────────────────────────

pub fn drawText(rs: *RenSurface, fonts: [*]?*RenFont, text: [*]const u8, len: usize, x: f32, y_in: c_int, color: RenColor, tab: RenTab) f64 {
    const surface = rs.surface;
    var clip: SDL.SDL_Rect = undefined;
    _ = SDL.SDL_GetSurfaceClipRect(surface, &clip);

    const surface_scale: c_int = rs.scale;
    var pen_x: f64 = @as(f64, x) * @as(f64, @floatFromInt(surface_scale));
    const original_pen_x = pen_x;
    const y: c_int = y_in * surface_scale;
    var ptr = text;
    const endp = text + len;
    const destination_pixels: [*]u8 = @ptrCast(surface.pixels);
    const clip_end_x: c_int = clip.x + clip.w;
    const clip_end_y: c_int = clip.y + clip.h;

    while (@intFromPtr(ptr) < @intFromPtr(endp)) {
        var codepoint: u32 = 0;
        ptr = utf8ToCp(ptr, endp, &codepoint);
        var font_surface: ?*SDL.SDL_Surface = null;
        var metric: ?*GlyphMetric = null;
        _ = fontGroupGetGlyph(fonts, codepoint, @intFromFloat(@mod(pen_x, 1.0) * SUBPIXEL_BITMAPS_CACHED), &font_surface, &metric);
        if (metric == null) break;
        const m = metric.?;

        const start_x_f: i64 = @intFromFloat(@floor(pen_x));
        const start_x: c_int = @intCast(start_x_f + m.bitmap_left);
        const glyph_start: u32 = 0;
        const glyph_end: u32 = m.x1;
        const end_x: c_int = @as(c_int, @intCast(m.x1)) + start_x;

        if (!isWhitespace(codepoint) and font_surface != null and color.a > 0 and end_x >= clip.x and start_x < clip_end_x) {
            const source_pixels: [*]const u8 = @ptrCast(font_surface.?.pixels);
            const font_surf = font_surface.?;
            const surface_format = SDL.SDL_GetPixelFormatDetails(surface.format);
            const font_surface_format = SDL.SDL_GetPixelFormatDetails(font_surf.format);

            if (surface_format != null and font_surface_format != null) {
                const sf = surface_format.?[0];
                const ff = font_surface_format.?[0];

                for (m.y0..m.y1) |line| {
                    const target_y: c_int = @intCast(@as(i64, @intCast(line)) - @as(i64, m.y0) + y - m.bitmap_top + @as(i64, fonts[0].?.baseline) * surface_scale);
                    if (target_y < clip.y) continue;
                    if (target_y >= clip_end_y) break;

                    // Reset per-line clipping
                    var line_start_x = start_x;
                    var line_glyph_start = glyph_start;
                    var line_glyph_end = glyph_end;

                    if (line_start_x + @as(c_int, @intCast(line_glyph_end - line_glyph_start)) >= clip_end_x)
                        line_glyph_end = line_glyph_start + @as(u32, @intCast(clip_end_x - line_start_x));
                    if (line_start_x < clip.x) {
                        const offset_val: c_int = clip.x - line_start_x;
                        line_start_x += offset_val;
                        line_glyph_start += @intCast(offset_val);
                    }

                    const dest_offset: usize = @intCast(@as(i64, surface.pitch) * target_y + @as(i64, line_start_x) * sf.bytes_per_pixel);
                    var dest_ptr: [*]u32 = @ptrCast(@alignCast(&destination_pixels[dest_offset]));
                    const src_offset: usize = line * @as(usize, @intCast(font_surf.pitch)) + line_glyph_start * @as(usize, @intCast(ff.bytes_per_pixel));
                    var src_ptr: [*]const u8 = @ptrCast(&source_pixels[src_offset]);

                    var gx: u32 = line_glyph_start;
                    while (gx < line_glyph_end) : (gx += 1) {
                        const dest_color = dest_ptr[0];
                        const dst_r: u32 = (dest_color & sf.Rmask) >> @intCast(sf.Rshift);
                        const dst_g: u32 = (dest_color & sf.Gmask) >> @intCast(sf.Gshift);
                        const dst_b: u32 = (dest_color & sf.Bmask) >> @intCast(sf.Bshift);
                        const dst_a: u32 = (dest_color & sf.Amask) >> @intCast(sf.Ashift);

                        var src_r: u32 = undefined;
                        var src_g: u32 = undefined;
                        if (m.format == .subpixel) {
                            src_r = src_ptr[0]; src_g = src_ptr[1]; src_ptr += 2;
                        } else {
                            src_r = src_ptr[0]; src_g = src_ptr[0];
                        }
                        const src_b: u32 = src_ptr[0]; src_ptr += 1;

                        const r = (color.r * src_r * color.a + dst_r * (65025 - src_r * color.a) + 32767) / 65025;
                        const g = (color.g * src_g * color.a + dst_g * (65025 - src_g * color.a) + 32767) / 65025;
                        const b = (color.b * src_b * color.a + dst_b * (65025 - src_b * color.a) + 32767) / 65025;

                        dest_ptr[0] = (dst_a << @intCast(sf.Ashift)) | (r << @intCast(sf.Rshift)) | (g << @intCast(sf.Gshift)) | (b << @intCast(sf.Bshift));
                        dest_ptr += 1;
                    }
                }
            }
        }

        const adv = fontGetXadvance(fonts[0].?, codepoint, metric, pen_x - original_pen_x, tab);
        pen_x += adv;
    }
    return pen_x / @as(f64, @floatFromInt(surface_scale));
}

// ── Draw rect ────────────────────────────────────────────────────────────

pub fn drawRect(rs: *RenSurface, rect: RenRect, color: RenColor) void {
    if (color.a == 0) return;
    const surface = rs.surface;
    const surface_scale = rs.scale;

    var dest_rect = SDL.SDL_Rect{
        .x = rect.x * surface_scale, .y = rect.y * surface_scale,
        .w = rect.width * surface_scale, .h = rect.height * surface_scale,
    };

    if (color.a == 0xFF) {
        const translated = SDL.SDL_MapSurfaceRGB(surface, color.r, color.g, color.b);
        _ = SDL.SDL_FillSurfaceRect(surface, &dest_rect, translated);
    } else {
        var clip_rect: SDL.SDL_Rect = undefined;
        _ = SDL.SDL_GetSurfaceClipRect(surface, &clip_rect);
        if (!SDL.SDL_GetRectIntersection(&clip_rect, &dest_rect, &dest_rect)) return;
        if (draw_rect_surface) |drs| {
            const pixel: *u32 = @ptrCast(@alignCast(drs.pixels));
            pixel.* = SDL.SDL_MapSurfaceRGBA(drs, color.r, color.g, color.b, color.a);
            _ = SDL.SDL_BlitSurfaceScaled(drs, null, surface, &dest_rect, SDL.SDL_SCALEMODE_LINEAR);
        }
    }
}
