const std = @import("std");
const linux = std.os.linux;
const drm = @import("drm.zig");
const evdev = @import("evdev.zig");
const wayland = @import("wayland.zig");
const surface_mod = @import("surface.zig");
const seat_mod    = @import("seat.zig");

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
    // Ignorar SIGBUS con SA_RESETHAND=0
    var sa: [152]u8 = std.mem.zeroes([152]u8);
    std.mem.writeInt(usize, sa[0..8], 1, .little); // SIG_IGN
    _ = linux.syscall4(.rt_sigaction, 7, @intFromPtr(&sa), 0, 8); // SIGBUS=7
    // Ignorar SIGBUS via syscall directo
    const SIG_IGN: usize = 1;
    const SIGBUS: usize = 7;
    var sa_buf: [152]u8 = std.mem.zeroes([152]u8);
    std.mem.writeInt(usize, sa_buf[0..8], SIG_IGN, .little);
    _ = std.os.linux.syscall4(.rt_sigaction, SIGBUS, @intFromPtr(&sa_buf), 0, 8);
    var da = std.heap.DebugAllocator(.{}){};
    defer _ = da.deinit();
    const allocator = da.allocator();

    bsLog(.info, "blacksea: iniciando...", .{});
    // Ignorar SIGPIPE — evita muerte cuando cliente cierra socket
    const sig_ign = linux.Sigaction{
        .handler = .{ .handler = linux.SIG.IGN },
        .mask = std.mem.zeroes(linux.sigset_t),
        .flags = 0,
    };
    _ = linux.sigaction(linux.SIG.PIPE, &sig_ign, null);

    var device = drm.Device.autoDetect(allocator) catch |err| {
        bsLog(.err, "no se pudo abrir DRM: {}", .{err});
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
        bsLog(.warn, "wayland socket falló: {}", .{err});
        break :blk null;
    };
    defer if (wl_server) |*s| s.deinit();

    drawFrame(output, .scrolling, output.width / 2, output.height / 2);
    try output.pageFlip(device.fd);

    bsLog(.info, "corriendo — Super+Q=salir  Super+Space=layout", .{});

    var running    = true;
    var mode       : LayoutMode = .scrolling;
    var cursor_x   : i32 = @intCast(output.width  / 2);
    var cursor_y   : i32 = @intCast(output.height / 2);
    var dirty      = false;

    while (running) {
        // ── Input ────────────────────────────────────────────────────────
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
                // Reenviar tecla al cliente Wayland activo
                if (wl_server) |*srv| {
                    const key_state: u32 = if (ev.value == evdev.KEY_PRESSED) 1 else 0;
                    for (&srv.clients) |*slot| {
                        if (slot.*) |*cl| {
                            if (cl.keyboard_id > 0) {
                                srv.serial += 1;
                                var ts: std.os.linux.timespec = undefined;
                                _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
                                const abs_ms: u64 = @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
                                const now_ms: u32 = @truncate(abs_ms - g_start_ms);
                                seat_mod.sendKey(cl.fd, cl.keyboard_id, srv.serial, now_ms, ev.code, key_state);
                                dirty = true;
                                break;
                            }
                        }
                    }
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

        // ── Wayland: siempre procesar, independiente del redraw ───────────
        if (wl_server) |*s| {
            s.poll();
            if (wl_server) |*srv2| { _ = srv2; dirty = true; }
        }

        // ── Render ───────────────────────────────────────────────────────
        if (dirty) {
            drawFrame(output, mode, @intCast(cursor_x), @intCast(cursor_y));
            if (wl_server) |*s| blitSurfaces(output, &s.surfaces);
            try output.pageFlip(device.fd);
            dirty = false;
        }

        // poll() ya esperó 16ms, solo agregamos pequeño sleep extra si no hubo trabajo
        if (!dirty) { _ = linux.nanosleep(&.{ .sec = 0, .nsec = 4_000_000 }, null); }
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

var back_pixels: [1280 * 800]u32 = std.mem.zeroes([1280 * 800]u32);
var g_start_ms: u64 = 0;

fn blitSurfaces(output: *drm.Output, surfaces: *wayland.SurfaceManager) void {
    const fb = output.drawBuffer();
    // Fondo en back_pixels (no tocar fb.data)
    const n = @min(back_pixels.len, fb.data.len);
    @memset(back_pixels[0..n], 0);
    for (&surfaces.surfaces) |*surf| {
        if (surf.id == 0 or !surf.mapped) continue;
        // Verificar buffer válido
        if (surf.buffer == null) continue;
        if (surf.buffer.?.fd < 0 or surf.buffer.?.data.len == 0) continue;
        surfaces.blitSurface(surf, back_pixels[0..fb.data.len], @intCast(output.width), @intCast(output.height), @intCast(fb.pitch));
    }
    // Copiar back buffer al framebuffer
    @memcpy(fb.data[0..n], back_pixels[0..n]);
}
