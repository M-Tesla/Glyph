// utf8extra Lua API — UTF-8 string operations
// Zig port of the luautf8 library used by Lite-XL
//
// Pattern matching (match, find, gmatch, gsub) delegates to Lua's string.*
// since full UTF-8 pattern matching would require reimplementing the Lua pattern engine.
// For Lite-XL this works because syntax patterns use regex (PCRE2) not Lua patterns.

const std = @import("std");
const c = @import("../c.zig");
const lua = c.lua;

// ── UTF-8 helpers ───────────────────────────────────────────────────────

fn utf8CharLen(byte: u8) usize {
    if (byte < 0x80) return 1;
    if (byte < 0xC0) return 1; // continuation byte, treat as 1
    if (byte < 0xE0) return 2;
    if (byte < 0xF0) return 3;
    return 4;
}

/// Decode a UTF-8 codepoint starting at s[pos]. Returns (codepoint, byte_length).
fn utf8Decode(s: [*c]const u8, pos: usize, len: usize) struct { cp: u32, size: usize } {
    if (pos >= len) return .{ .cp = 0, .size = 0 };
    const b0 = s[pos];
    if (b0 < 0x80) return .{ .cp = b0, .size = 1 };
    if (b0 < 0xC0) return .{ .cp = b0, .size = 1 }; // invalid, treat as single byte
    if (b0 < 0xE0 and pos + 1 < len) {
        const cp = (@as(u32, b0 & 0x1F) << 6) | @as(u32, s[pos + 1] & 0x3F);
        return .{ .cp = cp, .size = 2 };
    }
    if (b0 < 0xF0 and pos + 2 < len) {
        const cp = (@as(u32, b0 & 0x0F) << 12) | (@as(u32, s[pos + 1] & 0x3F) << 6) | @as(u32, s[pos + 2] & 0x3F);
        return .{ .cp = cp, .size = 3 };
    }
    if (pos + 3 < len) {
        const cp = (@as(u32, b0 & 0x07) << 18) | (@as(u32, s[pos + 1] & 0x3F) << 12) | (@as(u32, s[pos + 2] & 0x3F) << 6) | @as(u32, s[pos + 3] & 0x3F);
        return .{ .cp = cp, .size = 4 };
    }
    return .{ .cp = b0, .size = 1 };
}

fn utf8Next(s: [*c]const u8, pos: usize, len: usize) usize {
    if (pos >= len) return len;
    return @min(pos + utf8CharLen(s[pos]), len);
}

fn utf8Prev(s: [*c]const u8, pos: usize) usize {
    if (pos == 0) return 0;
    var p = pos - 1;
    while (p > 0 and (s[p] & 0xC0) == 0x80) : (p -= 1) {}
    return p;
}

/// Advance n characters from byte position pos. Returns new byte position.
fn utf8Advance(s: [*c]const u8, start: usize, len: usize, n: usize) usize {
    var pos = start;
    var rem = n;
    while (pos < len and rem > 0) {
        pos = utf8Next(s, pos, len);
        rem -= 1;
    }
    return pos;
}

/// Retreat n characters from byte position pos. Returns new byte position.
fn utf8Retreat(s: [*c]const u8, start: usize, n: usize) usize {
    var pos = start;
    var rem = n;
    while (pos > 0 and rem > 0) {
        pos = utf8Prev(s, pos);
        rem -= 1;
    }
    return pos;
}

// ── Lua helpers ─────────────────────────────────────────────────────────

fn luaOptInteger(L: ?*lua.lua_State, n: c_int, d: lua.lua_Integer) lua.lua_Integer {
    if (lua.lua_type(L, n) <= 0) return d;
    return lua.luaL_checkinteger(L, n);
}

/// luaL_addchar is a C macro with postfix inc that Zig can't translate.
fn bufAddChar(B: *lua.luaL_Buffer, ch: u8) void {
    var buf = [1]u8{ch};
    lua.luaL_addlstring(B, &buf, 1);
}

// ── Delegation helpers ─────────────────────────────────────────────────

/// Delegate a call to string.<method>, forwarding all arguments and returning all results.
fn delegateToString(L: ?*lua.lua_State, method: [*:0]const u8) c_int {
    const nargs = lua.lua_gettop(L);
    _ = lua.lua_getglobal(L, "string");
    _ = lua.lua_getfield(L, -1, method);
    lua.lua_remove(L, -2); // remove 'string' table
    var i: c_int = 1;
    while (i <= nargs) : (i += 1) {
        lua.lua_pushvalue(L, i);
    }
    lua.lua_callk(L, nargs, -1, 0, null); // LUA_MULTRET = -1
    return lua.lua_gettop(L) - nargs;
}

/// Delegate a call to utf8.<method> (Lua 5.3+), falling back to string.<method>.
fn delegateToUtf8(L: ?*lua.lua_State, method: [*:0]const u8) c_int {
    const nargs = lua.lua_gettop(L);
    _ = lua.lua_getglobal(L, "utf8");
    if (lua.lua_type(L, -1) == lua.LUA_TNIL) {
        lua.lua_settop(L, nargs); // pop nil, restore stack
        return delegateToString(L, method);
    }
    _ = lua.lua_getfield(L, -1, method);
    if (lua.lua_type(L, -1) == lua.LUA_TNIL) {
        lua.lua_settop(L, nargs); // field not found, restore stack
        return delegateToString(L, method);
    }
    lua.lua_remove(L, -2); // remove 'utf8' table
    var i: c_int = 1;
    while (i <= nargs) : (i += 1) {
        lua.lua_pushvalue(L, i);
    }
    lua.lua_callk(L, nargs, -1, 0, null);
    return lua.lua_gettop(L) - nargs;
}

// ── Pattern matching — delegate to string.* ────────────────────────────

fn f_match(L: ?*lua.lua_State) callconv(.c) c_int {
    return delegateToString(L, "match");
}
fn f_find(L: ?*lua.lua_State) callconv(.c) c_int {
    return delegateToString(L, "find");
}
fn f_gmatch(L: ?*lua.lua_State) callconv(.c) c_int {
    return delegateToString(L, "gmatch");
}
fn f_gsub(L: ?*lua.lua_State) callconv(.c) c_int {
    return delegateToString(L, "gsub");
}

// ── UTF-8 aware functions — delegate to Lua's utf8 library ─────────────

fn f_len(L: ?*lua.lua_State) callconv(.c) c_int {
    return delegateToUtf8(L, "len");
}
fn f_codepoint(L: ?*lua.lua_State) callconv(.c) c_int {
    return delegateToUtf8(L, "codepoint");
}
fn f_offset(L: ?*lua.lua_State) callconv(.c) c_int {
    return delegateToUtf8(L, "offset");
}
fn f_char(L: ?*lua.lua_State) callconv(.c) c_int {
    return delegateToUtf8(L, "char");
}
fn f_codes(L: ?*lua.lua_State) callconv(.c) c_int {
    return delegateToUtf8(L, "codes");
}

// ── Byte-level / ASCII-safe — delegate to string.* ─────────────────────

fn f_sub(L: ?*lua.lua_State) callconv(.c) c_int {
    return delegateToString(L, "sub");
}
fn f_reverse(L: ?*lua.lua_State) callconv(.c) c_int {
    return delegateToString(L, "reverse");
}
fn f_lower(L: ?*lua.lua_State) callconv(.c) c_int {
    return delegateToString(L, "lower");
}
fn f_upper(L: ?*lua.lua_State) callconv(.c) c_int {
    return delegateToString(L, "upper");
}
fn f_byte(L: ?*lua.lua_State) callconv(.c) c_int {
    return delegateToString(L, "byte");
}

// ── charpos(s [, charpos [, offset]]) ───────────────────────────────────
// Convert character position to byte offset.
// charpos (2nd arg): character position (1-based). Default 0 = beginning.
// offset (3rd arg): characters to advance. Default 1.
// Returns: 1-based byte position.

fn f_charpos(L: ?*lua.lua_State) callconv(.c) c_int {
    var len: usize = 0;
    const s = lua.luaL_checklstring(L, 1, &len);
    const posi = luaOptInteger(L, 2, 0);
    const offset_arg = luaOptInteger(L, 3, 1);

    // Find starting byte position from character position
    var e: usize = 0;
    if (posi > 0) {
        // Advance posi-1 characters from start (1-based → 0-based)
        e = utf8Advance(s, 0, len, @intCast(posi - 1));
    } else if (posi < 0) {
        // Count from end
        e = utf8Retreat(s, len, @intCast(-posi));
    }
    // posi == 0: e stays at 0 (beginning)

    // Apply character offset
    if (offset_arg > 0) {
        e = utf8Advance(s, e, len, @intCast(offset_arg));
    } else if (offset_arg < 0) {
        e = utf8Retreat(s, e, @intCast(-offset_arg));
    }

    lua.lua_pushinteger(L, @as(lua.lua_Integer, @intCast(e + 1))); // 1-based
    return 1;
}

// ── next(s [, byte_offset]) ─────────────────────────────────────────────
// Returns byte_pos (1-based), codepoint at that position.
// Default offset = 0 (before string). Returns first char position + codepoint.

fn f_next(L: ?*lua.lua_State) callconv(.c) c_int {
    var len: usize = 0;
    const s = lua.luaL_checklstring(L, 1, &len);
    var pos: usize = 0;

    if (lua.lua_gettop(L) > 1) {
        const offset = luaOptInteger(L, 2, 0);
        if (offset > 0) {
            pos = @intCast(offset); // already 1-based byte offset, convert to 0-based
            // Find next character boundary
            if (pos > 0) pos -= 1;
            pos = utf8Next(s, pos, len);
        }
    }

    if (pos >= len) {
        lua.lua_pushnil(L);
        return 1;
    }

    const decoded = utf8Decode(s, pos, len);
    lua.lua_pushinteger(L, @as(lua.lua_Integer, @intCast(pos + 1))); // 1-based
    lua.lua_pushinteger(L, @as(lua.lua_Integer, @intCast(decoded.cp)));
    return 2;
}

// ── escape(s) ───────────────────────────────────────────────────────────
// Escape Lua pattern special characters with %

fn f_escape(L: ?*lua.lua_State) callconv(.c) c_int {
    var len: usize = 0;
    const s = lua.luaL_checklstring(L, 1, &len);

    var buf: lua.luaL_Buffer = undefined;
    lua.luaL_buffinit(L, &buf);

    for (0..len) |i| {
        const ch = s[i];
        // Lua pattern special characters: ^$()%.[]*+-?
        switch (ch) {
            '^', '$', '(', ')', '%', '.', '[', ']', '*', '+', '-', '?' => {
                bufAddChar(&buf, '%');
                bufAddChar(&buf, ch);
            },
            else => bufAddChar(&buf, ch),
        }
    }

    lua.luaL_pushresult(&buf);
    return 1;
}

// ── insert(s, idx, substring) ───────────────────────────────────────────
// Insert substring at character position idx.

fn f_insert(L: ?*lua.lua_State) callconv(.c) c_int {
    var len: usize = 0;
    const s = lua.luaL_checklstring(L, 1, &len);
    const idx = luaOptInteger(L, 2, 0);
    var sub_len: usize = 0;
    const sub = lua.luaL_checklstring(L, 3, &sub_len);

    // Convert character position to byte position
    var byte_pos: usize = 0;
    if (idx > 0) {
        byte_pos = utf8Advance(s, 0, len, @intCast(idx - 1));
    } else if (idx < 0) {
        byte_pos = utf8Retreat(s, len, @intCast(-idx));
    }
    if (byte_pos > len) byte_pos = len;

    var buf: lua.luaL_Buffer = undefined;
    lua.luaL_buffinit(L, &buf);
    if (byte_pos > 0) lua.luaL_addlstring(&buf, s, byte_pos);
    if (sub_len > 0) lua.luaL_addlstring(&buf, sub, sub_len);
    if (byte_pos < len) lua.luaL_addlstring(&buf, ptrAdd(s, byte_pos), len - byte_pos);
    lua.luaL_pushresult(&buf);
    return 1;
}

// ── remove(s, i [, j]) ─────────────────────────────────────────────────
// Remove characters from position i to j (inclusive). Default j = i.

fn f_remove(L: ?*lua.lua_State) callconv(.c) c_int {
    var len: usize = 0;
    const s = lua.luaL_checklstring(L, 1, &len);
    const i_arg = lua.luaL_checkinteger(L, 2);
    const j_arg = luaOptInteger(L, 3, i_arg);

    // Convert character positions to byte positions
    var start_byte: usize = 0;
    if (i_arg > 0) {
        start_byte = utf8Advance(s, 0, len, @intCast(i_arg - 1));
    }

    var end_byte: usize = 0;
    if (j_arg > 0) {
        end_byte = utf8Advance(s, 0, len, @intCast(j_arg));
    } else {
        end_byte = start_byte;
    }
    if (end_byte > len) end_byte = len;

    var buf: lua.luaL_Buffer = undefined;
    lua.luaL_buffinit(L, &buf);
    if (start_byte > 0) lua.luaL_addlstring(&buf, s, start_byte);
    if (end_byte < len) lua.luaL_addlstring(&buf, ptrAdd(s, end_byte), len - end_byte);
    lua.luaL_pushresult(&buf);
    return 1;
}

// ── width(s [, ambi_is_double]) ─────────────────────────────────────────
// Returns the display width of string s.
// Simplified: each character has width 1 (proper implementation needs East Asian Width data).

fn f_width(L: ?*lua.lua_State) callconv(.c) c_int {
    var len: usize = 0;
    const s = lua.luaL_checklstring(L, 1, &len);
    _ = lua.lua_toboolean(L, 2); // ambi_is_double (ignored in simplified version)

    var width: usize = 0;
    var pos: usize = 0;
    while (pos < len) {
        const decoded = utf8Decode(s, pos, len);
        if (decoded.size == 0) break;
        // Basic CJK detection: characters in CJK ranges have width 2
        const cp = decoded.cp;
        if ((cp >= 0x1100 and cp <= 0x115F) or // Hangul Jamo
            (cp >= 0x2E80 and cp <= 0x9FFF) or // CJK
            (cp >= 0xAC00 and cp <= 0xD7AF) or // Hangul Syllables
            (cp >= 0xF900 and cp <= 0xFAFF) or // CJK Compat
            (cp >= 0xFE10 and cp <= 0xFE6F) or // CJK forms
            (cp >= 0xFF01 and cp <= 0xFF60) or // Fullwidth
            (cp >= 0xFFE0 and cp <= 0xFFE6) or // Fullwidth signs
            (cp >= 0x20000 and cp <= 0x2FA1F)) // CJK Extension
        {
            width += 2;
        } else {
            width += 1;
        }
        pos += decoded.size;
    }

    lua.lua_pushinteger(L, @as(lua.lua_Integer, @intCast(width)));
    return 1;
}

// ── widthindex(s, target_width [, ambi_is_double]) ──────────────────────
// Returns the byte index where the display width reaches target_width.

fn f_widthindex(L: ?*lua.lua_State) callconv(.c) c_int {
    var len: usize = 0;
    const s = lua.luaL_checklstring(L, 1, &len);
    const target: usize = @intCast(lua.luaL_checkinteger(L, 2));
    _ = lua.lua_toboolean(L, 3); // ambi_is_double

    var width: usize = 0;
    var pos: usize = 0;
    while (pos < len) {
        const decoded = utf8Decode(s, pos, len);
        if (decoded.size == 0) break;
        const cp = decoded.cp;
        const char_width: usize = if ((cp >= 0x1100 and cp <= 0x115F) or
            (cp >= 0x2E80 and cp <= 0x9FFF) or
            (cp >= 0xAC00 and cp <= 0xD7AF) or
            (cp >= 0xF900 and cp <= 0xFAFF) or
            (cp >= 0xFE10 and cp <= 0xFE6F) or
            (cp >= 0xFF01 and cp <= 0xFF60) or
            (cp >= 0xFFE0 and cp <= 0xFFE6) or
            (cp >= 0x20000 and cp <= 0x2FA1F)) 2 else 1;
        if (width + char_width > target) break;
        width += char_width;
        pos += decoded.size;
    }

    lua.lua_pushinteger(L, @as(lua.lua_Integer, @intCast(pos + 1))); // 1-based
    return 1;
}

// ── title(s) ────────────────────────────────────────────────────────────
// Title case: capitalize first character of each word.
// Simplified: delegates to upper for first char, lower for rest of each word.

fn f_title(L: ?*lua.lua_State) callconv(.c) c_int {
    var len: usize = 0;
    const s = lua.luaL_checklstring(L, 1, &len);

    var buf: lua.luaL_Buffer = undefined;
    lua.luaL_buffinit(L, &buf);

    var capitalize_next = true;
    for (0..len) |i| {
        const ch = s[i];
        if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') {
            capitalize_next = true;
            bufAddChar(&buf, ch);
        } else if (capitalize_next and ch >= 'a' and ch <= 'z') {
            bufAddChar(&buf, ch - 32);
            capitalize_next = false;
        } else {
            bufAddChar(&buf, ch);
            if ((ch & 0xC0) != 0x80) capitalize_next = false; // not continuation byte
        }
    }

    lua.luaL_pushresult(&buf);
    return 1;
}

// ── fold(s) ─────────────────────────────────────────────────────────────
// Case folding (simplified: delegates to string.lower)

fn f_fold(L: ?*lua.lua_State) callconv(.c) c_int {
    return delegateToString(L, "lower");
}

// ── ncasecmp(a, b) ─────────────────────────────────────────────────────
// Case-insensitive string comparison. Returns 0 if equal, <0 if a<b, >0 if a>b.

fn f_ncasecmp(L: ?*lua.lua_State) callconv(.c) c_int {
    var len_a: usize = 0;
    var len_b: usize = 0;
    const a = lua.luaL_checklstring(L, 1, &len_a);
    const b = lua.luaL_checklstring(L, 2, &len_b);

    const min_len = @min(len_a, len_b);
    var i: usize = 0;
    while (i < min_len) : (i += 1) {
        const ca = toLowerASCII(a[i]);
        const cb = toLowerASCII(b[i]);
        if (ca != cb) {
            lua.lua_pushinteger(L, @as(lua.lua_Integer, @intCast(ca)) - @as(lua.lua_Integer, @intCast(cb)));
            return 1;
        }
    }

    // Equal prefix — compare by length
    if (len_a == len_b) {
        lua.lua_pushinteger(L, 0);
    } else if (len_a < len_b) {
        lua.lua_pushinteger(L, -1);
    } else {
        lua.lua_pushinteger(L, 1);
    }
    return 1;
}

fn toLowerASCII(ch: u8) u8 {
    return if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
}

/// Advance a [*c]const u8 pointer by offset bytes
fn ptrAdd(ptr: [*c]const u8, off: usize) [*c]const u8 {
    return @ptrFromInt(@intFromPtr(ptr) + off);
}

// ── Module registration ────────────────────────────────────────────────

const funcs = [_]lua.luaL_Reg{
    // Pattern matching (delegate to string.*)
    .{ .name = "match", .func = f_match },
    .{ .name = "find", .func = f_find },
    .{ .name = "gmatch", .func = f_gmatch },
    .{ .name = "gsub", .func = f_gsub },
    // UTF-8 aware (delegate to utf8.*)
    .{ .name = "len", .func = f_len },
    .{ .name = "sub", .func = f_sub },
    .{ .name = "reverse", .func = f_reverse },
    .{ .name = "lower", .func = f_lower },
    .{ .name = "upper", .func = f_upper },
    .{ .name = "byte", .func = f_byte },
    .{ .name = "char", .func = f_char },
    .{ .name = "codepoint", .func = f_codepoint },
    .{ .name = "offset", .func = f_offset },
    .{ .name = "codes", .func = f_codes },
    // Native UTF-8 functions
    .{ .name = "charpos", .func = f_charpos },
    .{ .name = "next", .func = f_next },
    .{ .name = "escape", .func = f_escape },
    .{ .name = "insert", .func = f_insert },
    .{ .name = "remove", .func = f_remove },
    .{ .name = "width", .func = f_width },
    .{ .name = "widthindex", .func = f_widthindex },
    .{ .name = "title", .func = f_title },
    .{ .name = "fold", .func = f_fold },
    .{ .name = "ncasecmp", .func = f_ncasecmp },
    .{ .name = null, .func = null },
};

pub fn luaopen(L: ?*lua.lua_State) callconv(.c) c_int {
    c.luaNewLib(L, &funcs);
    return 1;
}
