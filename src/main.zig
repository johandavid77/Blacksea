const std = @import("std");
const linux = std.os.linux;
const wayland = @import("wayland.zig");
const drm = @import("drm.zig");
const evdev = @import("evdev.zig");

pub const Colors = struct {
    pub const background : u32 = 0xFF0D1117;
    pub const surface    : u32 = 0xFF161B22;
    pub const accent     : u32 = 0xFF1F6FEB;
    pub const white      : u32 = 0xFFE6EDF3;
};

pub const LayoutMode = enum {
    scrolling, tiling,
    pub fn toggle(self: LayoutMode) LayoutMode {
        return if (self == .scrolling) .tiling else .scrolling;
    }
};

fn bsLog(comptime level: std.log.Level, comptime fmt: []const u8, args: anytype) void {
    const prefix = switch (level) {
        .err   => "\x1b[31m[ERR]\x1b[0m",
        .warn  => "\x1b[33m[WRN]\x1b[0m",
        .info  => "\x1b[36m[INF]\x1b[0m",
        .debug => "\x1b[90m[DBG]\x1b[0m",
    };
    std.debug.print(prefix ++ " " ++ fmt ++ "\n", args);
}

pub fn main() !void {
    var da = std.heap.DebugAllocator(.{}){};
    defer _ = da.deinit();
    const allocator = da.allocator();

    bsLog(.info, "blacksea: iniciando...", .{});

    var device = drm.Device.autoDetect(allocator) catch |err| {
        bsLog(.err, "no se pudo abrir DRM: {} — correr en TTY con usuario en grupo 'video'", .{err});
        return err;
    };
    defer device.close();

    try device.detectOutput();
    const output = &device.output.?;
    bsLog(.info, "pantalla {}x{} lista", .{ output.width, output.height });

    var input = evdev.InputManager.init(allocator);
    defer input.deinit();
    input.scanDevices() catch |err| bsLog(.warn, "sin input: {}", .{err});

    // Servidor Wayland
    var wl_server = wayland.Server.init(allocator) catch |err| blk: {
        bsLog(.warn, "wayland: no se pudo iniciar socket: {}", .{err});
        break :blk null;
    };
    defer if (wl_server) |*s| s.deinit();

    if (wl_server != null) {
    }

    drawFrame(output, .scrolling, output.width / 2, output.height / 2);
    try output.pageFlip(device.fd);

    bsLog(.info, "corriendo — Super+Q=salir  Super+Space=layout", .{});

    var running     = true;
    var mode        : LayoutMode = .scrolling;
    var cursor_x    : i32 = @intCast(output.width  / 2);
    var cursor_y    : i32 = @intCast(output.height / 2);
    var dirty       = false;

    while (running) {
        for (input.devices[0..input.count]) |*dev| {
            var ev: evdev.InputEvent = undefined;
            while (std.posix.read(dev.fd, std.mem.asBytes(&ev))) |n| {
                if (n < @sizeOf(evdev.InputEvent)) break;
                if (ev.type == evdev.EV_KEY) {
                    const p = ev.value == evdev.KEY_PRESSED;
                    switch (ev.code) {
                        evdev.KEY_SUPER                           => input.mods.super = p,
                        evdev.KEY_LEFTCTRL                        => input.mods.ctrl  = p,
                        evdev.KEY_LEFTALT                         => input.mods.alt   = p,
                        evdev.KEY_LEFTSHIFT, evdev.KEY_RIGHTSHIFT => input.mods.shift = p,
                        else => {},
                    }
                    if (p) {
                        if (input.mods.super and ev.code == evdev.KEY_Q)     { running = false; break; }
                        if (input.mods.super and ev.code == evdev.KEY_SPACE) { mode = mode.toggle(); dirty = true; }
                    }
                }
                if (ev.type == evdev.EV_REL) {
                    if (ev.code == evdev.REL_X) cursor_x = @max(0, @min(@as(i32,@intCast(output.width))-1,  cursor_x+ev.value));
                    if (ev.code == evdev.REL_Y) cursor_y = @max(0, @min(@as(i32,@intCast(output.height))-1, cursor_y+ev.value));
                    dirty = true;
                }
            } else |_| {}
        }
        if (!running) break;

        // Aceptar y procesar clientes Wayland
        if (wl_server) |*s| {
            s.acceptClient();
            s.pollClients();
        }

        if (dirty) {
            drawFrame(output, mode, @intCast(cursor_x), @intCast(cursor_y));
            try output.pageFlip(device.fd);
            dirty = false;
        }
        _ = linux.nanosleep(&.{ .sec = 0, .nsec = 16_000_000 }, null);
    }
    bsLog(.info, "blacksea: hasta luego.", .{});
}

fn drawFrame(output: *drm.Output, mode: LayoutMode, cx: u32, cy: u32) void {
    const fb = output.drawBuffer();
    fb.clear(Colors.background);
    fb.fillRect(0, 0, output.width, 32, Colors.surface);
    fb.fillRect(0, 32, output.width, 1, Colors.accent);
    const mc: u32 = if (mode == .scrolling) Colors.accent else 0xFF3FB950;
    fb.fillRect(8, 8, 16, 16, mc);
    if (cy > 32) {
        fb.fillRect(if (cx>=8) cx-8 else 0, cy, 16, 1, Colors.white);
        fb.fillRect(cx, if (cy>=8) cy-8 else 0, 1, 16, Colors.white);
    }
}
