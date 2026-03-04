// dirmonitor Lua API — filesystem change monitoring
// Windows implementation using FindFirstChangeNotificationW
// Mode: "dir" — watches entire directory trees recursively

const std = @import("std");
const c = @import("../c.zig");
const lua = c.lua;
const windows = std.os.windows;

const HANDLE = windows.HANDLE;
const BOOL = windows.BOOL;
const DWORD = windows.DWORD;
const INVALID_HANDLE: HANDLE = windows.INVALID_HANDLE_VALUE;

const API_TYPE_DIRMONITOR = "Dirmonitor";
const MAX_WATCHES = 64;

// ── Win32 API declarations ──────────────────────────────────────────────

const kernel32 = struct {
    extern "kernel32" fn FindFirstChangeNotificationW(
        lpPathName: [*:0]const u16,
        bWatchSubtree: BOOL,
        dwNotifyFilter: DWORD,
    ) callconv(.winapi) ?HANDLE;

    extern "kernel32" fn FindNextChangeNotification(
        hChangeHandle: HANDLE,
    ) callconv(.winapi) BOOL;

    extern "kernel32" fn FindCloseChangeNotification(
        hChangeHandle: HANDLE,
    ) callconv(.winapi) BOOL;

    extern "kernel32" fn WaitForSingleObject(
        hHandle: HANDLE,
        dwMilliseconds: DWORD,
    ) callconv(.winapi) DWORD;

    extern "kernel32" fn MultiByteToWideChar(
        CodePage: c_uint,
        dwFlags: DWORD,
        lpMultiByteStr: [*c]const u8,
        cbMultiByte: c_int,
        lpWideCharStr: ?[*]u16,
        cchWideChar: c_int,
    ) callconv(.winapi) c_int;
};

const CP_UTF8: c_uint = 65001;
const WAIT_OBJECT_0: DWORD = 0;

const FILE_NOTIFY_CHANGE_FILE_NAME: DWORD = 0x00000001;
const FILE_NOTIFY_CHANGE_DIR_NAME: DWORD = 0x00000002;
const FILE_NOTIFY_CHANGE_SIZE: DWORD = 0x00000008;
const FILE_NOTIFY_CHANGE_LAST_WRITE: DWORD = 0x00000010;
const FILE_NOTIFY_CHANGE_CREATION: DWORD = 0x00000040;

const NOTIFY_FILTER = FILE_NOTIFY_CHANGE_FILE_NAME |
    FILE_NOTIFY_CHANGE_DIR_NAME |
    FILE_NOTIFY_CHANGE_SIZE |
    FILE_NOTIFY_CHANGE_LAST_WRITE |
    FILE_NOTIFY_CHANGE_CREATION;

// ── DirmonitorData — stored as Lua userdata ─────────────────────────────

const DirmonitorData = struct {
    handles: [MAX_WATCHES]?HANDLE,
    count: usize,

    fn init() DirmonitorData {
        return .{
            .handles = [_]?HANDLE{null} ** MAX_WATCHES,
            .count = 0,
        };
    }

    fn addWatch(self: *DirmonitorData, path: [*c]const u8, path_len: usize) c_int {
        if (self.count >= MAX_WATCHES) return -1;

        // Convert UTF-8 path to wide string
        var wide_buf: [4096]u16 = undefined;
        const wide_len = kernel32.MultiByteToWideChar(
            CP_UTF8,
            0,
            path,
            @intCast(path_len),
            &wide_buf,
            @intCast(wide_buf.len - 1),
        );
        if (wide_len <= 0) return -1;
        wide_buf[@intCast(wide_len)] = 0;

        const handle = kernel32.FindFirstChangeNotificationW(
            @ptrCast(&wide_buf),
            1, // bWatchSubtree = TRUE
            NOTIFY_FILTER,
        );
        if (handle == null or handle == INVALID_HANDLE) return -1;

        // Find first free slot
        for (&self.handles, 0..) |*slot, i| {
            if (slot.* == null) {
                slot.* = handle;
                if (i >= self.count) self.count = i + 1;
                return @intCast(i);
            }
        }

        // No free slot (shouldn't happen since we checked count)
        _ = kernel32.FindCloseChangeNotification(handle.?);
        return -1;
    }

    fn removeWatch(self: *DirmonitorData, id: usize) void {
        if (id >= MAX_WATCHES) return;
        if (self.handles[id]) |h| {
            _ = kernel32.FindCloseChangeNotification(h);
            self.handles[id] = null;
        }
    }

    fn closeAll(self: *DirmonitorData) void {
        for (&self.handles) |*slot| {
            if (slot.*) |h| {
                _ = kernel32.FindCloseChangeNotification(h);
                slot.* = null;
            }
        }
        self.count = 0;
    }
};

// ── Lua API functions ───────────────────────────────────────────────────

fn getData(L: ?*lua.lua_State) ?*DirmonitorData {
    const ud = lua.luaL_checkudata(L, 1, API_TYPE_DIRMONITOR);
    if (ud == null) return null;
    return @ptrCast(@alignCast(ud));
}

fn f_new(L: ?*lua.lua_State) callconv(.c) c_int {
    const ud = lua.lua_newuserdatauv(L, @sizeOf(DirmonitorData), 0);
    if (ud == null) return 0;
    const data: *DirmonitorData = @ptrCast(@alignCast(ud));
    data.* = DirmonitorData.init();
    _ = lua.luaL_setmetatable(L, API_TYPE_DIRMONITOR);
    return 1;
}

fn f_gc(L: ?*lua.lua_State) callconv(.c) c_int {
    const data = getData(L) orelse return 0;
    data.closeAll();
    return 0;
}

fn f_mode(L: ?*lua.lua_State) callconv(.c) c_int {
    // "dir" mode: one watch per project directory, recursive
    // This is what the original Lite-XL uses on Windows
    _ = lua.lua_pushstring(L, "dir");
    return 1;
}

fn f_watch(L: ?*lua.lua_State) callconv(.c) c_int {
    const data = getData(L) orelse return 0;
    var path_len: usize = 0;
    const path = lua.luaL_checklstring(L, 2, &path_len);

    const id = data.addWatch(path, path_len);
    if (id < 0) {
        lua.lua_pushnil(L);
        _ = lua.lua_pushstring(L, "failed to watch directory");
        return 2;
    }
    lua.lua_pushinteger(L, @as(lua.lua_Integer, id) + 1); // 1-based for Lua
    return 1;
}

fn f_unwatch(L: ?*lua.lua_State) callconv(.c) c_int {
    const data = getData(L) orelse return 0;
    const id = lua.luaL_checkinteger(L, 2);
    if (id > 0) {
        data.removeWatch(@intCast(id - 1)); // convert from 1-based
    }
    return 0;
}

fn f_check(L: ?*lua.lua_State) callconv(.c) c_int {
    const data = getData(L) orelse return 0;

    // arg 2 is the callback function
    for (data.handles[0..data.count], 0..) |handle, i| {
        if (handle) |h| {
            const result = kernel32.WaitForSingleObject(h, 0);
            if (result == WAIT_OBJECT_0) {
                // Directory changed — call callback(id)
                lua.lua_pushvalue(L, 2); // push callback
                lua.lua_pushinteger(L, @as(lua.lua_Integer, @intCast(i)) + 1); // 1-based
                lua.lua_callk(L, 1, 0, 0, null);

                // Re-arm the notification
                _ = kernel32.FindNextChangeNotification(h);
            }
        }
    }
    return 0;
}

// ── Module registration ─────────────────────────────────────────────────

const dirmonitor_methods = [_]lua.luaL_Reg{
    .{ .name = "mode", .func = f_mode },
    .{ .name = "watch", .func = f_watch },
    .{ .name = "unwatch", .func = f_unwatch },
    .{ .name = "check", .func = f_check },
    .{ .name = "__gc", .func = f_gc },
    .{ .name = null, .func = null },
};

const dirmonitor_lib = [_]lua.luaL_Reg{
    .{ .name = "new", .func = f_new },
    .{ .name = null, .func = null },
};

pub fn luaopen(L: ?*lua.lua_State) callconv(.c) c_int {
    // Create metatable for Dirmonitor userdata
    _ = lua.luaL_newmetatable(L, API_TYPE_DIRMONITOR);
    lua.luaL_setfuncs(L, &dirmonitor_methods, 0);
    lua.lua_pushvalue(L, -1);
    lua.lua_setfield(L, -2, "__index");
    lua.lua_settop(L, -(1) - 1); // pop metatable

    // Create the dirmonitor library table
    c.luaNewLib(L, &dirmonitor_lib);
    return 1;
}
