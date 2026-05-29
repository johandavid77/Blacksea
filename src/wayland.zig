/// wayland.zig — Protocolo Wayland desde cero
///
/// El servidor abre un Unix socket. Los clientes conectan.
/// Cada mensaje: [object_id: u32][size: u16][opcode: u16][payload...]
///
/// Objetos core que implementamos:
///   ID 1: wl_display    — punto de entrada, sync, error
///   ID 2: wl_registry   — lista de globals disponibles
///   wl_compositor       — crea wl_surface
///   wl_shm              — memoria compartida para buffers
///   xdg_wm_base         — ventanas de escritorio

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

// ─── Wire format ──────────────────────────────────────────────────────────────

/// Buffer simple para construir mensajes Wayland sin heap
pub const MsgBuf = struct {
    data: [512]u8 = undefined,
    len : usize   = 0,

    pub fn uint(self: *MsgBuf, v: u32) void {
        std.mem.writeInt(u32, self.data[self.len..][0..4], v, .little);
        self.len += 4;
    }
    pub fn int(self: *MsgBuf, v: i32) void {
        std.mem.writeInt(i32, self.data[self.len..][0..4], v, .little);
        self.len += 4;
    }
    pub fn string(self: *MsgBuf, s: []const u8) void {
        const slen: u32 = @intCast(s.len + 1);
        self.uint(slen);
        @memcpy(self.data[self.len..self.len + s.len], s);
        self.len += s.len;
        self.data[self.len] = 0;
        self.len += 1;
        const pad = (4 - (slen % 4)) % 4;
        @memset(self.data[self.len..self.len + pad], 0);
        self.len += pad;
    }
    pub fn slice(self: *MsgBuf) []const u8 {
        return self.data[0..self.len];
    }
};

pub fn readUint(data: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, data[offset..][0..4], .little);
}

pub fn readInt(data: []const u8, offset: usize) i32 {
    return std.mem.readInt(i32, data[offset..][0..4], .little);
}

// ─── Mensaje ──────────────────────────────────────────────────────────────────

pub const Header = extern struct {
    object_id: u32,
    size_and_opcode: u32,  // size en bits 31..16, opcode en bits 15..0

    pub fn size(self: Header) u16 {
        return @intCast(self.size_and_opcode >> 16);
    }
    pub fn opcode(self: Header) u16 {
        return @intCast(self.size_and_opcode & 0xFFFF);
    }
    pub fn encode(object_id: u32, op: u16, payload_len: u16) Header {
        const total: u32 = 8 + payload_len;
        return .{
            .object_id = object_id,
            .size_and_opcode = (@as(u32, total) << 16) | op,
        };
    }
};

// ─── Cliente ──────────────────────────────────────────────────────────────────

pub const Client = struct {
    fd         : i32,
    recv_buf   : [4096]u8 = undefined,
    recv_len   : usize = 0,
    next_id    : u32 = 0xFF000000,  // IDs del servidor empiezan acá
    allocator  : std.mem.Allocator,

    // Estado de globals asignados
    compositor_id : u32 = 0,
    shm_id        : u32 = 0,
    xdg_id        : u32 = 0,

    pub fn init(fd: i32, allocator: std.mem.Allocator) Client {
        return .{ .fd = fd, .allocator = allocator };
    }

    pub fn recv(self: *Client) ![]u8 {
        const n = linux.read(
            @intCast(self.fd),
            self.recv_buf[self.recv_len..].ptr,
            self.recv_buf.len - self.recv_len,
        );
        const bytes: i64 = @bitCast(n);
        if (bytes <= 0) return error.Disconnected;
        self.recv_len += @intCast(bytes);
        return self.recv_buf[0..self.recv_len];
    }

    pub fn consume(self: *Client, n: usize) void {
        if (n >= self.recv_len) {
            self.recv_len = 0;
        } else {
            std.mem.copyForwards(u8, &self.recv_buf, self.recv_buf[n..self.recv_len]);
            self.recv_len -= n;
        }
    }

    pub fn send(self: *Client, data: []const u8) void {
        _ = linux.write(@intCast(self.fd), data.ptr, data.len);
    }

    pub fn sendEvent(self: *Client, object_id: u32, opcode: u16, payload: []const u8) void {
        const hdr = Header.encode(object_id, opcode, @intCast(payload.len));
        var h: [8]u8 = undefined;
        std.mem.writeInt(u32, h[0..4], hdr.object_id, .little);
        std.mem.writeInt(u32, h[4..8], hdr.size_and_opcode, .little);
        self.send(&h);
        if (payload.len > 0) self.send(payload);
    }

    pub fn newId(self: *Client) u32 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }
};

// ─── Globals Wayland ──────────────────────────────────────────────────────────

// Nombres e interfaces que anunciamos en el registry
pub const globals = [_]struct { name: []const u8, version: u32 }{
    .{ .name = "wl_compositor", .version = 4 },
    .{ .name = "wl_shm",        .version = 1 },
    .{ .name = "xdg_wm_base",   .version = 2 },
    .{ .name = "wl_seat",       .version = 7 },
    .{ .name = "wl_output",     .version = 4 },
};

// ─── Handlers de requests ─────────────────────────────────────────────────────

/// wl_display (object_id = 1)
/// opcodes: 0=sync, 1=get_registry
pub fn handleDisplay(client: *Client, opcode: u16, payload: []const u8) !void {
    switch (opcode) {
        0 => { // sync — responder con wl_callback.done
            const callback_id = readUint(payload, 0);
            // wl_callback::done (opcode 0), serial = 0
            var buf = MsgBuf{};
            buf.uint(0);  // serial
            client.sendEvent(callback_id, 0, buf.slice());
            var del = MsgBuf{};
            del.uint(callback_id);
            client.sendEvent(1, 1, del.slice());
        },
        1 => { // get_registry
            const registry_id = readUint(payload, 0);
            // Anunciar todos los globals
            for (globals, 0..) |g, i| {
                var buf = MsgBuf{};
                buf.uint(@intCast(i + 1));
                buf.string(g.name);
                buf.uint(g.version);
                client.sendEvent(registry_id, 0, buf.slice());
            }
            std.log.info("wayland: registry enviado a cliente fd={}", .{client.fd});
        },
        else => std.log.warn("wayland: wl_display opcode desconocido: {}", .{opcode}),
    }
}

/// wl_registry — bind de globals
/// opcode 0 = bind(name, interface, version, new_id)
pub fn handleRegistry(client: *Client, opcode: u16, payload: []const u8) void {
    if (opcode != 0) return;
    const name = readUint(payload, 0);
    // interface string, version, new_id siguen
    // name 1=wl_compositor, 2=wl_shm, 3=xdg_wm_base, 4=wl_seat, 5=wl_output
    switch (name) {
        1 => { client.compositor_id = readUint(payload, payload.len - 4); std.log.info("wayland: wl_compositor bound id={}", .{client.compositor_id}); },
        2 => { client.shm_id        = readUint(payload, payload.len - 4); std.log.info("wayland: wl_shm bound id={}", .{client.shm_id}); },
        3 => { client.xdg_id        = readUint(payload, payload.len - 4); std.log.info("wayland: xdg_wm_base bound id={}", .{client.xdg_id}); },
        else => {},
    }
}

// ─── Servidor ─────────────────────────────────────────────────────────────────

pub const Server = struct {
    socket_fd : i32,
    clients   : [16]?Client = [_]?Client{null} ** 16,
    allocator : std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Server {
        // Crear directorio del socket si no existe
        _ = linux.mkdir("/run/user/1000", 0o755);

        // Eliminar socket anterior si existe
        const socket_path = "/run/user/1000/wayland-0";
        _ = linux.unlink("/run/user/1000/wayland-0");

        // Crear Unix domain socket
        const sock_rc = linux.socket(
            linux.AF.UNIX,
            linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC,
            0,
        );
        const sock: i32 = @bitCast(@as(u32, @truncate(sock_rc)));
        if (sock < 0) return error.SocketFailed;

        // Bind al path
        var addr = std.posix.sockaddr.un{
            .family = linux.AF.UNIX,
            .path   = std.mem.zeroes([108]u8),
        };
        @memcpy(addr.path[0..socket_path.len], socket_path);

        const bind_rc = linux.bind(
            @intCast(sock),
            @ptrCast(&addr),
            @sizeOf(@TypeOf(addr)),
        );
        if (@as(i32, @bitCast(@as(u32, @truncate(bind_rc)))) < 0)
            return error.BindFailed;

        const listen_rc = linux.listen(@intCast(sock), 16);
        if (@as(i32, @bitCast(@as(u32, @truncate(listen_rc)))) < 0)
            return error.ListenFailed;

        std.log.info("wayland: socket en {s}", .{socket_path});
        return Server{ .socket_fd = sock, .allocator = allocator };
    }

    pub fn acceptClient(self: *Server) void {
        const rc = linux.accept4(
            @intCast(self.socket_fd), null, null,
            linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC,
        );
        const fd: i32 = @bitCast(@as(u32, @truncate(rc)));
        if (fd < 0) return;

        for (&self.clients) |*slot| {
            if (slot.* == null) {
                slot.* = Client.init(fd, self.allocator);
                std.log.info("wayland: cliente conectado fd={}", .{fd});
                return;
            }
        }
        _ = linux.close(@intCast(fd));
        std.log.warn("wayland: demasiados clientes", .{});
    }

    pub fn pollClients(self: *Server) void {
        for (&self.clients) |*slot| {
            var client = &(slot.* orelse continue);
            const data = client.recv() catch {
                std.log.info("wayland: cliente fd={} desconectado", .{client.fd});
                _ = linux.close(@intCast(client.fd));
                slot.* = null;
                continue;
            };

            var offset: usize = 0;
            while (offset + 8 <= data.len) {
                const object_id = readUint(data, offset);
                const size_op   = readUint(data, offset + 4);
                const msg_size  : u16 = @intCast(size_op >> 16);
                const opcode    : u16 = @intCast(size_op & 0xFFFF);

                if (offset + msg_size > data.len) break;
                const payload = data[offset + 8 .. offset + msg_size];

                dispatch(client, object_id, opcode, payload) catch |err| {
                    std.log.err("wayland: dispatch error: {}", .{err});
                };
                offset += msg_size;
            }
            client.consume(offset);
        }
    }

    fn dispatch(client: *Client, object_id: u32, opcode: u16, payload: []const u8) !void {
        std.log.debug("wayland: obj={} op={} len={}", .{object_id, opcode, payload.len});

        if (object_id == 1) {
            try handleDisplay(client, opcode, payload);
        } else {
            // Por ahora: registry y otros globales
            handleRegistry(client, opcode, payload);
        }
    }

    pub fn deinit(self: *Server) void {
        _ = linux.close(@intCast(self.socket_fd));
        _ = linux.unlink("/run/user/1000/wayland-0");
    }
};

// ─── Integración con surface manager ─────────────────────────────────────────

pub const surface_mod = @import("surface.zig");

/// Responder a wl_shm bind: anunciar formato XRGB8888
pub fn sendShmFormats(client: *Client, shm_id: u32) void {
    // wl_shm::format event (opcode 0)
    var buf = MsgBuf{};
    buf.uint(surface_mod.WL_SHM_FORMAT_ARGB8888);
    client.sendEvent(shm_id, 0, buf.slice());
    var buf2 = MsgBuf{};
    buf2.uint(surface_mod.WL_SHM_FORMAT_XRGB8888);
    client.sendEvent(shm_id, 0, buf2.slice());
}
