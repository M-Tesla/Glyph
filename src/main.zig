const std = @import("std");
const c = @import("c.zig");

const api = @import("api/api.zig");
const renderer = @import("renderer.zig");
const rencache = @import("rencache.zig");
const rw = @import("renwindow.zig");

// ── Platform constants ──────────────────────────────────────────────────
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;

const GLYPH_PATHSEP_PATTERN = if (is_windows) "\\\\" else "/";
const GLYPH_NONPATHSEP_PATTERN = if (is_windows) "[^\\\\]+" else "[^/]+";
const GLYPH_OS_HOME = if (is_windows) "USERPROFILE" else "HOME";
const ARCH_TUPLE = @tagName(builtin.cpu.arch) ++ "-" ++ @tagName(builtin.os.tag);
const VERSION = "0.1.0";

const lua = c.lua;
const SDL = c.SDL;

// ── Entry point ─────────────────────────────────────────────────────────
pub fn main() !void {
    // Initialize SDL3
    if (!SDL.SDL_Init(SDL.SDL_INIT_EVENTS)) {
        const err_msg = SDL.SDL_GetError();
        std.log.err("Error initializing SDL: {s}", .{err_msg});
        std.process.exit(1);
    }
    defer SDL.SDL_Quit();

    SDL.SDL_SetEventEnabled(SDL.SDL_EVENT_DROP_FILE, true);
    SDL.SDL_SetEventEnabled(SDL.SDL_EVENT_TEXT_INPUT, true);
    SDL.SDL_SetEventEnabled(SDL.SDL_EVENT_TEXT_EDITING, true);

    // Initialize renderer (FreeType + SDL video)
    if (renderer.init() != 0) {
        std.log.err("Failed to initialize renderer", .{});
        std.process.exit(1);
    }
    defer renderer.deinit();

    // Initialize SDL video subsystem
    if (renderer.videoInit() != 0) {
        std.log.err("Failed to initialize SDL video", .{});
        std.process.exit(1);
    }

    // Create the main window
    var width: c_int = 1024;
    var height: c_int = 768;
    {
        const display = SDL.SDL_GetPrimaryDisplay();
        const dm = SDL.SDL_GetCurrentDisplayMode(display);
        if (dm != null) {
            width = @intFromFloat(@as(f32, @floatFromInt(dm.*.w)) * 0.8);
            height = @intFromFloat(@as(f32, @floatFromInt(dm.*.h)) * 0.8);
        }
    }

    const sdl_window = SDL.SDL_CreateWindow(
        "Glyph",
        width,
        height,
        SDL.SDL_WINDOW_RESIZABLE | SDL.SDL_WINDOW_HIGH_PIXEL_DENSITY,
    );
    if (sdl_window == null) {
        std.log.err("Error creating window: {s}", .{SDL.SDL_GetError()});
        std.process.exit(1);
    }
    const ren_window = renderer.create(sdl_window.?);
    renderer.setTargetWindow(ren_window);

    // Show window immediately (SDL3 creates windows hidden by default)
    _ = SDL.SDL_SetWindowPosition(sdl_window.?, SDL.SDL_WINDOWPOS_CENTERED, SDL.SDL_WINDOWPOS_CENTERED);
    _ = SDL.SDL_ShowWindow(sdl_window.?);
    _ = SDL.SDL_RaiseWindow(sdl_window.?);
    _ = SDL.SDL_SetWindowFocusable(sdl_window.?, true);

    // Enable text input events (SDL3 requires explicit activation)
    _ = SDL.SDL_StartTextInput(sdl_window.?);

    // Main loop with restart support
    var has_restarted: bool = false;
    var restart_count: u32 = 0;

    while (restart_count < 3) {
        // Create Lua state
        const L: *lua.lua_State = lua.luaL_newstate() orelse {
            std.log.err("Failed to create Lua state", .{});
            std.process.exit(1);
        };

        // Open standard Lua libraries
        lua.luaL_openlibs(L);

        // Register our native API modules
        api.loadLibs(L);

        // Set global variables
        setLuaGlobals(L, has_restarted);

        // Run the init code
        const restart = runInitCode(L);

        lua.lua_close(L);

        if (restart) {
            rencache.invalidate();
            has_restarted = true;
            restart_count += 1;
            continue;
        }
        break;
    }
}

// ── Set Lua global variables ────────────────────────────────────────────
fn setLuaGlobals(L: *lua.lua_State, has_restarted: bool) void {
    // ARGS table (from command line)
    const args = std.os.argv;
    lua.lua_createtable(L, @intCast(args.len), 0);
    for (args, 0..) |arg, i| {
        _ = lua.lua_pushstring(L, arg);
        lua.lua_rawseti(L, -2, @as(c_int, @intCast(i)) + 1);
    }
    lua.lua_setglobal(L, "ARGS");

    // PLATFORM
    _ = lua.lua_pushstring(L, SDL.SDL_GetPlatform());
    lua.lua_setglobal(L, "PLATFORM");

    // ARCH
    _ = lua.lua_pushstring(L, ARCH_TUPLE);
    lua.lua_setglobal(L, "ARCH");

    // RESTARTED
    lua.lua_pushboolean(L, @intFromBool(has_restarted));
    lua.lua_setglobal(L, "RESTARTED");

    // EXEFILE
    var buf: [2048]u8 = undefined;
    const exefile = getExeFilename(&buf);
    _ = lua.lua_pushstring(L, exefile.ptr);
    lua.lua_setglobal(L, "EXEFILE");
}

// ── Get executable path ─────────────────────────────────────────────────
fn getExeFilename(buf: *[2048]u8) [:0]const u8 {
    if (is_windows) {
        var wide_buf: [2048]u16 = undefined;
        const len = std.os.windows.kernel32.GetModuleFileNameW(null, &wide_buf, wide_buf.len);
        if (len > 0) {
            const utf8_len = std.unicode.utf16LeToUtf8(buf, wide_buf[0..len]) catch 0;
            buf[utf8_len] = 0;
            return buf[0..utf8_len :0];
        }
    } else {
        const link = std.fs.readLinkAbsoluteZ("/proc/self/exe", buf[0..2047]) catch "";
        buf[link.len] = 0;
        return buf[0..link.len :0];
    }
    buf[0] = 0;
    return buf[0..0 :0];
}

// ── Lua init code (bootstrap) ───────────────────────────────────────────
fn runInitCode(L: *lua.lua_State) bool {
    const init_code: [*:0]const u8 =
        "local core\n" ++
        "local ok, err = xpcall(function()\n" ++
        "  local match = require('utf8extra').match\n" ++
        "  HOME = os.getenv('" ++ GLYPH_OS_HOME ++ "')\n" ++
        "  local exedir = match(EXEFILE, '^(.*)" ++ GLYPH_PATHSEP_PATTERN ++ GLYPH_NONPATHSEP_PATTERN ++ "$')\n" ++
        "  local prefix = os.getenv('GLYPH_PREFIX') or match(exedir, '^(.*)" ++ GLYPH_PATHSEP_PATTERN ++ "bin$')\n" ++
        "  dofile((prefix and prefix .. '/share/glyph' or exedir .. '/data') .. '/core/start.lua')\n" ++
        "  core = require(os.getenv('GLYPH_RUNTIME') or 'core')\n" ++
        "  core.init()\n" ++
        "  core.run()\n" ++
        "end, function(e)\n" ++
        "  return tostring(e) .. '\\n' .. debug.traceback(nil, 2)\n" ++
        "end)\n" ++
        "if not ok then\n" ++
        "  io.stderr:write('Error: ' .. tostring(err) .. '\\n')\n" ++
        "  pcall(function()\n" ++
        "    system.show_fatal_error('Glyph Error', tostring(err))\n" ++
        "  end)\n" ++
        "end\n" ++
        "return core and core.restart_request\n";

    if (lua.luaL_loadstring(L, init_code) != 0) {
        std.log.err("Internal error loading init code", .{});
        std.process.exit(1);
    }

    const pcall_result = lua.lua_pcallk(L, 0, 1, 0, 0, null);
    if (pcall_result != 0) {
        // Error — print and don't restart
        const errmsg = lua.luaL_tolstring(L, -1, null);
        if (errmsg != null) {
            std.debug.print("Lua error: {s}\n", .{errmsg});
        }
        lua.lua_settop(L, 0);
        return false;
    }

    const restart = lua.lua_toboolean(L, -1) != 0;
    lua.lua_settop(L, -(1) - 1); // lua_pop(L, 1)
    return restart;
}
