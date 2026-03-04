// renderer Lua API — font management and drawing primitives
// Zig port of api/renderer.c from Lite-XL

const std = @import("std");
const c = @import("../c.zig");
const renderer = @import("../renderer.zig");
const rencache = @import("../rencache.zig");

const lua = c.lua;
const RenFont = renderer.RenFont;
const RenColor = renderer.RenColor;
const RenRect = renderer.RenRect;
const RenTab = renderer.RenTab;
const FONT_FALLBACK_MAX = renderer.FONT_FALLBACK_MAX;

const API_TYPE_FONT = "Font";
const API_TYPE_RENWINDOW = "RenWindow";

var RENDERER_FONT_REF: c_int = lua.LUA_NOREF;

// ── Helpers ──────────────────────────────────────────────────────────────

fn checkcolor(L: ?*lua.lua_State, idx: c_int, default: c_int) RenColor {
    if (lua.lua_isnoneornil(L, idx)) {
        const d: u8 = @intCast(default);
        return .{ .r = d, .g = d, .b = d, .a = 255 };
    }
    lua.luaL_checktype(L, idx, lua.LUA_TTABLE);
    _ = lua.lua_rawgeti(L, idx, 1);
    const r_val: u8 = @intFromFloat(lua.lua_tonumberx(L, -1, null));
    _ = lua.lua_rawgeti(L, idx, 2);
    const g_val: u8 = @intFromFloat(lua.lua_tonumberx(L, -1, null));
    _ = lua.lua_rawgeti(L, idx, 3);
    const b_val: u8 = @intFromFloat(lua.lua_tonumberx(L, -1, null));
    _ = lua.lua_rawgeti(L, idx, 4);
    const a_val: u8 = if (lua.lua_isnoneornil(L, -1)) 255 else @intFromFloat(lua.lua_tonumberx(L, -1, null));
    lua.lua_settop(L, -(4) - 1);
    return .{ .r = r_val, .g = g_val, .b = b_val, .a = a_val };
}

fn rectToGrid(x: f64, y: f64, w: f64, h: f64) RenRect {
    const x1: c_int = @intFromFloat(x + 0.5);
    const y1: c_int = @intFromFloat(y + 0.5);
    const x2: c_int = @intFromFloat(x + w + 0.5);
    const y2: c_int = @intFromFloat(y + h + 0.5);
    return .{ .x = x1, .y = y1, .width = x2 - x1, .height = y2 - y1 };
}

fn fontRetrieve(L: ?*lua.lua_State, fonts: *[FONT_FALLBACK_MAX]?*RenFont, idx: c_int) bool {
    @memset(fonts, null);
    if (lua.lua_type(L, idx) != lua.LUA_TTABLE) {
        const ud = lua.luaL_checkudata(L, idx, API_TYPE_FONT);
        if (ud) |ptr| {
            const font_ptr: *const *RenFont = @ptrCast(@alignCast(ptr));
            fonts[0] = font_ptr.*;
        }
        return false;
    } else {
        var len: c_int = @intCast(lua.luaL_len(L, idx));
        if (len > FONT_FALLBACK_MAX) len = FONT_FALLBACK_MAX;
        for (0..@intCast(len)) |i| {
            _ = lua.lua_rawgeti(L, idx, @intCast(i + 1));
            const ud = lua.luaL_checkudata(L, -1, API_TYPE_FONT);
            if (ud) |ptr| {
                const font_ptr: *const *RenFont = @ptrCast(@alignCast(ptr));
                fonts[i] = font_ptr.*;
            }
            lua.lua_settop(L, -(1) - 1);
        }
        return true;
    }
}

fn fontGetOptions(L: ?*lua.lua_State, antialiasing: *renderer.ERenFontAntialiasing, hinting: *renderer.ERenFontHinting, style: *c_int) c_int {
    if (lua.lua_gettop(L) > 2 and lua.lua_istable(L, 3)) {
        _ = lua.lua_getfield(L, 3, "antialiasing");
        if (lua.lua_isstring(L, -1) != 0) {
            const s = lua.lua_tolstring(L, -1, null);
            if (s != null) {
                const str = std.mem.sliceTo(s, 0);
                if (std.mem.eql(u8, str, "none")) antialiasing.* = .none
                else if (std.mem.eql(u8, str, "grayscale")) antialiasing.* = .grayscale
                else if (std.mem.eql(u8, str, "subpixel")) antialiasing.* = .subpixel;
            }
        }
        _ = lua.lua_getfield(L, 3, "hinting");
        if (lua.lua_isstring(L, -1) != 0) {
            const s = lua.lua_tolstring(L, -1, null);
            if (s != null) {
                const str = std.mem.sliceTo(s, 0);
                if (std.mem.eql(u8, str, "none")) hinting.* = .none
                else if (std.mem.eql(u8, str, "slight")) hinting.* = .slight
                else if (std.mem.eql(u8, str, "full")) hinting.* = .full;
            }
        }
        var style_local: c_int = 0;
        _ = lua.lua_getfield(L, 3, "italic");
        if (lua.lua_toboolean(L, -1) != 0) style_local |= 0x02;
        _ = lua.lua_getfield(L, 3, "bold");
        if (lua.lua_toboolean(L, -1) != 0) style_local |= 0x01;
        _ = lua.lua_getfield(L, 3, "underline");
        if (lua.lua_toboolean(L, -1) != 0) style_local |= 0x04;
        _ = lua.lua_getfield(L, 3, "smoothing");
        if (lua.lua_toboolean(L, -1) != 0) style_local |= 0x08;
        _ = lua.lua_getfield(L, 3, "strikethrough");
        if (lua.lua_toboolean(L, -1) != 0) style_local |= 0x10;
        lua.lua_settop(L, -(5) - 1);
        if (style_local != 0) style.* = style_local;
    }
    return 0;
}

fn checktab(L: ?*lua.lua_State, idx: c_int) RenTab {
    var tab = RenTab{};
    if (lua.lua_isnoneornil(L, idx)) return tab;
    lua.luaL_checktype(L, idx, lua.LUA_TTABLE);
    if (lua.lua_getfield(L, idx, "tab_offset") == lua.LUA_TNIL) return tab;
    tab.offset = lua.luaL_checknumber(L, -1);
    return tab;
}

// ── Font Lua functions ───────────────────────────────────────────────────

fn f_font_load(L: ?*lua.lua_State) callconv(.c) c_int {
    const filename = c.luaCheckString(L, 1);
    const size: f32 = @floatCast(lua.luaL_checknumber(L, 2));
    var style: c_int = 0;
    var hinting: renderer.ERenFontHinting = .slight;
    var antialiasing: renderer.ERenFontAntialiasing = .subpixel;
    _ = fontGetOptions(L, &antialiasing, &hinting, &style);

    const font_ud = lua.lua_newuserdatauv(L, @sizeOf(*RenFont), 0);
    if (font_ud == null) return lua.luaL_error(L, "failed to allocate font userdata");
    const font_ptr: **RenFont = @ptrCast(@alignCast(font_ud));
    const font = renderer.fontLoad(filename, size, antialiasing, hinting, @intCast(style));
    if (font == null) return lua.luaL_error(L, "failed to load font");
    font_ptr.* = font.?;
    _ = lua.luaL_setmetatable(L, API_TYPE_FONT);
    return 1;
}

fn f_font_copy(L: ?*lua.lua_State) callconv(.c) c_int {
    var fonts: [FONT_FALLBACK_MAX]?*RenFont = undefined;
    const table = fontRetrieve(L, &fonts, 1);
    const size: f32 = if (lua.lua_gettop(L) >= 2) @floatCast(lua.luaL_checknumber(L, 2)) else @floatFromInt(renderer.fontGroupGetHeight(&fonts));
    var style: c_int = -1;
    var hinting: renderer.ERenFontHinting = fonts[0].?.hinting;
    var antialiasing: renderer.ERenFontAntialiasing = fonts[0].?.antialiasing;
    _ = fontGetOptions(L, &antialiasing, &hinting, &style);

    if (table) { lua.lua_newtable(L); _ = lua.luaL_setmetatable(L, API_TYPE_FONT); }
    for (0..FONT_FALLBACK_MAX) |i| {
        if (fonts[i]) |f| {
            const font_ud = lua.lua_newuserdatauv(L, @sizeOf(*RenFont), 0);
            if (font_ud == null) return lua.luaL_error(L, "failed to copy font");
            const font_ptr: **RenFont = @ptrCast(@alignCast(font_ud));
            const copy = renderer.fontCopy(f, size, antialiasing, hinting, style);
            if (copy == null) return lua.luaL_error(L, "failed to copy font");
            font_ptr.* = copy.?;
            _ = lua.luaL_setmetatable(L, API_TYPE_FONT);
            if (table) lua.lua_rawseti(L, -2, @intCast(i + 1));
        } else break;
    }
    return 1;
}

fn f_font_group(L: ?*lua.lua_State) callconv(.c) c_int {
    lua.luaL_checktype(L, 1, lua.LUA_TTABLE);
    _ = lua.luaL_setmetatable(L, API_TYPE_FONT);
    return 1;
}

fn f_font_get_path(L: ?*lua.lua_State) callconv(.c) c_int {
    var fonts: [FONT_FALLBACK_MAX]?*RenFont = undefined;
    const table = fontRetrieve(L, &fonts, 1);
    if (table) lua.lua_newtable(L);
    for (0..FONT_FALLBACK_MAX) |i| {
        if (fonts[i]) |f| {
            _ = lua.lua_pushstring(L, renderer.fontGetPath(f));
            if (table) lua.lua_rawseti(L, -2, @intCast(i + 1));
        } else break;
    }
    return 1;
}

fn f_font_set_tab_size(L: ?*lua.lua_State) callconv(.c) c_int {
    var fonts: [FONT_FALLBACK_MAX]?*RenFont = undefined;
    _ = fontRetrieve(L, &fonts, 1);
    renderer.fontGroupSetTabSize(&fonts, @intFromFloat(lua.luaL_checknumber(L, 2)));
    return 0;
}

fn f_font_gc(L: ?*lua.lua_State) callconv(.c) c_int {
    if (lua.lua_istable(L, 1)) return 0;
    const ud = lua.luaL_checkudata(L, 1, API_TYPE_FONT);
    if (ud) |ptr| {
        const font_ptr: **RenFont = @ptrCast(@alignCast(ptr));
        renderer.fontFree(font_ptr.*);
    }
    return 0;
}

fn f_font_get_width(L: ?*lua.lua_State) callconv(.c) c_int {
    var fonts: [FONT_FALLBACK_MAX]?*RenFont = undefined;
    _ = fontRetrieve(L, &fonts, 1);
    var len: usize = 0;
    const text = lua.luaL_checklstring(L, 2, &len);
    lua.lua_pushnumber(L, renderer.fontGroupGetWidth(&fonts, @ptrCast(text), len, checktab(L, 3)));
    return 1;
}

fn f_font_get_height(L: ?*lua.lua_State) callconv(.c) c_int {
    var fonts: [FONT_FALLBACK_MAX]?*RenFont = undefined;
    _ = fontRetrieve(L, &fonts, 1);
    lua.lua_pushnumber(L, @floatFromInt(renderer.fontGroupGetHeight(&fonts)));
    return 1;
}

fn f_font_get_size(L: ?*lua.lua_State) callconv(.c) c_int {
    var fonts: [FONT_FALLBACK_MAX]?*RenFont = undefined;
    _ = fontRetrieve(L, &fonts, 1);
    lua.lua_pushnumber(L, renderer.fontGroupGetSize(&fonts));
    return 1;
}

fn f_font_set_size(L: ?*lua.lua_State) callconv(.c) c_int {
    var fonts: [FONT_FALLBACK_MAX]?*RenFont = undefined;
    _ = fontRetrieve(L, &fonts, 1);
    renderer.fontGroupSetSize(&fonts, @floatCast(lua.luaL_checknumber(L, 2)));
    return 0;
}

// ── Renderer Lua functions ───────────────────────────────────────────────

fn f_show_debug(L: ?*lua.lua_State) callconv(.c) c_int {
    lua.luaL_checkany(L, 1);
    rencache.showDebug(lua.lua_toboolean(L, 1) != 0);
    return 0;
}

fn f_get_size(L: ?*lua.lua_State) callconv(.c) c_int {
    var w: c_int = 0;
    var h: c_int = 0;
    if (renderer.getTargetWindow()) |win| renderer.getSize(win, &w, &h);
    lua.lua_pushnumber(L, @floatFromInt(w));
    lua.lua_pushnumber(L, @floatFromInt(h));
    return 2;
}

fn f_begin_frame(_: ?*lua.lua_State) callconv(.c) c_int {
    // Single-window API: use global target window
    const win = renderer.getTargetWindow() orelse return 0;
    rencache.beginFrame(win);
    return 0;
}

fn f_end_frame(L: ?*lua.lua_State) callconv(.c) c_int {
    const win = renderer.getTargetWindow() orelse return 0;
    rencache.endFrame(win);
    // Clear font reference table for next frame
    lua.lua_newtable(L);
    lua.lua_rawseti(L, lua.LUA_REGISTRYINDEX, RENDERER_FONT_REF);
    return 0;
}

fn f_set_clip_rect(L: ?*lua.lua_State) callconv(.c) c_int {
    const rect = rectToGrid(
        lua.luaL_checknumber(L, 1), lua.luaL_checknumber(L, 2),
        lua.luaL_checknumber(L, 3), lua.luaL_checknumber(L, 4),
    );
    if (renderer.getTargetWindow()) |win| rencache.setClipRectCmd(win, rect);
    return 0;
}

fn f_draw_rect(L: ?*lua.lua_State) callconv(.c) c_int {
    const rect = rectToGrid(
        lua.luaL_checknumber(L, 1), lua.luaL_checknumber(L, 2),
        lua.luaL_checknumber(L, 3), lua.luaL_checknumber(L, 4),
    );
    const color = checkcolor(L, 5, 255);
    if (renderer.getTargetWindow()) |win| rencache.drawRectCmd(win, rect, color);
    return 0;
}

fn f_draw_text(L: ?*lua.lua_State) callconv(.c) c_int {
    var fonts: [FONT_FALLBACK_MAX]?*RenFont = undefined;
    _ = fontRetrieve(L, &fonts, 1);

    var len: usize = 0;
    const text = lua.luaL_checklstring(L, 2, &len);
    const x = lua.luaL_checknumber(L, 3);
    const y: c_int = @intFromFloat(lua.luaL_checknumber(L, 4));
    const color = checkcolor(L, 5, 255);
    const tab = checktab(L, 6);

    var result_x = x;
    if (renderer.getTargetWindow()) |win|
        result_x = rencache.drawTextCmd(win, &fonts, @ptrCast(text), len, x, y, color, tab);
    lua.lua_pushnumber(L, result_x);
    return 1;
}

// ── Module tables ────────────────────────────────────────────────────────

const lib = [_]lua.luaL_Reg{
    .{ .name = "show_debug", .func = f_show_debug },
    .{ .name = "get_size", .func = f_get_size },
    .{ .name = "begin_frame", .func = f_begin_frame },
    .{ .name = "end_frame", .func = f_end_frame },
    .{ .name = "set_clip_rect", .func = f_set_clip_rect },
    .{ .name = "draw_rect", .func = f_draw_rect },
    .{ .name = "draw_text", .func = f_draw_text },
    .{ .name = null, .func = null },
};

const fontLib = [_]lua.luaL_Reg{
    .{ .name = "__gc", .func = f_font_gc },
    .{ .name = "load", .func = f_font_load },
    .{ .name = "copy", .func = f_font_copy },
    .{ .name = "group", .func = f_font_group },
    .{ .name = "set_tab_size", .func = f_font_set_tab_size },
    .{ .name = "get_width", .func = f_font_get_width },
    .{ .name = "get_height", .func = f_font_get_height },
    .{ .name = "get_size", .func = f_font_get_size },
    .{ .name = "set_size", .func = f_font_set_size },
    .{ .name = "get_path", .func = f_font_get_path },
    .{ .name = null, .func = null },
};

pub fn luaopen(L: ?*lua.lua_State) callconv(.c) c_int {
    lua.lua_newtable(L);
    RENDERER_FONT_REF = lua.luaL_ref(L, lua.LUA_REGISTRYINDEX);

    c.luaNewLib(L, &lib);

    _ = lua.luaL_newmetatable(L, API_TYPE_FONT);
    lua.luaL_setfuncs(L, &fontLib, 0);
    lua.lua_pushvalue(L, -1);
    lua.lua_setfield(L, -2, "__index");
    lua.lua_setfield(L, -2, "font");

    return 1;
}
