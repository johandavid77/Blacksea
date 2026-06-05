const std = @import("std");
const xdg_shell = @import("xdg_shell.zig");
const config_mod = @import("config.zig");
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
    // SIGBUS + SIGSEGV handler — ignorar
    var sa = std.mem.zeroes([32]usize);
    sa[0] = 1; // SIG_IGN

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
    var mode      : LayoutMode = .scrolling;
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
                        if (input.mods.ctrl and ev.code == evdev.KEY_Q)     { running = false; break; }
                        if (ev.code == evdev.KEY_F1) { mode = mode.toggle(); dirty = true; }
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
                                seat_mod.sendKey(cl.fd, cl.keyboard_id, srv.serial, now_ms, ev.code + 8, key_state); // evdev+8 = XKB keycode
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
            if (wl_server) |*s| blitSurfaces(output, &s.surfaces, mode);
            try output.pageFlip(device.fd);
            dirty = false;
        }

        // poll() ya esperó 16ms, solo agregamos pequeño sleep extra si no hubo trabajo
        if (!dirty) { _ = linux.nanosleep(&.{ .sec = 0, .nsec = 4_000_000 }, null); }
    }

    bsLog(.info, "blacksea: hasta luego.", .{});
}

fn drawFrame(output: *drm.Output, mode: LayoutMode, cx: u32, cy: u32) void {
    const real_fb = output.drawBuffer();
    var fake_fb = real_fb.*;
        fake_fb.data = real_fb.data;
    const fb = &fake_fb;
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


fn applyTiling(output: *drm.Output, surfaces: *wayland.SurfaceManager) void {
    const W: i32 = @intCast(output.width);
    const H: i32 = @intCast(output.height);
    const bar: i32 = 33; // altura barra superior

    // Contar ventanas mapeadas con xdg_toplevel
    var count: u32 = 0;
    for (&surfaces.surfaces) |*s| {
        if (s.mapped and s.buffer != null) count += 1;
    }
    if (count == 0) return;

    const gap: i32 = 6;
    var idx: u32 = 0;
    for (&surfaces.surfaces) |*s| {
        if (!s.mapped or s.buffer == null) continue;
        if (count == 1) {
            s.x = gap;
            s.y = bar + gap;
            s.width  = W - gap * 2;
            s.height = H - bar - gap * 2;
        } else if (idx == 0) {
            // Master: mitad izquierda
            s.x = gap;
            s.y = bar + gap;
            s.width  = @divTrunc(W, 2) - gap - @divTrunc(gap, 2);
            s.height = H - bar - gap * 2;
        } else {
            // Stack: mitad derecha, dividida verticalmente
            const stack_count: i32 = @intCast(count - 1);
            const slot_h = @divTrunc(H - bar - gap * (stack_count + 1), stack_count);
            const slot_idx: i32 = @intCast(idx - 1);
            s.x = @divTrunc(W, 2) + @divTrunc(gap, 2);
            s.y = bar + gap + slot_idx * (slot_h + gap);
            s.width  = @divTrunc(W, 2) - gap - @divTrunc(gap, 2);
            s.height = slot_h;
        }
        // configure se enviará en versión futura
        idx += 1;
    }
}

fn blitSurfaces(output: *drm.Output, surfaces: *wayland.SurfaceManager, mode: LayoutMode) void {
    if (mode == .tiling) applyTiling(output, surfaces);
    const fb = output.drawBuffer();
    if (fb.data.len == 0) return;
    _ = @min(back_pixels.len, fb.data.len);
    // Pasada 1: superficies con buffer grande (ventanas principales) primero
    for (&surfaces.surfaces) |*surf| {
        if (surf.id == 0 or !surf.mapped) continue;
        const buf = surf.buffer orelse continue;
        if (buf.fd < 0 or buf.data.len == 0) continue;
        if (buf.width <= 0 or buf.height <= 0) continue;
        const area: u64 = @as(u64, @intCast(buf.width)) * @as(u64, @intCast(@abs(buf.height)));
        if (area < 100000) continue; // skip decoraciones pequeñas en pasada 1
        surfaces.blitSurface(surf, fb.data, @intCast(output.width), @intCast(output.height), @intCast(fb.pitch));
    }
    // Pasada 2: subsuperficies pequeñas (decoraciones CSD) encima
    for (&surfaces.surfaces) |*surf| {
        if (surf.id == 0 or !surf.mapped) continue;
        const buf = surf.buffer orelse continue;
        if (buf.fd < 0 or buf.data.len == 0) continue;
        if (buf.width <= 0 or buf.height <= 0) continue;
        const area: u64 = @as(u64, @intCast(buf.width)) * @as(u64, @intCast(@abs(buf.height)));
        if (area >= 100000) continue; // ya blitadas en pasada 1
        surfaces.blitSurface(surf, fb.data, @intCast(output.width), @intCast(output.height), @intCast(fb.pitch));
    }
}
