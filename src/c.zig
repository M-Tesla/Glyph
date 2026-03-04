// C library imports — all C headers are imported here and re-exported
// so the rest of the codebase uses `c.lua`, `c.SDL`, etc.

pub const lua = @cImport({
    @cInclude("lua.h");
    @cInclude("lauxlib.h");
    @cInclude("lualib.h");
});

pub const SDL = @cImport({
    @cInclude("SDL3/SDL.h");
});

pub const ft = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
    @cInclude("freetype/ftoutln.h");
    @cInclude("freetype/ftlcdfil.h");
});

pub const pcre2 = @cImport({
    @cDefine("PCRE2_CODE_UNIT_WIDTH", "8");
    @cDefine("PCRE2_STATIC", "1");
    @cInclude("pcre2.h");
});

// ── Lua helper wrappers ──────────────────────────────────────────────────
// Some Lua macros can't be translated by Zig's @cImport, so we wrap them here.

/// Replacement for luaL_newlib(L, funcs) which Zig can't translate.
/// Creates a new table and registers all functions from the array.
pub fn luaNewLib(L: ?*lua.lua_State, funcs: [*]const lua.luaL_Reg) void {
    // Count entries (until .name == null sentinel)
    var count: c_int = 0;
    var ptr = funcs;
    while (ptr[0].name != null) {
        count += 1;
        ptr += 1;
    }
    lua.lua_createtable(L, 0, count);
    lua.luaL_setfuncs(L, funcs, 0);
}

/// Replacement for luaL_checkstring(L, n) which Zig can't translate
/// because the NULL macro doesn't cast to [*c]usize.
pub fn luaCheckString(L: ?*lua.lua_State, n: c_int) [*c]const u8 {
    return lua.luaL_checklstring(L, n, null);
}

/// Replacement for luaL_optstring(L, n, d)
pub fn luaOptString(L: ?*lua.lua_State, n: c_int, default: [*c]const u8) [*c]const u8 {
    return lua.luaL_optlstring(L, n, default, null);
}
