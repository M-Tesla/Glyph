// system module — Lua API for window management, filesystem, events, etc.
// Zig port of api/system.c from Lite-XL

const std = @import("std");
const c = @import("../c.zig");
const renderer = @import("../renderer.zig");
const rencache = @import("../rencache.zig");
const rw = @import("../renwindow.zig");

const lua = c.lua;
const SDL = c.SDL;
const RenWindow = renderer.RenWindow;

const win32 = struct {
    const DWORD = std.os.windows.DWORD;
    const HANDLE = std.os.windows.HANDLE;
    const LPCWSTR = std.os.windows.LPCWSTR;
    const LPWSTR = [*:0]u16;
    const BOOL = std.os.windows.BOOL;
    const MAX_PATH = 260;
    const INVALID_FILE_ATTRIBUTES = @as(DWORD, 0xFFFFFFFF);
    const FILE_ATTRIBUTE_DIRECTORY = 0x10;
    const FILE_ATTRIBUTE_REPARSE_POINT = 0x400;

    const FILETIME = extern struct { dwLowDateTime: DWORD, dwHighDateTime: DWORD };
    const WIN32_FILE_ATTRIBUTE_DATA = extern struct {
        dwFileAttributes: DWORD,
        ftCreationTime: FILETIME,
        ftLastAccessTime: FILETIME,
        ftLastWriteTime: FILETIME,
        nFileSizeHigh: DWORD,
        nFileSizeLow: DWORD,
    };

    extern "kernel32" fn GetFileAttributesExW(lpFileName: LPCWSTR, fInfoLevelId: c_int, lpFileInformation: *WIN32_FILE_ATTRIBUTE_DATA) callconv(.winapi) BOOL;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
    extern "kernel32" fn GetFullPathNameW(lpFileName: LPCWSTR, nBufferLength: DWORD, lpBuffer: LPWSTR, lpFilePart: ?*?LPWSTR) callconv(.winapi) DWORD;
    extern "kernel32" fn SetCurrentDirectoryW(lpPathName: LPCWSTR) callconv(.winapi) BOOL;
    extern "kernel32" fn CreateDirectoryW(lpPathName: LPCWSTR, lpSecurityAttributes: ?*anyopaque) callconv(.winapi) BOOL;
};

extern "kernel32" fn WinExec(lpCmdLine: [*c]const u8, uCmdShow: c_uint) callconv(.winapi) c_uint;

// ── CRT functions for ftruncate ─────────────────────────────────────────
const FILE = opaque {};
extern "c" fn _fileno(stream: *FILE) c_int;
extern "c" fn _chsize_s(fd: c_int, size: c_longlong) c_int;

// ── Helpers ──────────────────────────────────────────────────────────────

fn buttonName(button: u8) [*c]const u8 {
    return switch (button) {
        SDL.SDL_BUTTON_LEFT => "left",
        SDL.SDL_BUTTON_MIDDLE => "middle",
        SDL.SDL_BUTTON_RIGHT => "right",
        SDL.SDL_BUTTON_X1 => "x",
        SDL.SDL_BUTTON_X2 => "y",
        else => "?",
    };
}

fn strToLower(buf: []u8) void {
    for (buf) |*ch| {
        if (ch.* >= 'A' and ch.* <= 'Z') ch.* = ch.* + 32;
    }
}

const numpad = [_][*c]const u8{ "end", "down", "pagedown", "left", "", "right", "home", "up", "pageup", "ins", "delete" };

fn getKeyName(e: *const SDL.SDL_Event, buf: *[64]u8) [*c]const u8 {
    const scancode = e.key.scancode;
    // Numpad with numlock off
    if (scancode >= SDL.SDL_SCANCODE_KP_1 and scancode <= SDL.SDL_SCANCODE_KP_1 + 10 and
        (e.key.mod & SDL.SDL_KMOD_NUM) == 0)
    {
        return numpad[scancode - SDL.SDL_SCANCODE_KP_1];
    }
    // Get key name based on layout
    const name: [*c]const u8 = if ((e.key.key < 128) or (e.key.key & SDL.SDLK_SCANCODE_MASK != 0))
        SDL.SDL_GetKeyName(e.key.key)
    else
        SDL.SDL_GetScancodeName(scancode);
    if (name == null) return "";
    // Copy to buf and lowercase
    const slice = std.mem.sliceTo(name, 0);
    const copy_len = @min(slice.len, buf.len - 1);
    @memcpy(buf[0..copy_len], slice[0..copy_len]);
    buf[copy_len] = 0;
    strToLower(buf[0..copy_len]);
    return @ptrCast(buf);
}

// ── Hit test ─────────────────────────────────────────────────────────────

const HitTestInfo = struct {
    title_height: c_int = 0,
    controls_width: c_int = 0,
    resize_border: c_int = 0,
};

var window_hit_info = HitTestInfo{};

fn hitTest(window: ?*SDL.SDL_Window, pt: [*c]const SDL.SDL_Point, data: ?*anyopaque) callconv(.c) SDL.SDL_HitTestResult {
    const info: *const HitTestInfo = @ptrCast(@alignCast(data));
    const resize_border = info.resize_border;
    const controls_width = info.controls_width;
    var w: c_int = 0;
    var h: c_int = 0;
    _ = SDL.SDL_GetWindowSize(window, &w, &h);

    const p = pt[0];
    if (p.y < info.title_height and p.x > resize_border and p.x < w - controls_width) {
        return SDL.SDL_HITTEST_DRAGGABLE;
    }
    if (p.x < resize_border and p.y < resize_border) return SDL.SDL_HITTEST_RESIZE_TOPLEFT;
    if (p.x > w - resize_border and p.y < resize_border) return SDL.SDL_HITTEST_RESIZE_TOPRIGHT;
    if (p.x > w - resize_border and p.y > h - resize_border) return SDL.SDL_HITTEST_RESIZE_BOTTOMRIGHT;
    if (p.x < w - resize_border and p.x > resize_border and p.y > h - resize_border) return SDL.SDL_HITTEST_RESIZE_BOTTOM;
    if (p.x < resize_border and p.y > h - resize_border) return SDL.SDL_HITTEST_RESIZE_BOTTOMLEFT;
    if (p.x < resize_border and p.y < h - resize_border and p.y > resize_border) return SDL.SDL_HITTEST_RESIZE_LEFT;

    return SDL.SDL_HITTEST_NORMAL;
}

// ── Event polling ────────────────────────────────────────────────────────

fn f_poll_event(L: ?*lua.lua_State) callconv(.c) c_int {
    var buf: [64]u8 = undefined;
    var e: SDL.SDL_Event = undefined;
    var event_plus: SDL.SDL_Event = undefined;

    while (true) {
        if (!SDL.SDL_PollEvent(&e)) return 0;

        switch (e.type) {
            SDL.SDL_EVENT_QUIT => {
                _ = lua.lua_pushstring(L, "quit");
                return 1;
            },
            SDL.SDL_EVENT_WINDOW_RESIZED => {
                const win = renderer.findWindowFromId(e.window.windowID);
                if (win) |w| rw.resizeSurface(w);
                _ = lua.lua_pushstring(L, "resized");
                lua.lua_pushinteger(L, e.window.data1);
                lua.lua_pushinteger(L, e.window.data2);
                return 3;
            },
            SDL.SDL_EVENT_WINDOW_EXPOSED => {
                rencache.invalidate();
                _ = lua.lua_pushstring(L, "exposed");
                return 1;
            },
            SDL.SDL_EVENT_WINDOW_MINIMIZED => {
                _ = lua.lua_pushstring(L, "minimized");
                return 1;
            },
            SDL.SDL_EVENT_WINDOW_MAXIMIZED => {
                _ = lua.lua_pushstring(L, "maximized");
                return 1;
            },
            SDL.SDL_EVENT_WINDOW_RESTORED => {
                _ = lua.lua_pushstring(L, "restored");
                return 1;
            },
            SDL.SDL_EVENT_WINDOW_MOUSE_LEAVE => {
                _ = lua.lua_pushstring(L, "mouseleft");
                return 1;
            },
            SDL.SDL_EVENT_WINDOW_FOCUS_LOST => {
                _ = lua.lua_pushstring(L, "focuslost");
                return 1;
            },
            SDL.SDL_EVENT_WINDOW_FOCUS_GAINED => {
                SDL.SDL_FlushEvent(SDL.SDL_EVENT_KEY_DOWN);
                continue;
            },
            SDL.SDL_EVENT_DROP_FILE => {
                const win = renderer.findWindowFromId(e.drop.windowID);
                var mx: f32 = 0;
                var my: f32 = 0;
                _ = SDL.SDL_GetMouseState(&mx, &my);
                _ = lua.lua_pushstring(L, "filedropped");
                _ = lua.lua_pushstring(L, e.drop.data);
                const sx: f32 = if (win) |w| w.scale_x else 0;
                const sy: f32 = if (win) |w| w.scale_y else 0;
                lua.lua_pushinteger(L, @intFromFloat(mx * sx));
                lua.lua_pushinteger(L, @intFromFloat(my * sy));
                return 4;
            },
            SDL.SDL_EVENT_KEY_DOWN => {
                _ = lua.lua_pushstring(L, "keypressed");
                _ = lua.lua_pushstring(L, getKeyName(&e, &buf));
                return 2;
            },
            SDL.SDL_EVENT_KEY_UP => {
                _ = lua.lua_pushstring(L, "keyreleased");
                _ = lua.lua_pushstring(L, getKeyName(&e, &buf));
                return 2;
            },
            SDL.SDL_EVENT_TEXT_INPUT => {
                _ = lua.lua_pushstring(L, "textinput");
                _ = lua.lua_pushstring(L, e.text.text);
                return 2;
            },
            SDL.SDL_EVENT_TEXT_EDITING => {
                _ = lua.lua_pushstring(L, "textediting");
                _ = lua.lua_pushstring(L, e.edit.text);
                lua.lua_pushinteger(L, e.edit.start);
                lua.lua_pushinteger(L, e.edit.length);
                return 4;
            },
            SDL.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                if (e.button.button == 1) _ = SDL.SDL_CaptureMouse(true);
                const win = renderer.findWindowFromId(e.button.windowID);
                _ = lua.lua_pushstring(L, "mousepressed");
                _ = lua.lua_pushstring(L, buttonName(e.button.button));
                const sx: f32 = if (win) |w| w.scale_x else 1;
                const sy: f32 = if (win) |w| w.scale_y else 1;
                lua.lua_pushinteger(L, @intFromFloat(e.button.x * sx));
                lua.lua_pushinteger(L, @intFromFloat(e.button.y * sy));
                lua.lua_pushinteger(L, e.button.clicks);
                return 5;
            },
            SDL.SDL_EVENT_MOUSE_BUTTON_UP => {
                if (e.button.button == 1) _ = SDL.SDL_CaptureMouse(false);
                const win = renderer.findWindowFromId(e.button.windowID);
                _ = lua.lua_pushstring(L, "mousereleased");
                _ = lua.lua_pushstring(L, buttonName(e.button.button));
                const sx: f32 = if (win) |w| w.scale_x else 1;
                const sy: f32 = if (win) |w| w.scale_y else 1;
                lua.lua_pushinteger(L, @intFromFloat(e.button.x * sx));
                lua.lua_pushinteger(L, @intFromFloat(e.button.y * sy));
                return 4;
            },
            SDL.SDL_EVENT_MOUSE_MOTION => {
                SDL.SDL_PumpEvents();
                while (SDL.SDL_PeepEvents(&event_plus, 1, SDL.SDL_GETEVENT, SDL.SDL_EVENT_MOUSE_MOTION, SDL.SDL_EVENT_MOUSE_MOTION) > 0) {
                    e.motion.x = event_plus.motion.x;
                    e.motion.y = event_plus.motion.y;
                    e.motion.xrel += event_plus.motion.xrel;
                    e.motion.yrel += event_plus.motion.yrel;
                }
                const win = renderer.findWindowFromId(e.motion.windowID);
                _ = lua.lua_pushstring(L, "mousemoved");
                const sx: f32 = if (win) |w| w.scale_x else 1;
                const sy: f32 = if (win) |w| w.scale_y else 1;
                lua.lua_pushinteger(L, @intFromFloat(e.motion.x * sx));
                lua.lua_pushinteger(L, @intFromFloat(e.motion.y * sy));
                lua.lua_pushinteger(L, @intFromFloat(e.motion.xrel * sx));
                lua.lua_pushinteger(L, @intFromFloat(e.motion.yrel * sy));
                return 5;
            },
            SDL.SDL_EVENT_MOUSE_WHEEL => {
                _ = lua.lua_pushstring(L, "mousewheel");
                lua.lua_pushnumber(L, e.wheel.y);
                lua.lua_pushnumber(L, -e.wheel.x);
                return 3;
            },
            SDL.SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED,
            SDL.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED,
            => {
                const win = renderer.findWindowFromId(e.window.windowID);
                if (win) |w| rw.resizeSurface(w);
                continue;
            },
            else => continue,
        }
    }
}

fn f_wait_event(L: ?*lua.lua_State) callconv(.c) c_int {
    const nargs = lua.lua_gettop(L);
    if (nargs >= 1) {
        var n = lua.luaL_checknumber(L, 1);
        if (n < 0) n = 0;
        lua.lua_pushboolean(L, @intFromBool(SDL.SDL_WaitEventTimeout(null, @intFromFloat(n * 1000))));
    } else {
        lua.lua_pushboolean(L, @intFromBool(SDL.SDL_WaitEvent(null)));
    }
    return 1;
}

// ── Cursor ───────────────────────────────────────────────────────────────

var cursor_cache: [5]?*SDL.SDL_Cursor = .{ null, null, null, null, null };

fn f_set_cursor(L: ?*lua.lua_State) callconv(.c) c_int {
    const cursor_opts = [_][*c]const u8{ "arrow", "ibeam", "sizeh", "sizev", "hand" };
    const cursor_enums = [_]SDL.SDL_SystemCursor{
        SDL.SDL_SYSTEM_CURSOR_DEFAULT,
        SDL.SDL_SYSTEM_CURSOR_TEXT,
        SDL.SDL_SYSTEM_CURSOR_EW_RESIZE,
        SDL.SDL_SYSTEM_CURSOR_NS_RESIZE,
        SDL.SDL_SYSTEM_CURSOR_POINTER,
    };
    const opt: usize = @intCast(lua.luaL_checkoption(L, 1, "arrow", &cursor_opts));
    if (cursor_cache[opt] == null) {
        cursor_cache[opt] = SDL.SDL_CreateSystemCursor(cursor_enums[opt]);
    }
    _ = SDL.SDL_SetCursor(cursor_cache[opt]);
    return 0;
}

// ── Window management (single-window API — uses global target window) ───

fn getGlobalWindow() ?*SDL.SDL_Window {
    const win = renderer.getTargetWindow() orelse return null;
    return win.window;
}

fn f_set_window_title(L: ?*lua.lua_State) callconv(.c) c_int {
    const sdl_win = getGlobalWindow() orelse return 0;
    const title = c.luaCheckString(L, 1);
    _ = SDL.SDL_SetWindowTitle(sdl_win, title);
    return 0;
}

fn f_set_window_mode(L: ?*lua.lua_State) callconv(.c) c_int {
    const sdl_win = getGlobalWindow() orelse return 0;
    const mode_opts = [_][*c]const u8{ "normal", "minimized", "maximized", "fullscreen" };
    const opt = lua.luaL_checkoption(L, 1, "normal", &mode_opts);
    _ = SDL.SDL_SetWindowFullscreen(sdl_win, opt == 3);
    if (opt == 0) _ = SDL.SDL_RestoreWindow(sdl_win);
    if (opt == 2) _ = SDL.SDL_MaximizeWindow(sdl_win);
    if (opt == 1) _ = SDL.SDL_MinimizeWindow(sdl_win);
    return 0;
}

fn f_get_window_mode(L: ?*lua.lua_State) callconv(.c) c_int {
    const sdl_win = getGlobalWindow() orelse return 0;
    const flags = SDL.SDL_GetWindowFlags(sdl_win);
    if (flags & SDL.SDL_WINDOW_FULLSCREEN != 0) {
        _ = lua.lua_pushstring(L, "fullscreen");
    } else if (flags & SDL.SDL_WINDOW_MINIMIZED != 0) {
        _ = lua.lua_pushstring(L, "minimized");
    } else if (flags & SDL.SDL_WINDOW_MAXIMIZED != 0) {
        _ = lua.lua_pushstring(L, "maximized");
    } else {
        _ = lua.lua_pushstring(L, "normal");
    }
    return 1;
}

fn f_set_window_bordered(L: ?*lua.lua_State) callconv(.c) c_int {
    const sdl_win = getGlobalWindow() orelse return 0;
    _ = SDL.SDL_SetWindowBordered(sdl_win, lua.lua_toboolean(L, 1) != 0);
    return 0;
}

fn f_set_window_hit_test(L: ?*lua.lua_State) callconv(.c) c_int {
    const sdl_win = getGlobalWindow() orelse return 0;
    if (lua.lua_gettop(L) == 0) {
        _ = SDL.SDL_SetWindowHitTest(sdl_win, null, null);
        return 0;
    }
    window_hit_info.title_height = @intFromFloat(lua.luaL_checknumber(L, 1));
    window_hit_info.controls_width = @intFromFloat(lua.luaL_checknumber(L, 2));
    window_hit_info.resize_border = @intFromFloat(lua.luaL_checknumber(L, 3));
    _ = SDL.SDL_SetWindowHitTest(sdl_win, hitTest, @ptrCast(&window_hit_info));
    return 0;
}

fn f_get_window_size(L: ?*lua.lua_State) callconv(.c) c_int {
    const sdl_win = getGlobalWindow() orelse return 0;
    var w: c_int = 0;
    var h: c_int = 0;
    var x: c_int = 0;
    var y: c_int = 0;
    _ = SDL.SDL_GetWindowSize(sdl_win, &w, &h);
    _ = SDL.SDL_GetWindowPosition(sdl_win, &x, &y);
    lua.lua_pushinteger(L, w);
    lua.lua_pushinteger(L, h);
    lua.lua_pushinteger(L, x);
    lua.lua_pushinteger(L, y);
    return 4;
}

fn f_set_window_size(L: ?*lua.lua_State) callconv(.c) c_int {
    const win = renderer.getTargetWindow() orelse return 0;
    const w: c_int = @intFromFloat(lua.luaL_checknumber(L, 1));
    const h: c_int = @intFromFloat(lua.luaL_checknumber(L, 2));
    const x: c_int = @intFromFloat(lua.luaL_checknumber(L, 3));
    const y: c_int = @intFromFloat(lua.luaL_checknumber(L, 4));
    _ = SDL.SDL_SetWindowSize(win.window, w, h);
    _ = SDL.SDL_SetWindowPosition(win.window, x, y);
    rw.resizeSurface(win);
    return 0;
}

fn f_window_has_focus(L: ?*lua.lua_State) callconv(.c) c_int {
    const sdl_win = getGlobalWindow() orelse return 0;
    const flags = SDL.SDL_GetWindowFlags(sdl_win);
    lua.lua_pushboolean(L, @intFromBool(flags & SDL.SDL_WINDOW_INPUT_FOCUS != 0));
    return 1;
}

fn f_raise_window(_: ?*lua.lua_State) callconv(.c) c_int {
    const sdl_win = getGlobalWindow() orelse return 0;
    _ = SDL.SDL_RaiseWindow(sdl_win);
    return 0;
}

fn f_set_window_opacity(L: ?*lua.lua_State) callconv(.c) c_int {
    const sdl_win = getGlobalWindow() orelse return 0;
    const n: f32 = @floatCast(lua.luaL_checknumber(L, 1));
    const r = SDL.SDL_SetWindowOpacity(sdl_win, n);
    lua.lua_pushboolean(L, @intFromBool(r));
    return 1;
}

fn f_set_text_input_rect(L: ?*lua.lua_State) callconv(.c) c_int {
    const sdl_win = getGlobalWindow() orelse return 0;
    var rect: SDL.SDL_Rect = .{
        .x = @intFromFloat(lua.luaL_checknumber(L, 1)),
        .y = @intFromFloat(lua.luaL_checknumber(L, 2)),
        .w = @intFromFloat(lua.luaL_checknumber(L, 3)),
        .h = @intFromFloat(lua.luaL_checknumber(L, 4)),
    };
    _ = SDL.SDL_SetTextInputArea(sdl_win, &rect, 0);
    return 0;
}

fn f_clear_ime(_: ?*lua.lua_State) callconv(.c) c_int {
    const sdl_win = getGlobalWindow() orelse return 0;
    _ = SDL.SDL_ClearComposition(sdl_win);
    return 0;
}

fn f_text_input(L: ?*lua.lua_State) callconv(.c) c_int {
    const sdl_win = getGlobalWindow() orelse return 0;
    if (lua.lua_toboolean(L, 1) != 0) {
        _ = SDL.SDL_StartTextInput(sdl_win);
    } else {
        _ = SDL.SDL_StopTextInput(sdl_win);
    }
    return 0;
}

// ── System functions ─────────────────────────────────────────────────────

fn f_show_fatal_error(L: ?*lua.lua_State) callconv(.c) c_int {
    const title = c.luaCheckString(L, 1);
    const msg = c.luaCheckString(L, 2);
    _ = SDL.SDL_ShowSimpleMessageBox(SDL.SDL_MESSAGEBOX_ERROR, title, msg, null);
    return 0;
}

fn f_get_time(L: ?*lua.lua_State) callconv(.c) c_int {
    const ticks = SDL.SDL_GetPerformanceCounter();
    const freq = SDL.SDL_GetPerformanceFrequency();
    lua.lua_pushnumber(L, @as(f64, @floatFromInt(ticks)) / @as(f64, @floatFromInt(freq)));
    return 1;
}

fn f_sleep(L: ?*lua.lua_State) callconv(.c) c_int {
    var n = lua.luaL_checknumber(L, 1);
    if (n < 0) n = 0;
    SDL.SDL_Delay(@intFromFloat(n * 1000));
    return 0;
}

fn f_get_process_id(L: ?*lua.lua_State) callconv(.c) c_int {
    lua.lua_pushinteger(L, @intCast(win32.GetCurrentProcessId()));
    return 1;
}

fn f_exec(L: ?*lua.lua_State) callconv(.c) c_int {
    var len: usize = 0;
    const cmd = lua.luaL_checklstring(L, 1, &len);
    if (cmd == null) return 0;
    const slice = cmd[0..len];
    // Create command string with shell wrapper
    const alloc = std.heap.c_allocator;
    const buf = alloc.alloc(u8, len + 32) catch return 0;
    defer alloc.free(buf);
    const written = std.fmt.bufPrint(buf, "cmd /c \"{s}\"", .{slice}) catch return 0;
    buf[written.len] = 0;
    // Use WinExec for Windows
    _ = WinExec(@ptrCast(buf.ptr), 0);
    return 0;
}

fn f_setenv(L: ?*lua.lua_State) callconv(.c) c_int {
    const key = c.luaCheckString(L, 1);
    const val = c.luaCheckString(L, 2);
    lua.lua_pushboolean(L, @intFromBool(SDL.SDL_setenv_unsafe(key, val, 1) == 0));
    return 1;
}

// ── Filesystem ───────────────────────────────────────────────────────────

fn f_absolute_path(L: ?*lua.lua_State) callconv(.c) c_int {
    const path = c.luaCheckString(L, 1);
    const path_slice = std.mem.sliceTo(path, 0);
    // Convert UTF-8 to wide string
    var wpath_buf: [win32.MAX_PATH * 2]u16 = undefined;
    const wpath_len = std.unicode.utf8ToUtf16Le(&wpath_buf, path_slice) catch return 0;
    wpath_buf[wpath_len] = 0;
    const wpath: win32.LPCWSTR = @ptrCast(&wpath_buf);

    var wfull_buf: [win32.MAX_PATH * 2]u16 = undefined;
    const wfull_ptr: win32.LPWSTR = @ptrCast(&wfull_buf);
    const result = win32.GetFullPathNameW(wpath, win32.MAX_PATH * 2, wfull_ptr, null);
    if (result == 0) return 0;

    // Convert wide back to UTF-8
    var utf8_buf: [win32.MAX_PATH * 4]u8 = undefined;
    const wslice = wfull_buf[0..result];
    const utf8_len = std.unicode.utf16LeToUtf8(&utf8_buf, wslice) catch return 0;
    utf8_buf[utf8_len] = 0;
    _ = lua.lua_pushlstring(L, &utf8_buf, utf8_len);
    return 1;
}

fn f_chdir(L: ?*lua.lua_State) callconv(.c) c_int {
    const path = c.luaCheckString(L, 1);
    const path_slice = std.mem.sliceTo(path, 0);
    var wpath_buf: [win32.MAX_PATH * 2]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(&wpath_buf, path_slice) catch
        return lua.luaL_error(L, "invalid path encoding");
    wpath_buf[wlen] = 0;
    if (win32.SetCurrentDirectoryW(@ptrCast(&wpath_buf)) == 0)
        return lua.luaL_error(L, "chdir() failed");
    return 0;
}

fn f_list_dir(L: ?*lua.lua_State) callconv(.c) c_int {
    const path = c.luaCheckString(L, 1);
    lua.lua_newtable(L);
    if (SDL.SDL_EnumerateDirectory(path, listDirCallback, @ptrCast(@constCast(L)))) {
        return 1;
    } else {
        lua.lua_pushnil(L);
        _ = lua.lua_pushstring(L, SDL.SDL_GetError());
        return 2;
    }
}

fn listDirCallback(userdata: ?*anyopaque, _: [*c]const u8, fname: [*c]const u8) callconv(.c) SDL.SDL_EnumerationResult {
    const L: ?*lua.lua_State = @ptrCast(@alignCast(userdata));
    const len: c_int = @intCast(lua.lua_rawlen(L, -1));
    _ = lua.lua_pushstring(L, fname);
    lua.lua_rawseti(L, -2, len + 1);
    return SDL.SDL_ENUM_CONTINUE;
}

fn f_mkdir(L: ?*lua.lua_State) callconv(.c) c_int {
    const path = c.luaCheckString(L, 1);
    const path_slice = std.mem.sliceTo(path, 0);
    var wpath_buf: [win32.MAX_PATH * 2]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(&wpath_buf, path_slice) catch {
        lua.lua_pushboolean(L, 0);
        _ = lua.lua_pushstring(L, "invalid path encoding");
        return 2;
    };
    wpath_buf[wlen] = 0;
    if (win32.CreateDirectoryW(@ptrCast(&wpath_buf), null) == 0) {
        lua.lua_pushboolean(L, 0);
        _ = lua.lua_pushstring(L, "mkdir failed");
        return 2;
    }
    lua.lua_pushboolean(L, 1);
    return 1;
}

fn f_rmdir(L: ?*lua.lua_State) callconv(.c) c_int {
    const path = c.luaCheckString(L, 1);
    lua.lua_pushboolean(L, @intFromBool(SDL.SDL_RemovePath(path)));
    if (lua.lua_toboolean(L, -1) == 0) {
        _ = lua.lua_pushstring(L, SDL.SDL_GetError());
        return 2;
    }
    return 1;
}

fn f_get_file_info(L: ?*lua.lua_State) callconv(.c) c_int {
    const path = c.luaCheckString(L, 1);
    const path_slice = std.mem.sliceTo(path, 0);

    lua.lua_newtable(L);

    var wpath_buf: [win32.MAX_PATH * 2]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(&wpath_buf, path_slice) catch {
        lua.lua_pushnil(L);
        _ = lua.lua_pushstring(L, "invalid path encoding");
        return 2;
    };
    wpath_buf[wlen] = 0;
    const wpath: win32.LPCWSTR = @ptrCast(&wpath_buf);

    var data: win32.WIN32_FILE_ATTRIBUTE_DATA = undefined;
    if (win32.GetFileAttributesExW(wpath, 0, &data) == 0) {
        lua.lua_pushnil(L);
        _ = lua.lua_pushstring(L, "file not found");
        return 2;
    }

    // modified time
    const TICKS_PER_MS: u64 = 10000;
    const EPOCH_DIFF: i64 = 11644473600000;
    const ft_low: u64 = data.ftLastWriteTime.dwLowDateTime;
    const ft_high: u64 = @as(u64, data.ftLastWriteTime.dwHighDateTime) << 32;
    const ft_val: i64 = @intCast(ft_low | ft_high);
    const modified: f64 = @as(f64, @floatFromInt(@divTrunc(ft_val, @as(i64, TICKS_PER_MS)) - EPOCH_DIFF)) / 1000.0;
    lua.lua_pushnumber(L, modified);
    lua.lua_setfield(L, -2, "modified");

    // size
    const size: u64 = @as(u64, data.nFileSizeHigh) << 32 | data.nFileSizeLow;
    lua.lua_pushinteger(L, @intCast(size));
    lua.lua_setfield(L, -2, "size");

    // type
    if (data.dwFileAttributes & win32.FILE_ATTRIBUTE_DIRECTORY != 0) {
        _ = lua.lua_pushstring(L, "dir");
    } else {
        _ = lua.lua_pushstring(L, "file");
    }
    lua.lua_setfield(L, -2, "type");

    // symlink
    lua.lua_pushboolean(L, @intFromBool(data.dwFileAttributes & win32.FILE_ATTRIBUTE_DIRECTORY != 0 and
        data.dwFileAttributes & win32.FILE_ATTRIBUTE_REPARSE_POINT != 0));
    lua.lua_setfield(L, -2, "symlink");

    return 1;
}

fn f_get_fs_type(L: ?*lua.lua_State) callconv(.c) c_int {
    _ = lua.lua_pushstring(L, "unknown");
    return 1;
}

// ── Clipboard ────────────────────────────────────────────────────────────

fn f_get_clipboard(L: ?*lua.lua_State) callconv(.c) c_int {
    const text = SDL.SDL_GetClipboardText();
    if (text == null) return 0;
    // On Windows, convert \r\n to \n
    _ = lua.luaL_gsub(L, text, "\r\n", "\n");
    SDL.SDL_free(@constCast(@ptrCast(text)));
    return 1;
}

fn f_set_clipboard(L: ?*lua.lua_State) callconv(.c) c_int {
    const text = c.luaCheckString(L, 1);
    _ = SDL.SDL_SetClipboardText(text);
    return 0;
}

fn f_get_primary_selection(L: ?*lua.lua_State) callconv(.c) c_int {
    const text = SDL.SDL_GetPrimarySelectionText();
    if (text == null) return 0;
    _ = lua.lua_pushstring(L, text);
    SDL.SDL_free(@constCast(@ptrCast(text)));
    return 1;
}

fn f_set_primary_selection(L: ?*lua.lua_State) callconv(.c) c_int {
    const text = c.luaCheckString(L, 1);
    _ = SDL.SDL_SetPrimarySelectionText(text);
    return 0;
}

// ── Fuzzy match ──────────────────────────────────────────────────────────

fn f_fuzzy_match(L: ?*lua.lua_State) callconv(.c) c_int {
    var str_len: usize = 0;
    var ptn_len: usize = 0;
    const str = lua.luaL_checklstring(L, 1, &str_len);
    const ptn = lua.luaL_checklstring(L, 2, &ptn_len);
    if (str == null or ptn == null or str_len == 0 or ptn_len == 0) return 0;

    const files = lua.lua_gettop(L) > 2 and lua.lua_isboolean(L, 3) and lua.lua_toboolean(L, 3) != 0;
    var score: i32 = 0;
    var run: i32 = 0;
    const increment: i32 = if (files) -1 else 1;

    var si: i64 = if (files) @as(i64, @intCast(str_len)) - 1 else 0;
    var pi: i64 = if (files) @as(i64, @intCast(ptn_len)) - 1 else 0;

    while (si >= 0 and si < @as(i64, @intCast(str_len)) and
        pi >= 0 and pi < @as(i64, @intCast(ptn_len)))
    {
        const sc = str[@intCast(si)];
        const pc = ptn[@intCast(pi)];
        // Skip spaces
        if (sc == ' ') {
            si += increment;
            continue;
        }
        if (pc == ' ') {
            pi += increment;
            continue;
        }
        const sc_lower: u8 = if (sc >= 'A' and sc <= 'Z') sc + 32 else sc;
        const pc_lower: u8 = if (pc >= 'A' and pc <= 'Z') pc + 32 else pc;
        if (sc_lower == pc_lower) {
            score += run * 10 - @as(i32, if (sc != pc) 1 else 0);
            run += 1;
            pi += increment;
        } else {
            score -= 10;
            run = 0;
        }
        si += increment;
    }
    // Check if entire pattern was matched
    if (pi >= 0 and pi < @as(i64, @intCast(ptn_len))) return 0;
    lua.lua_pushinteger(L, score - @as(i32, @intCast(str_len)) * 10);
    return 1;
}

// ── Path compare ─────────────────────────────────────────────────────────

fn f_path_compare(L: ?*lua.lua_State) callconv(.c) c_int {
    var len1: usize = 0;
    var len2: usize = 0;
    const path1 = lua.luaL_checklstring(L, 1, &len1);
    const type1_s = c.luaCheckString(L, 2);
    const path2 = lua.luaL_checklstring(L, 3, &len2);
    const type2_s = c.luaCheckString(L, 4);
    if (path1 == null or path2 == null) return 0;

    const t1_slice = std.mem.sliceTo(type1_s, 0);
    const t2_slice = std.mem.sliceTo(type2_s, 0);
    var type1: i32 = if (std.mem.eql(u8, t1_slice, "dir")) 0 else 1;
    var type2: i32 = if (std.mem.eql(u8, t2_slice, "dir")) 0 else 1;

    const p1 = path1[0..len1];
    const p2 = path2[0..len2];

    // Find common part
    var offset: usize = 0;
    const min_len = @min(len1, len2);
    for (0..min_len) |i| {
        if (p1[i] != p2[i]) break;
        if (p1[i] == '\\' or p1[i] == '/') offset = i + 1;
    }

    // Check if remainder has path separator (treat as dir)
    for (p1[offset..]) |ch| {
        if (ch == '\\' or ch == '/') { type1 = 0; break; }
    }
    for (p2[offset..]) |ch| {
        if (ch == '\\' or ch == '/') { type2 = 0; break; }
    }

    if (type1 != type2) {
        lua.lua_pushboolean(L, @intFromBool(type1 < type2));
        return 1;
    }

    // Alphabetical comparison with natural number sorting
    var i = offset;
    var j = offset;
    var cfr: i32 = -1;
    const same_len = len1 == len2;
    while (i <= len1 and j <= len2) : ({
        i += 1;
        j += 1;
    }) {
        const c1: u8 = if (i < len1) p1[i] else 0;
        const c2: u8 = if (j < len2) p2[j] else 0;
        if (c1 == 0 or c2 == 0) {
            if (cfr < 0) cfr = 0;
            if (!same_len) cfr = @intFromBool(c1 == 0);
        } else if (isDigit(c1) and isDigit(c2)) {
            // Natural number comparison
            var d1: usize = 0;
            var d2: usize = 0;
            var ii: usize = 0;
            var ij: usize = 0;
            while (i + ii < len1 and isDigit(p1[i + ii])) : (ii += 1) {}
            while (j + ij < len2 and isDigit(p2[j + ij])) : (ij += 1) {}
            for (0..ii) |ai| d1 = d1 * 10 + (p1[i + ai] - '0');
            for (0..ij) |aj| d2 = d2 * 10 + (p2[j + aj] - '0');
            if (d1 == d2) continue;
            cfr = @intFromBool(d1 < d2);
        } else if (c1 == c2) {
            continue;
        } else if (c1 == '\\' or c1 == '/' or c2 == '\\' or c2 == '/') {
            cfr = @intFromBool(c1 == '\\' or c1 == '/');
        } else {
            const a: u8 = if (c1 >= 'A' and c1 <= 'Z') c1 + 32 else c1;
            const b: u8 = if (c2 >= 'A' and c2 <= 'Z') c2 + 32 else c2;
            if (a == b) {
                if (same_len and cfr < 0) cfr = @intFromBool(c1 > c2);
                continue;
            }
            cfr = @intFromBool(a < b);
        }
        break;
    }
    lua.lua_pushboolean(L, cfr);
    return 1;
}

fn isDigit(ch: u8) bool {
    return ch >= '0' and ch <= '9';
}

// ── Native plugin loading (stub) ─────────────────────────────────────────

fn f_load_native_plugin(L: ?*lua.lua_State) callconv(.c) c_int {
    _ = c.luaCheckString(L, 1); // name
    const path = c.luaCheckString(L, 2);
    const lib_handle = SDL.SDL_LoadObject(path);
    if (lib_handle == null) {
        _ = lua.lua_pushstring(L, SDL.SDL_GetError());
        return lua.lua_error(L);
    }

    // Try glyph entrypoint first, then lite-xl compat, then standard entrypoint
    const name_raw = c.luaCheckString(L, 1);
    const name_slice = std.mem.sliceTo(name_raw, 0);
    // Find basename after last '.'
    var basename = name_slice;
    for (name_slice, 0..) |ch, idx| {
        if (ch == '.') basename = name_slice[idx + 1 ..];
    }

    var entry_buf: [512]u8 = undefined;
    const entry_name = std.fmt.bufPrint(&entry_buf, "luaopen_glyph_{s}", .{basename}) catch return 0;
    entry_buf[entry_name.len] = 0;

    const ext_fn = SDL.SDL_LoadFunction(lib_handle, @ptrCast(entry_buf[0..entry_name.len :0]));
    if (ext_fn != null) {
        const func: *const fn (?*lua.lua_State, ?*anyopaque) callconv(.c) c_int = @ptrCast(ext_fn);
        return func(L, null);
    }

    const entry_name2 = std.fmt.bufPrint(&entry_buf, "luaopen_{s}", .{basename}) catch return 0;
    entry_buf[entry_name2.len] = 0;
    const std_fn = SDL.SDL_LoadFunction(lib_handle, @ptrCast(entry_buf[0..entry_name2.len :0]));
    if (std_fn != null) {
        const func: *const fn (?*lua.lua_State) callconv(.c) c_int = @ptrCast(std_fn);
        return func(L);
    }

    return lua.luaL_error(L, "Unable to load native plugin");
}

// ── File dialogs (stub) ──────────────────────────────────────────────────

fn f_open_file_dialog(_: ?*lua.lua_State) callconv(.c) c_int {
    return 0;
}
fn f_save_file_dialog(_: ?*lua.lua_State) callconv(.c) c_int {
    return 0;
}
fn f_open_directory_dialog(_: ?*lua.lua_State) callconv(.c) c_int {
    return 0;
}

fn f_get_sandbox(L: ?*lua.lua_State) callconv(.c) c_int {
    _ = lua.lua_pushstring(L, "none");
    return 1;
}

fn f_ftruncate(L: ?*lua.lua_State) callconv(.c) c_int {
    // arg 1: Lua file handle (io.open result), arg 2: optional length (default 0)
    const ud = lua.luaL_checkudata(L, 1, lua.LUA_FILEHANDLE);
    if (ud == null) return 0;
    const len: i64 = if (lua.lua_gettop(L) >= 2) @intCast(lua.luaL_checkinteger(L, 2)) else 0;

    // luaL_Stream first field is FILE *f
    const file: *FILE = (@as(*?*FILE, @ptrCast(@alignCast(ud)))).* orelse {
        lua.lua_pushboolean(L, 0);
        _ = lua.lua_pushstring(L, "invalid file handle");
        return 2;
    };
    const fd = _fileno(file);
    if (fd < 0 or _chsize_s(fd, len) != 0) {
        lua.lua_pushboolean(L, 0);
        _ = lua.lua_pushstring(L, "ftruncate failed");
        return 2;
    }
    lua.lua_pushboolean(L, 1);
    return 1;
}

// ── Module registration ──────────────────────────────────────────────────

const funcs = [_]lua.luaL_Reg{
    .{ .name = "poll_event", .func = f_poll_event },
    .{ .name = "wait_event", .func = f_wait_event },
    .{ .name = "set_cursor", .func = f_set_cursor },
    .{ .name = "set_window_title", .func = f_set_window_title },
    .{ .name = "set_window_mode", .func = f_set_window_mode },
    .{ .name = "get_window_mode", .func = f_get_window_mode },
    .{ .name = "set_window_bordered", .func = f_set_window_bordered },
    .{ .name = "set_window_hit_test", .func = f_set_window_hit_test },
    .{ .name = "get_window_size", .func = f_get_window_size },
    .{ .name = "set_window_size", .func = f_set_window_size },
    .{ .name = "set_text_input_rect", .func = f_set_text_input_rect },
    .{ .name = "clear_ime", .func = f_clear_ime },
    .{ .name = "window_has_focus", .func = f_window_has_focus },
    .{ .name = "raise_window", .func = f_raise_window },
    .{ .name = "show_fatal_error", .func = f_show_fatal_error },
    .{ .name = "rmdir", .func = f_rmdir },
    .{ .name = "chdir", .func = f_chdir },
    .{ .name = "mkdir", .func = f_mkdir },
    .{ .name = "list_dir", .func = f_list_dir },
    .{ .name = "absolute_path", .func = f_absolute_path },
    .{ .name = "get_file_info", .func = f_get_file_info },
    .{ .name = "get_clipboard", .func = f_get_clipboard },
    .{ .name = "set_clipboard", .func = f_set_clipboard },
    .{ .name = "get_primary_selection", .func = f_get_primary_selection },
    .{ .name = "set_primary_selection", .func = f_set_primary_selection },
    .{ .name = "get_process_id", .func = f_get_process_id },
    .{ .name = "get_time", .func = f_get_time },
    .{ .name = "sleep", .func = f_sleep },
    .{ .name = "exec", .func = f_exec },
    .{ .name = "fuzzy_match", .func = f_fuzzy_match },
    .{ .name = "set_window_opacity", .func = f_set_window_opacity },
    .{ .name = "load_native_plugin", .func = f_load_native_plugin },
    .{ .name = "path_compare", .func = f_path_compare },
    .{ .name = "get_fs_type", .func = f_get_fs_type },
    .{ .name = "text_input", .func = f_text_input },
    .{ .name = "setenv", .func = f_setenv },
    .{ .name = "ftruncate", .func = f_ftruncate },
    .{ .name = "open_file_dialog", .func = f_open_file_dialog },
    .{ .name = "save_file_dialog", .func = f_save_file_dialog },
    .{ .name = "open_directory_dialog", .func = f_open_directory_dialog },
    .{ .name = "get_sandbox", .func = f_get_sandbox },
    .{ .name = null, .func = null },
};

pub fn luaopen(L: ?*lua.lua_State) callconv(.c) c_int {
    c.luaNewLib(L, &funcs);
    return 1;
}
