// RenWindow — SDL window/surface management
// Zig port of renwindow.c (non-SDL_RENDERER path)

const std = @import("std");
const c = @import("c.zig");
const SDL = c.SDL;

pub const RenRect = extern struct {
    x: c_int = 0,
    y: c_int = 0,
    width: c_int = 0,
    height: c_int = 0,
};

pub const RenColor = extern struct {
    b: u8 = 0,
    g: u8 = 0,
    r: u8 = 0,
    a: u8 = 255,
};

pub const RenSurface = struct {
    surface: *SDL.SDL_Surface,
    scale: c_int = 1,
};

pub const RenWindow = struct {
    window: *SDL.SDL_Window,
    command_buf: ?[*]u8 = null,
    command_buf_idx: usize = 0,
    command_buf_size: usize = 0,
    scale_x: f32 = 1.0,
    scale_y: f32 = 1.0,
};

pub fn initSurface(ren: *RenWindow) void {
    ren.scale_x = 1.0;
    ren.scale_y = 1.0;
}

pub fn initCommandBuf(ren: *RenWindow) void {
    ren.command_buf = null;
    ren.command_buf_idx = 0;
    ren.command_buf_size = 0;
}

pub fn clipToSurface(ren: *RenWindow) void {
    const rs = getSurface(ren);
    _ = SDL.SDL_SetSurfaceClipRect(rs.surface, null);
}

pub fn setClipRect(ren: *RenWindow, rect: RenRect) void {
    const rs = getSurface(ren);
    const sdl_rect = SDL.SDL_Rect{
        .x = rect.x,
        .y = rect.y,
        .w = rect.width,
        .h = rect.height,
    };
    _ = SDL.SDL_SetSurfaceClipRect(rs.surface, &sdl_rect);
}

pub fn getSurface(ren: *RenWindow) RenSurface {
    const surface = SDL.SDL_GetWindowSurface(ren.window);
    if (surface == null) {
        std.log.err("Error getting window surface: {s}", .{SDL.SDL_GetError()});
        std.process.exit(1);
    }
    return RenSurface{ .surface = surface.?, .scale = 1 };
}

pub fn resizeSurface(_: *RenWindow) void {
    // Non-SDL_RENDERER path: nothing needed, SDL_GetWindowSurface handles it
}

pub fn updateScale(ren: *RenWindow) void {
    const surface = SDL.SDL_GetWindowSurface(ren.window);
    if (surface) |s| {
        var window_w: c_int = s.w;
        var window_h: c_int = s.h;
        _ = SDL.SDL_GetWindowSize(ren.window, &window_w, &window_h);
        ren.scale_x = @as(f32, @floatFromInt(s.w)) / @as(f32, @floatFromInt(window_w));
        ren.scale_y = @as(f32, @floatFromInt(s.h)) / @as(f32, @floatFromInt(window_h));
    }
}

pub fn showWindow(ren: *RenWindow) void {
    _ = SDL.SDL_ShowWindow(ren.window);
}

pub fn updateRects(ren: *RenWindow, rects: [*]RenRect, count: c_int) void {
    _ = SDL.SDL_UpdateWindowSurfaceRects(
        ren.window,
        @ptrCast(rects),
        count,
    );
}

pub fn free(ren: *RenWindow) void {
    SDL.SDL_DestroyWindow(ren.window);
    ren.window = undefined;
}
