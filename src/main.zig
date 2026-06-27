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
    if (wl_server) |*s| { s.screen_w = output.width; s.screen_h = output.height; }
    defer if (wl_server) |*s| s.deinit();

    drawFrame(output, .scrolling, output.width / 2, output.height / 2);
    try output.pageFlip(device.fd);

    bsLog(.info, "corriendo — Super+Q=salir  Super+Space=layout", .{});

    var running    = true;
    var mode      : LayoutMode = .scrolling;
    var cursor_x   : i32 = @intCast(output.width  / 2);
    var cursor_y   : i32 = @intCast(output.height / 2);
    var dirty          = false;
    var pointer_moved  = false;
    var last_render_ms: u64 = 0;

    // Cargar wallpaper PPM
    // Cargar config Lua
    var cfg = config_mod.Config{};
    cfg.load("/home/johan/.config/blacksea/init.lua") catch {};

    load_wp: {
        const wp_fd_r = linux.open(@as([*:0]const u8, @ptrCast(std.mem.sliceTo(&cfg.wallpaper_path, 0).ptr)), .{ .ACCMODE = .RDONLY }, 0);
        const wp_fd: i32 = @bitCast(@as(u32, @truncate(wp_fd_r)));
        if (wp_fd < 0) { std.log.err("wp open failed: {}", .{wp_fd}); break :load_wp; }
        defer _ = linux.close(@intCast(wp_fd));
        // Leer header línea a línea
        var hdr: [128]u8 = undefined;
        var hpos: usize = 0;
        // Leer byte a byte hasta newline para P6
        var b: [1]u8 = undefined;
        hpos = 0;
        while (hpos < 3) { _ = linux.read(@intCast(wp_fd), &b, 1); if (b[0] == '\n') break; hdr[hpos] = b[0]; hpos += 1; }
        if (!std.mem.eql(u8, hdr[0..2], "P6")) { std.log.err("wp not P6", .{}); break :load_wp; }
        // Leer WxH
        hpos = 0;
        while (hpos < 63) { _ = linux.read(@intCast(wp_fd), &b, 1); if (b[0] == '\n') break; hdr[hpos] = b[0]; hpos += 1; }
        var it = std.mem.tokenizeScalar(u8, hdr[0..hpos], ' ');
        wallpaper_w = std.fmt.parseInt(u32, it.next() orelse break :load_wp, 10) catch break :load_wp;
        wallpaper_h = std.fmt.parseInt(u32, it.next() orelse break :load_wp, 10) catch break :load_wp;
        // Leer maxval line
        while (true) { const nr = linux.read(@intCast(wp_fd), &b, 1); if (nr <= 0 or b[0] == '\n') break; }
        // Leer pixels
        var rgb: [3]u8 = undefined;
        const total = wallpaper_w * wallpaper_h;
        var pi: u32 = 0;
        while (pi < total) : (pi += 1) {
            var got: usize = 0;
            while (got < 3) { const nr = linux.read(@intCast(wp_fd), rgb[got..].ptr, 3-got); if (nr <= 0) break :load_wp; got += @intCast(nr); }
            wp_buf[pi] = 0xFF000000|(@as(u32,rgb[0])<<16)|(@as(u32,rgb[1])<<8)|rgb[2];
        }
        wallpaper_data = wp_buf[0..total];
        std.log.info("wallpaper: {}x{}", .{wallpaper_w, wallpaper_h});
    }

    while (running) {
        // ── Input ────────────────────────────────────────────────────────
        for (input.devices[0..input.count]) |*dev| {
            var ev: evdev.InputEvent = undefined;
            while (std.posix.read(dev.fd, std.mem.asBytes(&ev))) |n| {
                if (n < @sizeOf(evdev.InputEvent)) break;
                if (ev.type == evdev.EV_KEY) {
                    std.log.info("EVKEY code={} val={}", .{ev.code, ev.value});
                    // Mouse buttons
                    if (ev.code == evdev.BTN_LEFT or ev.code == evdev.BTN_RIGHT or ev.code == evdev.BTN_MIDDLE) {
                        if (wl_server) |*srv| {
                            var ts_b: std.os.linux.timespec = undefined;
                            _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts_b);
                            const ms_b: u32 = @truncate(@as(u64,@intCast(ts_b.sec))*1000+@as(u64,@intCast(ts_b.nsec))/1_000_000);
                            // Focus-on-click
                            if (ev.value == 1 and ev.code == evdev.BTN_LEFT) {
                                std.log.info("CLICK x={} y={}", .{cursor_x, cursor_y});
                                for (srv.surfaces.surfaces) |sdbg| {
                                    if (sdbg.id == 0 or !sdbg.mapped) continue;
                                    std.log.info("  surf id={} fd={} x={} y={} w={} h={} top={}", .{sdbg.id, sdbg.client_fd, sdbg.x, sdbg.y, sdbg.width, sdbg.height, sdbg.xdg_toplevel_id});
                                }
                                std.log.info("CLICK x={} y={}", .{cursor_x, cursor_y});
                                for (srv.surfaces.surfaces) |sdbg| {
                                    if (sdbg.id == 0 or !sdbg.mapped) continue;
                                    std.log.info("  surf id={} fd={} x={} y={} w={} h={} top={}", .{sdbg.id, sdbg.client_fd, sdbg.x, sdbg.y, sdbg.width, sdbg.height, sdbg.xdg_toplevel_id});
                                }
                                focus: for (&srv.clients) |*slot2| {
                                    if (slot2.*) |*cl2| {
                                        for (srv.surfaces.surfaces) |s| {
                                            if (s.id == 0 or !s.mapped or s.xdg_toplevel_id == 0) continue;
                                            if (s.client_fd != cl2.fd) continue;
                                            if (cursor_x >= s.x and cursor_x < s.x + @as(i32,@intCast(s.width)) and
                                                cursor_y >= s.y and cursor_y < s.y + @as(i32,@intCast(s.height))) {
                                                if (srv.focused_fd != cl2.fd) {
                                                    // Leave al anterior
                                                    for (&srv.clients) |*slot3| {
                                                        if (slot3.*) |*cl3| {
                                                            if (cl3.fd == srv.focused_fd and cl3.keyboard_id > 0) {
                                                                for (srv.surfaces.surfaces) |s3| {
                                                                    if (s3.xdg_toplevel_id > 0 and s3.client_fd == cl3.fd) {
                                                                        srv.serial += 1;
                                                                        seat_mod.sendKeyboardLeave(cl3.fd, cl3.keyboard_id, s3.id, srv.serial);
                                                                        break;
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    }
                                                    srv.focused_fd = cl2.fd;
                                                    // Enter al nuevo
                                                    if (cl2.keyboard_id > 0) {
                                                        srv.serial += 1;
                                                        // Buscar la surface principal (con xdg_toplevel) del cliente
                    var enter_surf: u32 = cl2.last_wl_surface_id;
                    for (srv.surfaces.surfaces) |ts| {
                        if (ts.id > 0 and ts.client_fd == cl2.fd and ts.xdg_toplevel_id > 0) {
                            enter_surf = ts.id; break;
                        }
                    }
                    // Fallback: usar cualquier surface toplevel del cliente
                if (enter_surf == 0) {
                    for (srv.surfaces.surfaces) |ts| {
                        if (ts.id > 0 and ts.client_fd == cl2.fd) {
                            enter_surf = ts.id; break;
                        }
                    }
                }
                if (enter_surf > 0) { seat_mod.sendKeyboardEnter(cl2.fd, cl2.keyboard_id, enter_surf, srv.serial); cl2.has_keyboard_focus = true; }
                                                        seat_mod.sendModifiers(cl2.fd, cl2.keyboard_id, srv.serial, 0, 0, 0, 0);
                                                    }
                                                    std.log.info("focus -> fd={}", .{cl2.fd});
                                                }
                                                break :focus;
                                            }
                                        }
                                    }
                                }
                            }
                            for (&srv.clients) |*slot| {
                                if (slot.*) |*cl| {
                                    if (cl.pointer_id == 0) continue;
                                    if (cl.pointer_surface_id == 0) continue;
                                    srv.serial += 1;
                                    const btn: u32 = 0x110 + @as(u32, ev.code - evdev.BTN_LEFT);
                                    var bp = wayland.MsgBuf{};
                                    bp.uint(srv.serial); bp.uint(ms_b);
                                    bp.uint(btn); bp.uint(@intCast(ev.value));
                                    cl.sendEvent(cl.pointer_id, 3, bp.slice());
                                }
                            }
                        }
                        dirty = true;
                        continue;
                    }
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
                        // Alt+Tab: rotar foco entre clientes
            if (p and (ev.code == 67 or (input.mods.alt and ev.code == 15))) { // F9 o Alt+Tab focus cycle
                    if (wl_server) |*srv2| {
                        const old_fd = srv2.focused_fd;
                        var found = false;
                        var first_fd: i32 = -1;
                        var new_fd: i32 = -1;
                        for (&srv2.clients) |*slot2| {
                            if (slot2.*) |*cl2| {
                                if (cl2.keyboard_id > 0) {
                                    if (first_fd == -1) first_fd = cl2.fd;
                                    if (found) { new_fd = cl2.fd; break; }
                                    if (cl2.fd == old_fd) found = true;
                                }
                            }
                        }
                        if (new_fd == -1 and found and first_fd != -1) new_fd = first_fd;
                        if (new_fd != -1 and new_fd != old_fd) {
                            // keyboard leave al anterior
                            for (&srv2.clients) |*slot3| {
                                if (slot3.*) |*cl3| {
                                    if (cl3.fd == old_fd and cl3.keyboard_id > 0 and cl3.last_wl_surface_id > 0 and cl3.has_keyboard_focus) {
                                        srv2.serial += 1;
                                        seat_mod.sendKeyboardLeave(cl3.fd, cl3.keyboard_id, cl3.last_wl_surface_id, srv2.serial);
                                        cl3.has_keyboard_focus = false;
                                    }
                                }
                            }
                            srv2.focused_fd = new_fd;
                            // keyboard enter al nuevo
                            for (&srv2.clients) |*slot4| {
                                if (slot4.*) |*cl4| {
                                    if (cl4.fd == new_fd and cl4.keyboard_id > 0) {
                                        var esurf: u32 = cl4.last_wl_surface_id;
                                        for (srv2.surfaces.surfaces) |ts| {
                                            if (ts.id > 0 and ts.client_fd == cl4.fd and ts.xdg_toplevel_id > 0) {
                                                esurf = ts.id; break;
                                            }
                                        }
                                        if (esurf > 0) {
                                            srv2.serial += 1;
                                            seat_mod.sendKeyboardEnter(cl4.fd, cl4.keyboard_id, esurf, srv2.serial);
                                            cl4.has_keyboard_focus = true;
                                            seat_mod.sendModifiers(cl4.fd, cl4.keyboard_id, srv2.serial, 0, 0, 0, 0);
                                        }
                                    }
                                }
                            }
                            dirty = true;
                            std.log.info("F9 focus -> fd={}", .{new_fd});
                        }
                    }
                continue;
                }
                        if (ev.code == evdev.KEY_F1) { mode = mode.toggle(); dirty = true; }
                    // Super+Return: abrir foot
                if (p and (ev.code == 68 or (ev.code == 28 and input.mods.alt))) { // F10 o Alt+Enter spawn foot
                    std.log.info("SPAWN! super={} p={} code={}", .{input.mods.super, p, ev.code});
                    const rc = linux.fork();
                    if (rc == 0) {
                        _ = linux.setsid();
                        const term_cmd: [*:0]const u8 = if (cfg.terminal_cmd[0] != 0)
                            @as([*:0]const u8, @ptrCast(&cfg.terminal_cmd))
                        else
                            "foot";
                        const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", term_cmd, null };
                        const env = [_:null]?[*:0]const u8{
                            "WAYLAND_DISPLAY=wayland-0",
                            "XDG_RUNTIME_DIR=/run/user/1000",
                            "HOME=/home/johan",
                            "TERM=foot",
                            null,
                        };
                        _ = linux.execve("/bin/sh", &argv, &env);
                        linux.exit(1);
                    }
                if (ev.code == 28 and input.mods.alt) continue; // no enviar Alt+Enter al cliente
                    std.log.info("spawned foot pid={}", .{rc});
                    continue;
                }
                    }
                // Reenviar tecla al cliente Wayland activo
                if (wl_server) |*srv| {
                    const key_state: u32 = if (ev.value == evdev.KEY_PRESSED) 1 else 0;
                    // Si el cliente enfocado murió, reasignar foco al primero disponible
                    var focus_valid = false;
                    for (&srv.clients) |*slot| {
                        if (slot.*) |*cl| { if (cl.fd == srv.focused_fd and cl.keyboard_id > 0) { focus_valid = true; break; } }
                    }
                    for (&srv.clients) |*slot| {
                        if (slot.*) |*cl| {
                            if (cl.keyboard_id > 0 and cl.fd == srv.focused_fd) {
                                srv.serial += 1;
                                var ts: std.os.linux.timespec = undefined;
                                _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
                                const abs_ms: u64 = @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
                                const now_ms: u32 = @truncate(abs_ms - g_start_ms);
                                std.log.info("KEY fd={} kid={} code={} state={}", .{cl.fd, cl.keyboard_id, ev.code, key_state});
                    // Interceptar Alt+Enter — spawn foot, no enviar al cliente
                    seat_mod.sendKey(cl.fd, cl.keyboard_id, srv.serial, now_ms, ev.code, key_state); // evdev+8 = XKB keycode
                                dirty = true;
                                break;
                            }
                        }
                    }
                }
                }
                if (ev.type == evdev.EV_ABS) {
                    if (ev.code == evdev.ABS_X) cursor_x = @intCast(@divTrunc(@as(i64,ev.value)*@as(i64,@intCast(output.width)), 65535));
                    if (ev.code == evdev.ABS_Y) cursor_y = @intCast(@divTrunc(@as(i64,ev.value)*@as(i64,@intCast(output.height)), 65535));
                    dirty = true;
                    pointer_moved = true;
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
            // Marcar dirty si hay frame callback o blit pendiente
            for (&s.clients) |*slot| {
                if (slot.*) |*cl| {
                    if (cl.frame_cb_id > 0 or cl.needs_blit) { dirty = true; break; }
                }
            }
        }
        // Throttle: render máximo cada 16ms
        if (!dirty) {
            var _t: std.os.linux.timespec = undefined;
            _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &_t);
            const _now: u64 = @as(u64,@intCast(_t.sec))*1000 + @as(u64,@intCast(_t.nsec))/1_000_000;
            if (_now -% last_render_ms >= 16) dirty = true;
        }

        // ── Render ───────────────────────────────────────────────────────
        if (dirty) {
            drawFrame(output, mode, @intCast(cursor_x), @intCast(cursor_y));
            if (wl_server) |*s| {
                blitSurfaces(output, &s.surfaces, mode);
                for (&s.clients) |*slot_rb| {
                    if (slot_rb.*) |*cl_rb| cl_rb.needs_blit = false;
                }
                for (&s.clients) |*slot_rb| {
                    if (slot_rb.*) |*cl_rb| cl_rb.needs_blit = false;
                }
                // Bordes con esquinas redondeadas
                const bw2: u32 = 2;
                const bc2: u32 = 0xFF4A90D9;
                if (bw2 > 0) {
                    for (&s.surfaces.surfaces) |*surf| {
                        if (surf.id == 0 or !surf.mapped) continue;
                        if (surf.width == 0 or surf.height == 0) continue;
                        const area: u64 = @as(u64,@intCast(surf.width))*@as(u64,@intCast(@abs(surf.height)));
                        if (area < 100000) continue; // solo ventanas principales
                        drawBorder(output, surf, bw2, bc2);
                    }
                }
                blitCursor(output, &s.surfaces, &s.clients, cursor_x, cursor_y);
            }
            try output.pageFlip(device.fd);
            // Pointer enter/leave
            if (wl_server) |*srv| {
                for (&srv.clients) |*slot| {
                    if (slot.*) |*cl| {
                        if (cl.pointer_id == 0 or !pointer_moved) continue;
                        var sid: u32 = 0;
                        for (srv.surfaces.surfaces) |s| {
                            if (s.id > 0 and s.mapped and s.client_fd == cl.fd and
                                s.width > 0 and s.height > 0 and
                                cursor_x >= s.x and cursor_x < s.x+@as(i32,@intCast(s.width)) and
                                cursor_y >= s.y and cursor_y < s.y+@as(i32,@intCast(s.height)))
                                sid = s.id;
                        }
                        if (sid == cl.pointer_surface_id) {
                            // motion dentro de la misma surface
                            if (sid > 0 and pointer_moved) {
                                var rx: i32 = cursor_x; var ry: i32 = cursor_y;
                                for (srv.surfaces.surfaces) |s| { if (s.id==sid) { rx=cursor_x-s.x; ry=cursor_y-s.y; break; } }
                                var ts_m: std.os.linux.timespec = undefined;
                                _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts_m);
                                const ms_m: u32 = @truncate(@as(u64,@intCast(ts_m.sec))*1000+@as(u64,@intCast(ts_m.nsec))/1_000_000);
                                var mo = wayland.MsgBuf{};
                                mo.uint(ms_m);
                                mo.uint(@bitCast(rx << 8));
                                mo.uint(@bitCast(ry << 8));
                                cl.sendEvent(cl.pointer_id, 2, mo.slice()); // motion
                            }
                            continue;
                        }
                        // Solo procesar si el cursor tiene posicion valida
                        if (cursor_x < 0 or cursor_y < 0) continue;
                        // Guard: cliente debe haber completado al menos un render cycle
                        if (cl.needs_blit or cl.frame_cb_id > 0) continue;
                        if (cl.pointer_surface_id > 0) {
                            srv.serial += 1;
                            var lv = wayland.MsgBuf{};
                            lv.uint(srv.serial); lv.uint(cl.pointer_surface_id);
                            cl.sendEvent(cl.pointer_id, 1, lv.slice()); // leave
                            cl.sendEvent(cl.pointer_id, 5, &[_]u8{});
                        }
                        cl.pointer_surface_id = sid;
                        if (sid > 0) {
                            const rx: i32 = cursor_x - (for (srv.surfaces.surfaces) |s| { if (s.id==sid) break s.x; } else 0);
                            const ry: i32 = cursor_y - (for (srv.surfaces.surfaces) |s| { if (s.id==sid) break s.y; } else 0);
                            srv.serial += 1;
                            var en = wayland.MsgBuf{};
                            en.uint(srv.serial); en.uint(sid);
                            en.uint(@bitCast(rx << 8)); en.uint(@bitCast(ry << 8));
                            cl.sendEvent(cl.pointer_id, 0, en.slice());
                            cl.sendEvent(cl.pointer_id, 5, &[_]u8{});
                        }
                    }
                }
                if (pointer_moved) pointer_moved = false;
            }



            if (wl_server) |*srv| {
                for (&srv.clients) |*slot| {
                    if (slot.*) |*cl| {
                        if (cl.frame_cb_id > 0) {
                            var ts3: std.os.linux.timespec = undefined;
                            _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts3);
                            const ms3: u32 = @truncate(@as(u64, @intCast(ts3.sec)) * 1000 + @as(u64, @intCast(ts3.nsec)) / 1_000_000);
                            var fcb = wayland.MsgBuf{};
                            fcb.uint(ms3);
                            cl.sendEvent(cl.frame_cb_id, 0, fcb.slice());
                            cl.frame_cb_id = 0;
                        cl.needs_blit = true;
                        }
                    }
                }
            }
            var _t2: std.os.linux.timespec = undefined;
            _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &_t2);
            last_render_ms = @as(u64,@intCast(_t2.sec))*1000 + @as(u64,@intCast(_t2.nsec))/1_000_000;
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
    if (wallpaper_data) |wp| {
        const fb_px: [*]u32 = @ptrCast(@alignCast(fb.data.ptr));
        const sw = @min(wallpaper_w, output.width);
        const sh = @min(wallpaper_h, output.height);
        const pitch: u32 = @intCast(fb.pitch / 4);
        var wy: u32 = 0;
        while (wy < sh) : (wy += 1) {
            @memcpy(fb_px[wy*pitch..wy*pitch+sw], wp[wy*wallpaper_w..wy*wallpaper_w+sw]);
        }
    } else fb.clear(Colors.background);
    fb.fillRect(0, 0, output.width, 32, Colors.surface);
    fb.fillRect(0, 32, output.width, 1, Colors.accent);
    // Hora en la barra
    var ts_now: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts_now);
    const secs = @as(u64, @intCast(ts_now.sec));
    const local_secs = secs -% (5 * 3600); // UTC-5 Colombia
    const hh: u64 = (local_secs % 86400) / 3600;
    const mm: u64 = (local_secs % 3600) / 60;
    const ss: u64 = local_secs % 60;
    var tbuf: [16]u8 = undefined;
    const tstr = std.fmt.bufPrint(&tbuf, "{d:0>2}:{d:0>2}:{d:0>2}", .{hh, mm, ss}) catch "??:??:??";
    fb.drawText(output.width / 2 -| 24, 12, tstr, Colors.white, Colors.surface);
    // Título ventana enfocada (izquierda)
    if (focused_title_len > 0)
        fb.drawText(40, 12, focused_title[0..focused_title_len], Colors.white, Colors.surface);
    const mc: u32 = if (mode == .scrolling) Colors.accent else 0xFF3FB950;
    fb.fillRect(8, 8, 16, 16, mc);
    if (cy > 32) {
        fb.fillRect(if (cx>=8) cx-8 else 0, cy, 16, 1, Colors.white);
        fb.fillRect(cx, if (cy>=8) cy-8 else 0, 1, 16, Colors.white);
    }
}

var back_pixels: [1280 * 800]u32 = std.mem.zeroes([1280 * 800]u32);
var g_start_ms: u64 = 0;
var wallpaper_data: ?[]u32 = null;
var focused_title: [64]u8 = [_]u8{0} ** 64;
var focused_title_len: usize = 0;
var wallpaper_w: u32 = 0;
var wallpaper_h: u32 = 0;
var wp_buf: [1280*800]u32 = undefined;


fn applyTiling(output: *drm.Output, surfaces: *wayland.SurfaceManager) void {
    const W: i32 = @intCast(output.width);
    const H: i32 = @intCast(output.height);
    const bar: i32 = 33; // altura barra superior

    // Contar ventanas mapeadas con xdg_toplevel
    var count: u32 = 0;
    for (&surfaces.surfaces) |*s| {
        if (s.mapped and s.buffer != null and s.xdg_toplevel_id > 0) count += 1;
    }
    if (count == 0) return;

    const gap: i32 = 6;
    var idx: u32 = 0;
    for (&surfaces.surfaces) |*s| {
        if (!s.mapped or s.buffer == null or s.xdg_toplevel_id == 0) continue;
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
    applyTiling(output, surfaces); _ = mode;
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
    // Pasada 2: subsuperficies CSD omitidas (compositor maneja decoraciones)
}


fn drawBorder(output: *drm.Output, surf: *surface_mod.Surface, bw: u32, color: u32) void {
    const fb = output.drawBuffer();
    if (fb.data.len == 0) return;
    const W: i32 = @intCast(output.width);
    const H: i32 = @intCast(output.height);
    const pitch: i32 = @intCast(fb.pitch / 4);
    const px: [*]u32 = @ptrCast(@alignCast(fb.data.ptr));
    const x0 = surf.x;
    const y0 = surf.y;
    const x1 = surf.x + @as(i32, @intCast(surf.width));
    const y1 = surf.y + @as(i32, @intCast(surf.height));
    const b: i32 = @intCast(bw);
    const r: i32 = 8; // corner radius
    // Función inline: pintar pixel con clip
    const setpx = struct {
        fn f(p: [*]u32, x: i32, y: i32, w: i32, h: i32, pt: i32, c: u32) void {
            if (x < 0 or y < 0 or x >= w or y >= h) return;
            p[@intCast(y * pt + x)] = c;
        }
    }.f;
    // 4 lados del borde
    var i: i32 = 0;
    while (i < b) : (i += 1) {
        // top y bottom
        var x: i32 = x0 + r;
        while (x < x1 - r) : (x += 1) {
            setpx(px, x, y0 - i - 1, W, H, pitch, color);
            setpx(px, x, y1 + i,     W, H, pitch, color);
        }
        // left y right
        var y: i32 = y0 + r;
        while (y < y1 - r) : (y += 1) {
            setpx(px, x0 - i - 1, y, W, H, pitch, color);
            setpx(px, x1 + i,     y, W, H, pitch, color);
        }
        // esquinas redondeadas (arco de 90°)
        var a: i32 = 0;
        while (a <= r) : (a += 1) {
            const dy: i32 = r - a;
            const dx: i32 = @intFromFloat(@sqrt(@as(f32, @floatFromInt(r*r - dy*dy))));
            setpx(px, x0 - i - 1 + r - dx, y0 - i - 1 + r - dy, W, H, pitch, color);
            setpx(px, x1 + i - r + dx,     y0 - i - 1 + r - dy, W, H, pitch, color);
            setpx(px, x0 - i - 1 + r - dx, y1 + i - r + dy,     W, H, pitch, color);
            setpx(px, x1 + i - r + dx,     y1 + i - r + dy,     W, H, pitch, color);
        }
    }
}

fn blitCursor(output: *drm.Output, surfaces: *wayland.SurfaceManager, clients: []?wayland.Client, cx: i32, cy: i32) void {
    const fb = output.drawBuffer();
    if (fb.data.len == 0) return;
    // Intentar cursor del cliente
    for (clients) |*slot| {
        const cl = slot.* orelse continue;
        if (cl.cursor_surface_id == 0) continue;
        for (&surfaces.surfaces) |*surf| {
            if (surf.id != cl.cursor_surface_id or !surf.mapped) continue;
            const buf = surf.buffer orelse continue;
            if (buf.fd < 0 or buf.data.len == 0) continue;
            surf.x = cx - cl.cursor_hotspot_x;
            surf.y = cy - cl.cursor_hotspot_y;
            surfaces.blitSurface(surf, fb.data, @intCast(output.width), @intCast(output.height), @intCast(fb.pitch));
            return;
        }
    }
    // Fallback: flecha de software
    drawArrowCursor(output, cx, cy);
}

fn drawArrowCursor(output: *drm.Output, cx: i32, cy: i32) void {
    const fb = output.drawBuffer();
    if (fb.data.len == 0) return;
    const W: i32 = @intCast(output.width);
    const H: i32 = @intCast(output.height);
    const pitch: i32 = @intCast(fb.pitch / 4);
    const px: [*]u32 = @ptrCast(@alignCast(fb.data.ptr));
    const arrow = [13][13]u2{
        .{ 2,0,0,0,0,0,0,0,0,0,0,0,0 },
        .{ 2,2,0,0,0,0,0,0,0,0,0,0,0 },
        .{ 2,1,2,0,0,0,0,0,0,0,0,0,0 },
        .{ 2,1,1,2,0,0,0,0,0,0,0,0,0 },
        .{ 2,1,1,1,2,0,0,0,0,0,0,0,0 },
        .{ 2,1,1,1,1,2,0,0,0,0,0,0,0 },
        .{ 2,1,1,1,1,1,2,0,0,0,0,0,0 },
        .{ 2,1,1,1,1,1,1,2,0,0,0,0,0 },
        .{ 2,1,1,1,1,1,1,1,2,0,0,0,0 },
        .{ 2,1,1,1,1,1,2,2,2,0,0,0,0 },
        .{ 2,1,1,2,1,1,2,0,0,0,0,0,0 },
        .{ 2,1,2,0,2,1,1,2,0,0,0,0,0 },
        .{ 2,2,0,0,0,2,1,1,2,0,0,0,0 },
    };
    for (arrow, 0..) |row, dy| {
        for (row, 0..) |v, dx| {
            if (v == 0) continue;
            const x = cx + @as(i32, @intCast(dx));
            const y = cy + @as(i32, @intCast(dy));
            if (x < 0 or y < 0 or x >= W or y >= H) continue;
            const color: u32 = if (v == 1) 0xFFFFFFFF else 0xFF000000;
            px[@intCast(y * pitch + x)] = color;
        }
    }
}
