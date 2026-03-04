// renwindow Lua API — window creation and management
// Zig port of api/renwindow.c from Lite-XL

const c = @import("../c.zig");
const renderer = @import("../renderer.zig");
const rw = @import("../renwindow.zig");

const lua = c.lua;
const SDL = c.SDL;
const RenWindow = renderer.RenWindow;

const API_TYPE_RENWINDOW = "RenWindow";

var persistent_window: ?*RenWindow = null;

fn checkRenWindow(L: ?*lua.lua_State, idx: c_int) ?*RenWindow {
    const ud = lua.luaL_checkudata(L, idx, API_TYPE_RENWINDOW);
    if (ud == null) return null;
    const ptr: *const *RenWindow = @ptrCast(@alignCast(ud));
    return ptr.*;
}

fn f_renwin_create(L: ?*lua.lua_State) callconv(.c) c_int {
    const title = c.luaCheckString(L, 1);
    var width: f32 = @floatCast(lua.luaL_optnumber(L, 2, 0));
    var height: f32 = @floatCast(lua.luaL_optnumber(L, 3, 0));

    if (renderer.videoInit() != 0)
        return lua.luaL_error(L, "Error creating glyph window: %s", SDL.SDL_GetError());

    if (width < 1 or height < 1) {
        const display = SDL.SDL_GetPrimaryDisplay();
        const dm = SDL.SDL_GetCurrentDisplayMode(display);
        if (dm != null) {
            if (width < 1) width = @as(f32, @floatFromInt(dm.*.w)) * 0.8;
            if (height < 1) height = @as(f32, @floatFromInt(dm.*.h)) * 0.8;
        } else {
            if (width < 1) width = 1024;
            if (height < 1) height = 768;
        }
    }

    const window = SDL.SDL_CreateWindow(
        title,
        @intFromFloat(width),
        @intFromFloat(height),
        SDL.SDL_WINDOW_RESIZABLE | SDL.SDL_WINDOW_HIGH_PIXEL_DENSITY | SDL.SDL_WINDOW_HIDDEN,
    );
    if (window == null) {
        return lua.luaL_error(L, "Error creating glyph window: %s", SDL.SDL_GetError());
    }

    const ud = lua.lua_newuserdatauv(L, @sizeOf(*RenWindow), 0);
    if (ud == null) return lua.luaL_error(L, "Failed to allocate window userdata");
    _ = lua.luaL_setmetatable(L, API_TYPE_RENWINDOW);

    const win_ptr: **RenWindow = @ptrCast(@alignCast(ud));
    win_ptr.* = renderer.create(window.?);

    return 1;
}

fn f_renwin_gc(L: ?*lua.lua_State) callconv(.c) c_int {
    const win = checkRenWindow(L, 1) orelse return 0;
    if (win != persistent_window)
        renderer.destroy(win);
    return 0;
}

fn f_renwin_get_size(L: ?*lua.lua_State) callconv(.c) c_int {
    const win = checkRenWindow(L, 1) orelse return 0;
    var w: c_int = 0;
    var h: c_int = 0;
    renderer.getSize(win, &w, &h);
    lua.lua_pushnumber(L, @floatFromInt(w));
    lua.lua_pushnumber(L, @floatFromInt(h));
    return 2;
}

fn f_renwin_persist(L: ?*lua.lua_State) callconv(.c) c_int {
    persistent_window = checkRenWindow(L, 1);
    return 0;
}

fn f_renwin_restore(L: ?*lua.lua_State) callconv(.c) c_int {
    if (persistent_window) |win| {
        const ud = lua.lua_newuserdatauv(L, @sizeOf(*RenWindow), 0);
        if (ud == null) {
            lua.lua_pushnil(L);
            return 1;
        }
        _ = lua.luaL_setmetatable(L, API_TYPE_RENWINDOW);
        const win_ptr: **RenWindow = @ptrCast(@alignCast(ud));
        win_ptr.* = win;
    } else {
        lua.lua_pushnil(L);
    }
    return 1;
}

const renwindow_lib = [_]lua.luaL_Reg{
    .{ .name = "create", .func = f_renwin_create },
    .{ .name = "__gc", .func = f_renwin_gc },
    .{ .name = "get_size", .func = f_renwin_get_size },
    .{ .name = "_persist", .func = f_renwin_persist },
    .{ .name = "_restore", .func = f_renwin_restore },
    .{ .name = null, .func = null },
};

pub fn luaopen(L: ?*lua.lua_State) callconv(.c) c_int {
    _ = lua.luaL_newmetatable(L, API_TYPE_RENWINDOW);
    lua.luaL_setfuncs(L, &renwindow_lib, 0);
    lua.lua_pushvalue(L, -1);
    lua.lua_setfield(L, -2, "__index");
    return 1;
}
