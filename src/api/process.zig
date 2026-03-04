// process Lua API — subprocess management (Windows implementation)
// Zig port of api/process.c from Lite-XL

const std = @import("std");
const c = @import("../c.zig");
const lua = c.lua;
const windows = std.os.windows;

const HANDLE = windows.HANDLE;
const INVALID_HANDLE: HANDLE = windows.INVALID_HANDLE_VALUE;
const BOOL = windows.BOOL;
const DWORD = windows.DWORD;
const LPDWORD = *DWORD;

const API_TYPE_PROCESS = "Process";
const READ_BUF_SIZE: usize = 2048;

// ── Error codes ──────────────────────────────────────────────────────────
const ERROR_PIPE: c_int = -1;
const ERROR_WOULDBLOCK: c_int = -2;
const ERROR_TIMEDOUT: c_int = -3;
const ERROR_INVAL: c_int = -4;
const ERROR_NOMEM: c_int = -5;

// ── Stream / redirect constants ──────────────────────────────────────────
const STDIN_FD: c_int = 0;
const STDOUT_FD: c_int = 1;
const STDERR_FD: c_int = 2;

const REDIRECT_DEFAULT: c_int = -1;
const REDIRECT_DISCARD: c_int = -2;
const REDIRECT_PARENT: c_int = -3;

const WAIT_INFINITE: c_int = -2;
const WAIT_DEADLINE: c_int = -1;

// ── Win32 extern declarations ────────────────────────────────────────────
const kernel32 = struct {
    extern "kernel32" fn CreatePipe(
        hReadPipe: *HANDLE,
        hWritePipe: *HANDLE,
        lpPipeAttributes: ?*SECURITY_ATTRIBUTES,
        nSize: DWORD,
    ) callconv(.winapi) BOOL;

    extern "kernel32" fn CreateProcessW(
        lpApplicationName: ?[*:0]const u16,
        lpCommandLine: ?[*:0]u16,
        lpProcessAttributes: ?*SECURITY_ATTRIBUTES,
        lpThreadAttributes: ?*SECURITY_ATTRIBUTES,
        bInheritHandles: BOOL,
        dwCreationFlags: DWORD,
        lpEnvironment: ?*anyopaque,
        lpCurrentDirectory: ?[*:0]const u16,
        lpStartupInfo: *STARTUPINFOW,
        lpProcessInformation: *PROCESS_INFORMATION,
    ) callconv(.winapi) BOOL;

    extern "kernel32" fn GetExitCodeProcess(hProcess: HANDLE, lpExitCode: LPDWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD) callconv(.winapi) DWORD;
    extern "kernel32" fn TerminateProcess(hProcess: HANDLE, uExitCode: c_uint) callconv(.winapi) BOOL;
    extern "kernel32" fn PeekNamedPipe(
        hNamedPipe: HANDLE,
        lpBuffer: ?*anyopaque,
        nBufferSize: DWORD,
        lpBytesRead: ?*DWORD,
        lpTotalBytesAvail: ?*DWORD,
        lpBytesLeftThisMessage: ?*DWORD,
    ) callconv(.winapi) BOOL;
    extern "kernel32" fn ReadFile(
        hFile: HANDLE,
        lpBuffer: [*]u8,
        nNumberOfBytesToRead: DWORD,
        lpNumberOfBytesRead: ?*DWORD,
        lpOverlapped: ?*anyopaque,
    ) callconv(.winapi) BOOL;
    extern "kernel32" fn WriteFile(
        hFile: HANDLE,
        lpBuffer: [*]const u8,
        nNumberOfBytesToWrite: DWORD,
        lpNumberOfBytesWritten: ?*DWORD,
        lpOverlapped: ?*anyopaque,
    ) callconv(.winapi) BOOL;
    extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn SetHandleInformation(hObject: HANDLE, dwMask: DWORD, dwFlags: DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn GetProcessId(Process: HANDLE) callconv(.winapi) DWORD;
    extern "kernel32" fn GenerateConsoleCtrlEvent(dwCtrlEvent: DWORD, dwProcessGroupId: DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn GetEnvironmentStringsW() callconv(.winapi) ?[*]u16;
    extern "kernel32" fn FreeEnvironmentStringsW(lpszEnvironmentBlock: [*]u16) callconv(.winapi) BOOL;
};

const SECURITY_ATTRIBUTES = extern struct {
    nLength: DWORD = @sizeOf(SECURITY_ATTRIBUTES),
    lpSecurityDescriptor: ?*anyopaque = null,
    bInheritHandle: BOOL = 0,
};

const STARTUPINFOW = extern struct {
    cb: DWORD = @sizeOf(STARTUPINFOW),
    lpReserved: ?[*:0]u16 = null,
    lpDesktop: ?[*:0]u16 = null,
    lpTitle: ?[*:0]u16 = null,
    dwX: DWORD = 0,
    dwY: DWORD = 0,
    dwXSize: DWORD = 0,
    dwYSize: DWORD = 0,
    dwXCountChars: DWORD = 0,
    dwYCountChars: DWORD = 0,
    dwFillAttribute: DWORD = 0,
    dwFlags: DWORD = 0,
    wShowWindow: u16 = 0,
    cbReserved2: u16 = 0,
    lpReserved2: ?*u8 = null,
    hStdInput: ?HANDLE = null,
    hStdOutput: ?HANDLE = null,
    hStdError: ?HANDLE = null,
};

const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE = INVALID_HANDLE,
    hThread: HANDLE = INVALID_HANDLE,
    dwProcessId: DWORD = 0,
    dwThreadId: DWORD = 0,
};

const HANDLE_FLAG_INHERIT: DWORD = 0x00000001;
const STARTF_USESTDHANDLES: DWORD = 0x00000100;
const STARTF_USESHOWWINDOW: DWORD = 0x00000001;
const CREATE_NO_WINDOW: DWORD = 0x08000000;
const CREATE_NEW_CONSOLE: DWORD = 0x00000010;
const DETACHED_PROCESS: DWORD = 0x00000008;
const CREATE_UNICODE_ENVIRONMENT: DWORD = 0x00000400;
const STILL_ACTIVE: DWORD = 259;
const WAIT_OBJECT_0: DWORD = 0;
const WAIT_TIMEOUT_VAL: DWORD = 0x00000102;
const CTRL_BREAK_EVENT: DWORD = 1;

const allocator = std.heap.c_allocator;

// ── Process userdata ─────────────────────────────────────────────────────
const ProcessData = struct {
    hProcess: ?HANDLE = null,
    hThread: ?HANDLE = null,
    stdin_pipe: ?HANDLE = null,
    stdout_pipe: ?HANDLE = null,
    stderr_pipe: ?HANDLE = null,
    pid: DWORD = 0,
    exit_code: DWORD = STILL_ACTIVE,
    deadline: DWORD = 10,
    detached: bool = false,
};

fn getProcess(L: ?*lua.lua_State) *ProcessData {
    const ud = lua.luaL_checkudata(L, 1, API_TYPE_PROCESS);
    return @ptrCast(@alignCast(ud));
}

fn closeHandle(h: *?HANDLE) void {
    if (h.*) |handle| {
        _ = kernel32.CloseHandle(handle);
        h.* = null;
    }
}

fn pollProcess(proc: *ProcessData) void {
    if (proc.exit_code != STILL_ACTIVE) return;
    if (proc.hProcess) |hp| {
        var code: DWORD = STILL_ACTIVE;
        if (kernel32.GetExitCodeProcess(hp, &code) != 0) {
            proc.exit_code = code;
        }
    }
}

// ── process.start(command, options) ──────────────────────────────────────
fn f_start(L: ?*lua.lua_State) callconv(.c) c_int {
    // Get command string (on Windows, Lua wrapper already escaped table to string)
    var cmd_len: usize = 0;
    const cmd_ptr = lua.luaL_checklstring(L, 1, &cmd_len);
    if (cmd_ptr == null) return lua.luaL_error(L, "invalid command");

    // Parse options (arg 2)
    var deadline: DWORD = 10;
    var cwd_ptr: ?[*:0]const u8 = null;
    var fds: [3]c_int = .{ STDIN_FD, STDOUT_FD, STDERR_FD }; // default: pipe
    var detached: bool = false;
    var no_window: bool = false;

    if (lua.lua_type(L, 2) == lua.LUA_TTABLE) {
        // timeout
        if (lua.lua_getfield(L, 2, "timeout") == lua.LUA_TNUMBER) {
            deadline = @intFromFloat(lua.lua_tonumberx(L, -1, null));
        }
        lua.lua_settop(L, -(1) - 1);

        // cwd
        if (lua.lua_getfield(L, 2, "cwd") == lua.LUA_TSTRING) {
            cwd_ptr = lua.lua_tolstring(L, -1, null);
        }
        lua.lua_settop(L, -(1) - 1);

        // stdin/stdout/stderr redirect
        if (lua.lua_getfield(L, 2, "stdin") == lua.LUA_TNUMBER) {
            fds[0] = @intFromFloat(lua.lua_tonumberx(L, -1, null));
        }
        lua.lua_settop(L, -(1) - 1);
        if (lua.lua_getfield(L, 2, "stdout") == lua.LUA_TNUMBER) {
            fds[1] = @intFromFloat(lua.lua_tonumberx(L, -1, null));
        }
        lua.lua_settop(L, -(1) - 1);
        if (lua.lua_getfield(L, 2, "stderr") == lua.LUA_TNUMBER) {
            fds[2] = @intFromFloat(lua.lua_tonumberx(L, -1, null));
        }
        lua.lua_settop(L, -(1) - 1);

        // detach
        if (lua.lua_getfield(L, 2, "detach") != lua.LUA_TNIL) {
            detached = lua.lua_toboolean(L, -1) != 0;
        }
        lua.lua_settop(L, -(1) - 1);

        // no_window: use CREATE_NO_WINDOW instead of CREATE_NEW_CONSOLE
        // Needed for processes that communicate purely via pipes (e.g. terminal shell).
        // CREATE_NEW_CONSOLE causes the child to re-attach its stdio to the console
        // device, bypassing the pipes we pass via STARTF_USESTDHANDLES.
        if (lua.lua_getfield(L, 2, "no_window") != lua.LUA_TNIL) {
            no_window = lua.lua_toboolean(L, -1) != 0;
        }
        lua.lua_settop(L, -(1) - 1);
    }

    // Create pipes for each stream
    var sa = SECURITY_ATTRIBUTES{
        .bInheritHandle = 1,
    };

    var stdin_read: HANDLE = INVALID_HANDLE;
    var stdin_write: HANDLE = INVALID_HANDLE;
    var stdout_read: HANDLE = INVALID_HANDLE;
    var stdout_write: HANDLE = INVALID_HANDLE;
    var stderr_read: HANDLE = INVALID_HANDLE;
    var stderr_write: HANDLE = INVALID_HANDLE;

    // stdin pipe
    if (fds[0] == STDIN_FD) {
        if (kernel32.CreatePipe(&stdin_read, &stdin_write, &sa, 0) == 0)
            return lua.luaL_error(L, "failed to create stdin pipe");
        _ = kernel32.SetHandleInformation(stdin_write, HANDLE_FLAG_INHERIT, 0);
    }
    // stdout pipe
    if (fds[1] == STDOUT_FD) {
        if (kernel32.CreatePipe(&stdout_read, &stdout_write, &sa, 0) == 0)
            return lua.luaL_error(L, "failed to create stdout pipe");
        _ = kernel32.SetHandleInformation(stdout_read, HANDLE_FLAG_INHERIT, 0);
    }
    // stderr pipe (or redirect to stdout)
    if (fds[2] == STDERR_FD) {
        if (kernel32.CreatePipe(&stderr_read, &stderr_write, &sa, 0) == 0)
            return lua.luaL_error(L, "failed to create stderr pipe");
        _ = kernel32.SetHandleInformation(stderr_read, HANDLE_FLAG_INHERIT, 0);
    } else if (fds[2] == STDOUT_FD) {
        // redirect stderr to stdout
        stderr_write = stdout_write;
    }

    // Setup STARTUPINFO
    var si = STARTUPINFOW{};
    si.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
    si.wShowWindow = 0; // SW_HIDE
    if (fds[0] == STDIN_FD) si.hStdInput = stdin_read;
    if (fds[1] == STDOUT_FD) si.hStdOutput = stdout_write;
    if (fds[2] == STDERR_FD or fds[2] == STDOUT_FD) si.hStdError = stderr_write;

    // Convert command to wide string
    const cmd_slice = cmd_ptr[0..cmd_len];
    const cmd_wide = std.unicode.utf8ToUtf16LeAllocZ(allocator, cmd_slice) catch
        return lua.luaL_error(L, "failed to convert command to UTF-16");
    defer allocator.free(cmd_wide);

    // Convert cwd to wide string if specified
    var cwd_wide: ?[:0]u16 = null;
    if (cwd_ptr) |cwdp| {
        const cwd_slice = std.mem.sliceTo(cwdp, 0);
        cwd_wide = std.unicode.utf8ToUtf16LeAllocZ(allocator, cwd_slice) catch null;
    }
    defer if (cwd_wide) |cw| allocator.free(cw);

    // Handle environment
    var env_block: ?*anyopaque = null;
    var env_alloc: ?[]u16 = null;
    if (lua.lua_type(L, 2) == lua.LUA_TTABLE) {
        if (lua.lua_getfield(L, 2, "env") == lua.LUA_TFUNCTION) {
            // Build system env table to pass to the function
            lua.lua_createtable(L, 0, 64);
            const env_strings = kernel32.GetEnvironmentStringsW();
            if (env_strings) |es| {
                defer _ = kernel32.FreeEnvironmentStringsW(es);
                var ptr: [*]u16 = es;
                while (ptr[0] != 0) {
                    const entry_len = std.mem.indexOfScalar(u16, ptr[0..32768], 0) orelse break;
                    const entry = ptr[0..entry_len];
                    // Find '=' separator (skip if first char is '=')
                    var eq_pos: ?usize = null;
                    for (entry, 0..) |ch, i| {
                        if (ch == '=' and i > 0) { eq_pos = i; break; }
                    }
                    if (eq_pos) |eqp| {
                        const key = std.unicode.utf16LeToUtf8Alloc(allocator, entry[0..eqp]) catch null;
                        const val = std.unicode.utf16LeToUtf8Alloc(allocator, entry[eqp + 1 ..]) catch null;
                        if (key != null and val != null) {
                            _ = lua.lua_pushlstring(L, @ptrCast(val.?.ptr), val.?.len);
                            lua.lua_setfield(L, -2, @ptrCast(key.?.ptr));
                        }
                        if (key) |k| allocator.free(k);
                        if (val) |v| allocator.free(v);
                    }
                    ptr += entry_len + 1;
                }
            }
            // Call env function with the system env table
            if (lua.lua_pcallk(L, 1, 1, 0, 0, null) == 0) {
                // Result is a null-terminated string of KEY=VALUE\0 pairs
                var env_result_len: usize = 0;
                const env_result = lua.lua_tolstring(L, -1, &env_result_len);
                if (env_result != null and env_result_len > 0) {
                    // Convert to wide string for CreateProcessW
                    const env_slice = @as([*]const u8, @ptrCast(env_result))[0..env_result_len];
                    const wide = std.unicode.utf8ToUtf16LeAlloc(allocator, env_slice) catch null;
                    if (wide) |w| {
                        env_alloc = w;
                        env_block = @ptrCast(w.ptr);
                    }
                }
            }
            lua.lua_settop(L, -(1) - 1);
        } else {
            lua.lua_settop(L, -(1) - 1);
        }
    }
    defer if (env_alloc) |ea| allocator.free(ea);

    // CreateProcess
    // CREATE_NEW_CONSOLE gives the child a real console (needed for Node.js-based
    // tools like claude.exe). SW_HIDE in STARTUPINFO keeps the window invisible.
    // CREATE_NO_WINDOW is used when the caller sets no_window=true: the child has
    // no console at all, so all I/O goes exclusively through our pipes.
    var creation_flags: DWORD = if (no_window) CREATE_NO_WINDOW else CREATE_NEW_CONSOLE;
    if (detached) creation_flags |= DETACHED_PROCESS;
    if (env_block != null) creation_flags |= CREATE_UNICODE_ENVIRONMENT;

    var pi = PROCESS_INFORMATION{};
    const result = kernel32.CreateProcessW(
        null,
        @ptrCast(cmd_wide.ptr),
        null,
        null,
        1, // inherit handles
        creation_flags,
        env_block,
        if (cwd_wide) |cw| @ptrCast(cw.ptr) else null,
        &si,
        &pi,
    );

    // Close child-side pipe ends
    if (stdin_read != INVALID_HANDLE) _ = kernel32.CloseHandle(stdin_read);
    if (stdout_write != INVALID_HANDLE) _ = kernel32.CloseHandle(stdout_write);
    if (stderr_write != INVALID_HANDLE and fds[2] != STDOUT_FD) _ = kernel32.CloseHandle(stderr_write);

    if (result == 0) {
        // Cleanup our pipe ends on failure
        if (stdin_write != INVALID_HANDLE) _ = kernel32.CloseHandle(stdin_write);
        if (stdout_read != INVALID_HANDLE) _ = kernel32.CloseHandle(stdout_read);
        if (stderr_read != INVALID_HANDLE) _ = kernel32.CloseHandle(stderr_read);
        return lua.luaL_error(L, "failed to create process");
    }

    // Create userdata
    const ud = lua.lua_newuserdatauv(L, @sizeOf(ProcessData), 0);
    if (ud == null) return lua.luaL_error(L, "failed to allocate process userdata");
    const proc: *ProcessData = @ptrCast(@alignCast(ud));
    proc.* = ProcessData{
        .hProcess = pi.hProcess,
        .hThread = pi.hThread,
        .stdin_pipe = if (stdin_write != INVALID_HANDLE) stdin_write else null,
        .stdout_pipe = if (stdout_read != INVALID_HANDLE) stdout_read else null,
        .stderr_pipe = if (stderr_read != INVALID_HANDLE) stderr_read else null,
        .pid = pi.dwProcessId,
        .deadline = deadline,
        .detached = detached,
    };
    _ = lua.luaL_setmetatable(L, API_TYPE_PROCESS);

    if (detached) {
        closeHandle(&proc.hProcess);
        closeHandle(&proc.hThread);
    }

    return 1;
}

// ── process:pid() ────────────────────────────────────────────────────────
fn f_pid(L: ?*lua.lua_State) callconv(.c) c_int {
    const proc = getProcess(L);
    lua.lua_pushnumber(L, @floatFromInt(proc.pid));
    return 1;
}

// ── process:running() ────────────────────────────────────────────────────
fn f_running(L: ?*lua.lua_State) callconv(.c) c_int {
    const proc = getProcess(L);
    pollProcess(proc);
    lua.lua_pushboolean(L, @intFromBool(proc.exit_code == STILL_ACTIVE));
    return 1;
}

// ── process:returncode() ─────────────────────────────────────────────────
fn f_returncode(L: ?*lua.lua_State) callconv(.c) c_int {
    const proc = getProcess(L);
    pollProcess(proc);
    if (proc.exit_code == STILL_ACTIVE) return 0; // still running, return nothing
    lua.lua_pushnumber(L, @floatFromInt(proc.exit_code));
    return 1;
}

// ── process:wait(timeout) ────────────────────────────────────────────────
fn f_wait(L: ?*lua.lua_State) callconv(.c) c_int {
    const proc = getProcess(L);
    pollProcess(proc);
    if (proc.exit_code != STILL_ACTIVE) {
        lua.lua_pushnumber(L, @floatFromInt(proc.exit_code));
        return 1;
    }

    const hp = proc.hProcess orelse return 0;
    const timeout_arg: c_int = if (lua.lua_gettop(L) >= 2)
        @intFromFloat(lua.lua_tonumberx(L, 2, null))
    else
        0;

    const wait_ms: DWORD = switch (timeout_arg) {
        WAIT_INFINITE => windows.INFINITE,
        WAIT_DEADLINE => proc.deadline,
        else => if (timeout_arg > 0) @intCast(timeout_arg) else 0,
    };

    const wait_result = kernel32.WaitForSingleObject(hp, wait_ms);
    if (wait_result == WAIT_OBJECT_0) {
        pollProcess(proc);
        if (proc.exit_code != STILL_ACTIVE) {
            lua.lua_pushnumber(L, @floatFromInt(proc.exit_code));
            return 1;
        }
    }
    return 0; // still running or timeout
}

// ── process:read(stream, len) ────────────────────────────────────────────
fn readPipe(L: ?*lua.lua_State, pipe: ?HANDLE, max_len: usize) c_int {
    const handle = pipe orelse return 0;

    // Check if data available (non-blocking)
    var available: DWORD = 0;
    if (kernel32.PeekNamedPipe(handle, null, 0, null, &available, null) == 0) {
        return 0; // pipe error (process ended)
    }

    if (available == 0) {
        // No data yet — return empty string
        _ = lua.lua_pushlstring(L, "", 0);
        return 1;
    }

    const to_read: DWORD = @intCast(@min(available, max_len));
    var buf: [READ_BUF_SIZE]u8 = undefined;
    const buf_size = @min(to_read, READ_BUF_SIZE);
    var bytes_read: DWORD = 0;

    if (kernel32.ReadFile(handle, &buf, buf_size, &bytes_read, null) == 0) {
        return 0; // pipe error
    }

    _ = lua.lua_pushlstring(L, &buf, bytes_read);
    return 1;
}

fn f_read(L: ?*lua.lua_State) callconv(.c) c_int {
    const proc = getProcess(L);
    const stream: c_int = @intFromFloat(lua.luaL_checknumber(L, 2));
    const len: usize = if (lua.lua_gettop(L) >= 3)
        @intFromFloat(lua.lua_tonumberx(L, 3, null))
    else
        READ_BUF_SIZE;

    return switch (stream) {
        STDOUT_FD => readPipe(L, proc.stdout_pipe, len),
        STDERR_FD => readPipe(L, proc.stderr_pipe, len),
        else => 0,
    };
}

fn f_read_stdout(L: ?*lua.lua_State) callconv(.c) c_int {
    const proc = getProcess(L);
    const len: usize = if (lua.lua_gettop(L) >= 2)
        @intFromFloat(lua.lua_tonumberx(L, 2, null))
    else
        READ_BUF_SIZE;
    return readPipe(L, proc.stdout_pipe, len);
}

fn f_read_stderr(L: ?*lua.lua_State) callconv(.c) c_int {
    const proc = getProcess(L);
    const len: usize = if (lua.lua_gettop(L) >= 2)
        @intFromFloat(lua.lua_tonumberx(L, 2, null))
    else
        READ_BUF_SIZE;
    return readPipe(L, proc.stderr_pipe, len);
}

// ── process:write(data) ──────────────────────────────────────────────────
fn f_write(L: ?*lua.lua_State) callconv(.c) c_int {
    const proc = getProcess(L);
    var len: usize = 0;
    const data = lua.luaL_checklstring(L, 2, &len);
    if (data == null or len == 0) {
        lua.lua_pushnumber(L, 0);
        return 1;
    }
    const handle = proc.stdin_pipe orelse return lua.luaL_error(L, "stdin pipe not available");

    var bytes_written: DWORD = 0;
    if (kernel32.WriteFile(handle, @ptrCast(data), @intCast(len), &bytes_written, null) == 0) {
        return lua.luaL_error(L, "write failed");
    }
    lua.lua_pushnumber(L, @floatFromInt(bytes_written));
    return 1;
}

// ── process:close_stream(stream) ─────────────────────────────────────────
fn f_close_stream(L: ?*lua.lua_State) callconv(.c) c_int {
    const proc = getProcess(L);
    const stream: c_int = @intFromFloat(lua.luaL_checknumber(L, 2));
    switch (stream) {
        STDIN_FD => closeHandle(&proc.stdin_pipe),
        STDOUT_FD => closeHandle(&proc.stdout_pipe),
        STDERR_FD => closeHandle(&proc.stderr_pipe),
        else => {},
    }
    lua.lua_pushboolean(L, 1);
    return 1;
}

// ── process:terminate() ──────────────────────────────────────────────────
fn f_terminate(L: ?*lua.lua_State) callconv(.c) c_int {
    const proc = getProcess(L);
    if (proc.hProcess) |hp| {
        _ = kernel32.GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT, proc.pid);
        _ = hp;
    }
    lua.lua_pushboolean(L, 1);
    return 1;
}

// ── process:kill() ───────────────────────────────────────────────────────
fn f_kill(L: ?*lua.lua_State) callconv(.c) c_int {
    const proc = getProcess(L);
    if (proc.hProcess) |hp| {
        _ = kernel32.TerminateProcess(hp, @bitCast(@as(i32, -1)));
    }
    lua.lua_pushboolean(L, 1);
    return 1;
}

// ── process:interrupt() ──────────────────────────────────────────────────
fn f_interrupt(L: ?*lua.lua_State) callconv(.c) c_int {
    const proc = getProcess(L);
    _ = kernel32.GenerateConsoleCtrlEvent(0, proc.pid); // CTRL_C_EVENT
    lua.lua_pushboolean(L, 1);
    return 1;
}

// ── process:__gc() ───────────────────────────────────────────────────────
fn f_gc(L: ?*lua.lua_State) callconv(.c) c_int {
    const proc = getProcess(L);
    // Terminate if still running
    pollProcess(proc);
    if (proc.exit_code == STILL_ACTIVE) {
        if (proc.hProcess) |hp| {
            _ = kernel32.TerminateProcess(hp, @bitCast(@as(i32, -1)));
            _ = kernel32.WaitForSingleObject(hp, 500);
        }
    }
    closeHandle(&proc.stdin_pipe);
    closeHandle(&proc.stdout_pipe);
    closeHandle(&proc.stderr_pipe);
    closeHandle(&proc.hProcess);
    closeHandle(&proc.hThread);
    return 0;
}

// ── process.strerror(code) ───────────────────────────────────────────────
fn f_strerror(L: ?*lua.lua_State) callconv(.c) c_int {
    const code: c_int = @intFromFloat(lua.luaL_checknumber(L, 1));
    const msg: [*:0]const u8 = switch (code) {
        ERROR_PIPE => "pipe error",
        ERROR_WOULDBLOCK => "would block",
        ERROR_TIMEDOUT => "timed out",
        ERROR_INVAL => "invalid argument",
        ERROR_NOMEM => "out of memory",
        else => "unknown error",
    };
    _ = lua.lua_pushstring(L, msg);
    return 1;
}

// ── Module registration ──────────────────────────────────────────────────

const process_methods = [_]lua.luaL_Reg{
    .{ .name = "pid", .func = f_pid },
    .{ .name = "running", .func = f_running },
    .{ .name = "returncode", .func = f_returncode },
    .{ .name = "wait", .func = f_wait },
    .{ .name = "read", .func = f_read },
    .{ .name = "read_stdout", .func = f_read_stdout },
    .{ .name = "read_stderr", .func = f_read_stderr },
    .{ .name = "write", .func = f_write },
    .{ .name = "close_stream", .func = f_close_stream },
    .{ .name = "terminate", .func = f_terminate },
    .{ .name = "kill", .func = f_kill },
    .{ .name = "interrupt", .func = f_interrupt },
    .{ .name = "__gc", .func = f_gc },
    .{ .name = null, .func = null },
};

const funcs = [_]lua.luaL_Reg{
    .{ .name = "start", .func = f_start },
    .{ .name = "strerror", .func = f_strerror },
    .{ .name = null, .func = null },
};

pub fn luaopen(L: ?*lua.lua_State) callconv(.c) c_int {
    // Create metatable for Process userdata
    _ = lua.luaL_newmetatable(L, API_TYPE_PROCESS);
    lua.luaL_setfuncs(L, &process_methods, 0);
    lua.lua_pushvalue(L, -1);
    lua.lua_setfield(L, -2, "__index");
    lua.lua_settop(L, -(1) - 1);

    // Create module table
    c.luaNewLib(L, &funcs);

    // Constants
    lua.lua_pushnumber(L, ERROR_PIPE);
    lua.lua_setfield(L, -2, "ERROR_PIPE");
    lua.lua_pushnumber(L, ERROR_WOULDBLOCK);
    lua.lua_setfield(L, -2, "ERROR_WOULDBLOCK");
    lua.lua_pushnumber(L, ERROR_TIMEDOUT);
    lua.lua_setfield(L, -2, "ERROR_TIMEDOUT");
    lua.lua_pushnumber(L, ERROR_INVAL);
    lua.lua_setfield(L, -2, "ERROR_INVAL");
    lua.lua_pushnumber(L, ERROR_NOMEM);
    lua.lua_setfield(L, -2, "ERROR_NOMEM");

    lua.lua_pushnumber(L, STDIN_FD);
    lua.lua_setfield(L, -2, "STREAM_STDIN");
    lua.lua_pushnumber(L, STDOUT_FD);
    lua.lua_setfield(L, -2, "STREAM_STDOUT");
    lua.lua_pushnumber(L, STDERR_FD);
    lua.lua_setfield(L, -2, "STREAM_STDERR");

    lua.lua_pushnumber(L, WAIT_INFINITE);
    lua.lua_setfield(L, -2, "WAIT_INFINITE");
    lua.lua_pushnumber(L, WAIT_DEADLINE);
    lua.lua_setfield(L, -2, "WAIT_DEADLINE");

    lua.lua_pushnumber(L, REDIRECT_DEFAULT);
    lua.lua_setfield(L, -2, "REDIRECT_DEFAULT");
    lua.lua_pushnumber(L, STDIN_FD);
    lua.lua_setfield(L, -2, "REDIRECT_PIPE");
    lua.lua_pushnumber(L, REDIRECT_PARENT);
    lua.lua_setfield(L, -2, "REDIRECT_PARENT");
    lua.lua_pushnumber(L, REDIRECT_DISCARD);
    lua.lua_setfield(L, -2, "REDIRECT_DISCARD");
    lua.lua_pushnumber(L, STDOUT_FD);
    lua.lua_setfield(L, -2, "REDIRECT_STDOUT");

    return 1;
}
