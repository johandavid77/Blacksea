/// xdg_shell.zig — xdg_wm_base, xdg_surface, xdg_toplevel
///
/// Protocolo que convierte wl_surface en ventanas reales.
/// Referencia: xdg-shell.xml del protocolo Wayland.

const std = @import("std");
const linux = std.os.linux;

pub const MAX_TOPLEVELS = 16;

// ─── Estado de una ventana xdg ───────────────────────────────────────────────

pub const XdgToplevel = struct {
    id             : u32 = 0,
    xdg_surface_id : u32 = 0,
    surface_id     : u32 = 0,
    client_fd      : i32 = -1,

    title  : [128]u8 = std.mem.zeroes([128]u8),
    app_id : [128]u8 = std.mem.zeroes([128]u8),

    width  : i32 = 800,
    height : i32 = 600,

    configured : bool = false,
    mapped     : bool = false,

    pub fn getTitle(self: *XdgToplevel) []const u8 {
        return std.mem.sliceTo(&self.title, 0);
    }

    pub fn getAppId(self: *XdgToplevel) []const u8 {
        return std.mem.sliceTo(&self.app_id, 0);
    }
};

// ─── Manager ─────────────────────────────────────────────────────────────────

pub const XdgManager = struct {
    toplevels: [MAX_TOPLEVELS]XdgToplevel = std.mem.zeroes([MAX_TOPLEVELS]XdgToplevel),
    count    : usize = 0,

    pub fn init() XdgManager {
        return .{};
    }

    pub fn createToplevel(
        self          : *XdgManager,
        toplevel_id   : u32,
        xdg_surface_id: u32,
        surface_id    : u32,
        client_fd     : i32,
    ) ?*XdgToplevel {
        for (&self.toplevels) |*t| {
            if (t.id == 0) {
                t.* = std.mem.zeroes(XdgToplevel);
                t.id              = toplevel_id;
                t.xdg_surface_id  = xdg_surface_id;
                t.surface_id      = surface_id;
                t.client_fd       = client_fd;
                t.width           = 800;
                t.height          = 600;
                self.count += 1;
                std.log.info("xdg: toplevel id={} surface={}", .{toplevel_id, surface_id});
                return t;
            }
        }
        return null;
    }

    pub fn getToplevel(self: *XdgManager, id: u32) ?*XdgToplevel {
        for (&self.toplevels) |*t| {
            if (t.id == id) return t;
        }
        return null;
    }

    pub fn getToplevelBySurface(self: *XdgManager, surface_id: u32) ?*XdgToplevel {
        for (&self.toplevels) |*t| {
            if (t.id > 0 and t.surface_id == surface_id) return t;
        }
        return null;
    }

    pub fn destroyToplevel(self: *XdgManager, id: u32) void {
        for (&self.toplevels) |*t| {
            if (t.id == id) {
                t.* = std.mem.zeroes(XdgToplevel);
                if (self.count > 0) self.count -= 1;
                return;
            }
        }
    }
};

// ─── Helpers para enviar eventos xdg ─────────────────────────────────────────

/// Enviar xdg_surface.configure(serial)
pub fn sendXdgSurfaceConfigure(client_fd: i32, xdg_surface_id: u32, serial: u32) void {
    var buf: [8 + 4]u8 = undefined;
    // Header: object_id, (size<<16)|opcode
    // xdg_surface::configure opcode = 0
    std.mem.writeInt(u32, buf[0..4], xdg_surface_id, .little);
    std.mem.writeInt(u32, buf[4..8], (@as(u32, 12) << 16) | 0, .little);
    std.mem.writeInt(u32, buf[8..12], serial, .little);
    _ = linux.sendto(@intCast(client_fd), &buf, buf.len, linux.MSG.NOSIGNAL, null, 0);
    std.log.info("xdg: configure serial={} → fd={}", .{serial, client_fd});
}

/// Enviar xdg_toplevel.configure(width, height, states)
pub fn sendToplevelConfigure(client_fd: i32, toplevel_id: u32, w: i32, h: i32) void {
    // xdg_toplevel::configure opcode = 0
    // payload: width(i32) + height(i32) + states_array_len(u32) = 12 bytes
    var buf: [8 + 12]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], toplevel_id, .little);
    std.mem.writeInt(u32, buf[4..8], (@as(u32, 20) << 16) | 0, .little);
    std.mem.writeInt(i32, buf[8..12], w, .little);
    std.mem.writeInt(i32, buf[12..16], h, .little);
    std.mem.writeInt(u32, buf[16..20], 0, .little); // states array vacío
    _ = linux.sendto(@intCast(client_fd), &buf, buf.len, linux.MSG.NOSIGNAL, null, 0);
}
