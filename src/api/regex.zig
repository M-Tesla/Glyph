// regex Lua API — PCRE2 bindings
// Zig port of api/regex.c from Lite-XL

const std = @import("std");
const c = @import("../c.zig");
const lua = c.lua;
const pcre2 = c.pcre2;

const allocator = std.heap.c_allocator;

// ── Lua helper functions (macros not translated by @cImport) ────────────

fn luaUpvalueIndex(i: c_int) c_int {
    return lua.LUA_REGISTRYINDEX - i;
}

fn luaSetMetatable(L: ?*lua.lua_State, name: [*:0]const u8) void {
    _ = lua.lua_getfield(L, lua.LUA_REGISTRYINDEX, name);
    _ = lua.lua_setmetatable(L, -2);
}

fn luaOptInteger(L: ?*lua.lua_State, n: c_int, d: lua.lua_Integer) lua.lua_Integer {
    if (lua.lua_type(L, n) <= 0) return d;
    return lua.luaL_checkinteger(L, n);
}

fn luaOptNumber(L: ?*lua.lua_State, n: c_int, d: lua.lua_Number) lua.lua_Number {
    if (lua.lua_type(L, n) <= 0) return d;
    return lua.luaL_checknumber(L, n);
}

/// Advance a [*c]const u8 pointer by offset bytes
fn ptrAdd(ptr: [*c]const u8, off: usize) [*c]const u8 {
    return @ptrFromInt(@intFromPtr(ptr) + off);
}

// ── RegexState for gmatch iterator ──────────────────────────────────────

const RegexState = struct {
    re: ?*pcre2.pcre2_code_8,
    match_data: ?*pcre2.pcre2_match_data_8,
    subject: [*c]const u8,
    subject_len: usize,
    offset: usize,
    regex_compiled: bool,
    found: bool,
};

// ── Helpers ─────────────────────────────────────────────────────────────

/// Convert Lua offset (may be negative) to absolute 1-based position
fn regexOffsetRelative(pos: lua.lua_Integer, len: usize) usize {
    if (pos > 0) return @intCast(pos);
    if (pos == 0) return 1;
    const ilen: lua.lua_Integer = @intCast(len);
    if (pos < -ilen) return 1;
    return @intCast(ilen + pos + 1);
}

/// Get pcre2_code from arg 1: table = precompiled, string = compile on-the-fly
fn regexGetPattern(L: ?*lua.lua_State, should_free: *bool) ?*pcre2.pcre2_code_8 {
    should_free.* = false;

    if (lua.lua_type(L, 1) == lua.LUA_TTABLE) {
        _ = lua.lua_rawgeti(L, 1, 1);
        const ud = lua.lua_touserdata(L, -1);
        lua.lua_settop(L, lua.lua_gettop(L) - 1); // pop
        if (ud) |ptr| return @ptrCast(@alignCast(ptr));
        return null;
    }

    // Compile string pattern on-the-fly
    var pattern_len: usize = 0;
    const pattern = lua.luaL_checklstring(L, 1, &pattern_len);
    var errornumber: c_int = 0;
    var erroroffset: usize = 0;

    const re = pcre2.pcre2_compile_8(
        pattern,
        pattern_len,
        pcre2.PCRE2_UTF,
        &errornumber,
        &erroroffset,
        null,
    );
    if (re == null) {
        var errmsg: [256]u8 = undefined;
        _ = pcre2.pcre2_get_error_message_8(errornumber, &errmsg, errmsg.len);
        _ = lua.luaL_error(
            L,
            "regex pattern error at offset %d: %s",
            @as(c_int, @intCast(erroroffset)),
            @as([*c]const u8, @ptrCast(&errmsg)),
        );
        return null;
    }

    _ = pcre2.pcre2_jit_compile_8(re, pcre2.PCRE2_JIT_COMPLETE);
    should_free.* = true;
    return re;
}

// ── regex.compile(pattern, options?) ────────────────────────────────────

fn f_pcre_compile(L: ?*lua.lua_State) callconv(.c) c_int {
    var len: usize = 0;
    var options: u32 = pcre2.PCRE2_UTF;
    const str = lua.luaL_checklstring(L, 1, &len);

    if (lua.lua_gettop(L) > 1) {
        const opt_str = c.luaCheckString(L, 2);
        if (opt_str != null) {
            var i: usize = 0;
            while (opt_str[i] != 0) : (i += 1) {
                switch (opt_str[i]) {
                    'i' => options |= pcre2.PCRE2_CASELESS,
                    'm' => options |= pcre2.PCRE2_MULTILINE,
                    's' => options |= pcre2.PCRE2_DOTALL,
                    else => {},
                }
            }
        }
    }

    var errornumber: c_int = 0;
    var erroroffset: usize = 0;
    const re = pcre2.pcre2_compile_8(str, len, options, &errornumber, &erroroffset, null);

    if (re != null) {
        _ = pcre2.pcre2_jit_compile_8(re, pcre2.PCRE2_JIT_COMPLETE);
        lua.lua_createtable(L, 1, 0);
        lua.lua_pushlightuserdata(L, @ptrCast(@constCast(re.?)));
        lua.lua_rawseti(L, -2, 1);
        luaSetMetatable(L, "regex");
        return 1;
    }

    // Error — return nil, message
    var buffer: [256]u8 = undefined;
    _ = pcre2.pcre2_get_error_message_8(errornumber, &buffer, buffer.len);
    lua.lua_pushnil(L);
    _ = lua.lua_pushfstring(
        L,
        "regex compilation failed at offset %d: %s",
        @as(c_int, @intCast(erroroffset)),
        @as([*c]const u8, @ptrCast(&buffer)),
    );
    return 2;
}

// ── regex.cmatch(pattern, str, offset?, options?) ───────────────────────

fn f_pcre_match(L: ?*lua.lua_State) callconv(.c) c_int {
    var regex_compiled: bool = false;
    const re = regexGetPattern(L, &regex_compiled) orelse return 0;

    var len: usize = 0;
    const str = lua.luaL_checklstring(L, 2, &len);

    var offset: usize = 1;
    if (lua.lua_gettop(L) > 2)
        offset = regexOffsetRelative(@intFromFloat(lua.luaL_checknumber(L, 3)), len);
    offset -= 1;
    len -= offset;

    var opts: u32 = 0;
    if (lua.lua_gettop(L) > 3)
        opts = @intFromFloat(lua.luaL_checknumber(L, 4));

    const md = pcre2.pcre2_match_data_create_from_pattern_8(re, null);
    const subject = ptrAdd(str, offset);
    const rc = pcre2.pcre2_match_8(re, subject, len, 0, opts, md, null);

    if (rc < 0) {
        if (regex_compiled) pcre2.pcre2_code_free_8(re);
        pcre2.pcre2_match_data_free_8(md);
        if (rc != pcre2.PCRE2_ERROR_NOMATCH) {
            var buffer: [120]u8 = undefined;
            _ = pcre2.pcre2_get_error_message_8(rc, &buffer, buffer.len);
            _ = lua.luaL_error(
                L,
                "regex matching error %d: %s",
                rc,
                @as([*c]const u8, @ptrCast(&buffer)),
            );
        }
        return 0;
    }

    const ovector = pcre2.pcre2_get_ovector_pointer_8(md);
    if (ovector[0] > ovector[1]) {
        if (regex_compiled) pcre2.pcre2_code_free_8(re);
        pcre2.pcre2_match_data_free_8(md);
        _ = lua.luaL_error(L, "regex matching error: \\K was used in an assertion to set the match start after its end");
        return 0;
    }

    const count: usize = @intCast(rc);
    for (0..count * 2) |i| {
        lua.lua_pushinteger(L, @as(lua.lua_Integer, @intCast(ovector[i] + offset + 1)));
    }

    if (regex_compiled) pcre2.pcre2_code_free_8(re);
    pcre2.pcre2_match_data_free_8(md);
    return @intCast(count * 2);
}

// ── gmatch iterator closure ─────────────────────────────────────────────

fn regex_gmatch_iterator(L: ?*lua.lua_State) callconv(.c) c_int {
    const state_ptr = lua.lua_touserdata(L, luaUpvalueIndex(3));
    if (state_ptr == null) return 0;
    const state: *RegexState = @ptrCast(@alignCast(state_ptr));

    if (state.found) {
        const rc = pcre2.pcre2_match_8(
            state.re.?,
            state.subject,
            state.subject_len,
            state.offset,
            0,
            state.match_data,
            null,
        );

        if (rc < 0) {
            if (rc != pcre2.PCRE2_ERROR_NOMATCH) {
                var buffer: [120]u8 = undefined;
                _ = pcre2.pcre2_get_error_message_8(rc, &buffer, buffer.len);
                _ = lua.luaL_error(
                    L,
                    "regex matching error %d: %s",
                    rc,
                    @as([*c]const u8, @ptrCast(&buffer)),
                );
            }
            // Clean up
            if (state.regex_compiled) pcre2.pcre2_code_free_8(state.re.?);
            pcre2.pcre2_match_data_free_8(state.match_data.?);
            state.found = false;
            return 0;
        }

        const ovector_count: usize = pcre2.pcre2_get_ovector_count_8(state.match_data);
        if (ovector_count > 0) {
            const ovector = pcre2.pcre2_get_ovector_pointer_8(state.match_data);
            if (ovector[0] > ovector[1]) {
                _ = lua.luaL_error(L, "regex matching error: \\K was used in an assertion to set the match start after its end");
                if (state.regex_compiled) pcre2.pcre2_code_free_8(state.re.?);
                pcre2.pcre2_match_data_free_8(state.match_data.?);
                state.found = false;
                return 0;
            }

            // If captures exist, skip group 0 (full match)
            var index: usize = 0;
            if (ovector_count > 1) index = 2;

            var total: c_int = 0;
            const total_results = ovector_count * 2;
            var last_offset: usize = 0;
            var i = index;
            while (i < total_results) : (i += 2) {
                if (ovector[i] == ovector[i + 1]) {
                    // Zero-width match: return 1-based position
                    lua.lua_pushinteger(L, @as(lua.lua_Integer, @intCast(ovector[i] + 1)));
                } else {
                    // Non-empty match: return substring
                    const start = ovector[i];
                    const end = ovector[i + 1];
                    _ = lua.lua_pushlstring(L, ptrAdd(state.subject, start), end - start);
                }
                last_offset = ovector[i + 1];
                total += 1;
            }

            if (last_offset > 0 and last_offset - 1 < state.subject_len)
                state.offset = last_offset
            else
                state.found = false;

            return total;
        } else {
            state.found = false;
        }
    }

    // Clean up
    if (state.re) |re| {
        if (state.regex_compiled) pcre2.pcre2_code_free_8(re);
        state.re = null;
    }
    if (state.match_data) |md| {
        pcre2.pcre2_match_data_free_8(md);
        state.match_data = null;
    }
    return 0;
}

// ── regex.gmatch(pattern, str, offset?) ─────────────────────────────────

fn f_pcre_gmatch(L: ?*lua.lua_State) callconv(.c) c_int {
    var regex_compiled: bool = false;
    const re = regexGetPattern(L, &regex_compiled) orelse return 0;

    var subject_len: usize = 0;
    const subject = lua.luaL_checklstring(L, 2, &subject_len);

    var offset = regexOffsetRelative(
        @intFromFloat(luaOptNumber(L, 3, 1)),
        subject_len,
    );
    offset -= 1;

    lua.lua_settop(L, 2); // Keep pattern and subject as upvalues 1 and 2

    // Create userdata for state (upvalue 3)
    const state_raw = lua.lua_newuserdatauv(L, @sizeOf(RegexState), 0);
    const state: *RegexState = @ptrCast(@alignCast(state_raw));
    state.* = .{
        .re = re,
        .match_data = pcre2.pcre2_match_data_create_from_pattern_8(re, null),
        .subject = subject,
        .subject_len = subject_len,
        .offset = offset,
        .regex_compiled = regex_compiled,
        .found = true,
    };

    lua.lua_pushcclosure(L, regex_gmatch_iterator, 3);
    return 1;
}

// ── regex.gsub(pattern, str, replacement, limit?) ───────────────────────

fn f_pcre_gsub(L: ?*lua.lua_State) callconv(.c) c_int {
    var orig_subject_len: usize = 0;
    var replacement_len: usize = 0;

    var regex_compiled: bool = false;
    const re = regexGetPattern(L, &regex_compiled) orelse return 0;

    const orig_subject = lua.luaL_checklstring(L, 2, &orig_subject_len);
    const replacement = lua.luaL_checklstring(L, 3, &replacement_len);
    var limit: c_int = @intCast(luaOptInteger(L, 4, 0));
    if (limit < 0) limit = 0;

    const md = pcre2.pcre2_match_data_create_from_pattern_8(re, null);

    var buffer_size: usize = 1024;
    var output = allocator.alloc(u8, buffer_size) catch {
        pcre2.pcre2_match_data_free_8(md);
        if (regex_compiled) pcre2.pcre2_code_free_8(re);
        return 0;
    };

    var options: u32 = pcre2.PCRE2_SUBSTITUTE_OVERFLOW_LENGTH | pcre2.PCRE2_SUBSTITUTE_EXTENDED;
    if (limit == 0) options |= pcre2.PCRE2_SUBSTITUTE_GLOBAL;

    var subject: [*c]const u8 = orig_subject;
    var subject_len: usize = orig_subject_len;
    var subject_buf: ?[]u8 = null; // non-null if subject was allocated by us

    var results_count: c_int = 0;
    var limit_count: c_int = 0;
    var done = false;
    var offset: usize = 0;
    var outlen: usize = buffer_size;

    while (!done) {
        outlen = buffer_size;
        results_count = pcre2.pcre2_substitute_8(
            re,
            subject,
            subject_len,
            offset,
            options,
            md,
            null,
            replacement,
            replacement_len,
            @ptrCast(output.ptr),
            &outlen,
        );

        if (results_count != pcre2.PCRE2_ERROR_NOMEMORY or buffer_size >= outlen) {
            if (limit == 0) {
                done = true;
            } else {
                const ovector_count = pcre2.pcre2_get_ovector_count_8(md);
                if (results_count > 0 and ovector_count > 0) {
                    limit_count += 1;
                    const ovector = pcre2.pcre2_get_ovector_pointer_8(md);
                    if (outlen > subject_len) {
                        offset = ovector[1] + (outlen - subject_len);
                    } else {
                        offset = ovector[1] -| (subject_len - outlen);
                    }
                    // Free previous subject if it was our allocation
                    if (subject_buf) |sb| allocator.free(sb);

                    if (limit_count == limit or (offset > 0 and offset - 1 == outlen)) {
                        done = true;
                        results_count = limit_count;
                        subject_buf = null;
                    } else {
                        // Swap: output becomes new subject
                        subject_buf = output;
                        subject = @ptrCast(output.ptr);
                        subject_len = outlen;
                        output = allocator.alloc(u8, buffer_size) catch {
                            subject_buf = null;
                            done = true;
                            results_count = limit_count;
                            break;
                        };
                    }
                } else {
                    if (subject_buf) |sb| allocator.free(sb);
                    subject_buf = null;
                    done = true;
                    results_count = limit_count;
                }
            }
        } else {
            // Need bigger buffer — outlen has the required size
            buffer_size = outlen;
            allocator.free(output);
            output = allocator.alloc(u8, buffer_size) catch {
                pcre2.pcre2_match_data_free_8(md);
                if (regex_compiled) pcre2.pcre2_code_free_8(re);
                return 0;
            };
        }
    }

    var return_count: c_int = 0;

    if (results_count > 0) {
        _ = lua.lua_pushlstring(L, @ptrCast(output.ptr), outlen);
        lua.lua_pushinteger(L, @intCast(results_count));
        return_count = 2;
    } else if (results_count == 0) {
        _ = lua.lua_pushlstring(L, subject, subject_len);
        lua.lua_pushinteger(L, 0);
        return_count = 2;
    }

    allocator.free(output);
    if (subject_buf) |sb| allocator.free(sb);
    pcre2.pcre2_match_data_free_8(md);
    if (regex_compiled) pcre2.pcre2_code_free_8(re);

    if (results_count < 0) {
        var errmsg: [256]u8 = undefined;
        _ = pcre2.pcre2_get_error_message_8(results_count, &errmsg, errmsg.len);
        _ = lua.luaL_error(L, "regex substitute error: %s", @as([*c]const u8, @ptrCast(&errmsg)));
        return 0;
    }

    return return_count;
}

// ── __gc metamethod ─────────────────────────────────────────────────────

fn f_pcre_gc(L: ?*lua.lua_State) callconv(.c) c_int {
    _ = lua.lua_rawgeti(L, -1, 1);
    const ud = lua.lua_touserdata(L, -1);
    if (ud) |ptr| {
        pcre2.pcre2_code_free_8(@ptrCast(@alignCast(ptr)));
    }
    return 0;
}

// ── Module registration ─────────────────────────────────────────────────

const funcs = [_]lua.luaL_Reg{
    .{ .name = "compile", .func = f_pcre_compile },
    .{ .name = "cmatch", .func = f_pcre_match },
    .{ .name = "gmatch", .func = f_pcre_gmatch },
    .{ .name = "gsub", .func = f_pcre_gsub },
    .{ .name = "__gc", .func = f_pcre_gc },
    .{ .name = null, .func = null },
};

pub fn luaopen(L: ?*lua.lua_State) callconv(.c) c_int {
    c.luaNewLib(L, &funcs);

    // Set __name field
    _ = lua.lua_pushstring(L, "regex");
    lua.lua_setfield(L, -2, "__name");

    // Register as metatable in registry: registry["regex"] = this table
    lua.lua_pushvalue(L, -1);
    lua.lua_setfield(L, lua.LUA_REGISTRYINDEX, "regex");

    // Export PCRE2 matching option constants
    lua.lua_pushinteger(L, pcre2.PCRE2_ANCHORED);
    lua.lua_setfield(L, -2, "ANCHORED");
    lua.lua_pushinteger(L, if (@hasDecl(pcre2, "PCRE2_ENDANCHORED")) pcre2.PCRE2_ENDANCHORED else pcre2.PCRE2_ANCHORED);
    lua.lua_setfield(L, -2, "ENDANCHORED");
    lua.lua_pushinteger(L, pcre2.PCRE2_NOTBOL);
    lua.lua_setfield(L, -2, "NOTBOL");
    lua.lua_pushinteger(L, pcre2.PCRE2_NOTEOL);
    lua.lua_setfield(L, -2, "NOTEOL");
    lua.lua_pushinteger(L, pcre2.PCRE2_NOTEMPTY);
    lua.lua_setfield(L, -2, "NOTEMPTY");
    lua.lua_pushinteger(L, pcre2.PCRE2_NOTEMPTY_ATSTART);
    lua.lua_setfield(L, -2, "NOTEMPTY_ATSTART");

    return 1;
}
