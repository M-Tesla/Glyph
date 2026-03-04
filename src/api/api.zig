// API module registry — mirrors api.c from Lite-XL
// Registers all native modules into the Lua state.

const c = @import("../c.zig");
const lua = c.lua;

// Module open functions (to be implemented)
const system = @import("system.zig");
const renderer_api = @import("renderer_api.zig");
const renwindow_api = @import("renwindow_api.zig");
const regex = @import("regex.zig");
const process = @import("process.zig");
const dirmonitor = @import("dirmonitor.zig");
const utf8extra = @import("utf8extra.zig");

const ModuleEntry = struct {
    name: [*:0]const u8,
    func: lua.lua_CFunction,
};

const libs = [_]ModuleEntry{
    .{ .name = "system", .func = system.luaopen },
    .{ .name = "renderer", .func = renderer_api.luaopen },
    .{ .name = "renwindow", .func = renwindow_api.luaopen },
    .{ .name = "regex", .func = regex.luaopen },
    .{ .name = "process", .func = process.luaopen },
    .{ .name = "dirmonitor", .func = dirmonitor.luaopen },
    .{ .name = "utf8extra", .func = utf8extra.luaopen },
};

pub fn loadLibs(L: *lua.lua_State) void {
    for (&libs) |entry| {
        // luaL_requiref(L, name, func, 1) — registers module as global
        lua.luaL_requiref(L, entry.name, entry.func, 1);
        lua.lua_settop(L, -(1) - 1); // lua_pop(L, 1)
    }
}
