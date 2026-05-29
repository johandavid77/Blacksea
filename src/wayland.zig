/// wayland.zig — Protocolo Wayland desde cero
const std = @import("std");
const linux = std.os.linux;
const surface_mod = @import("surface.zig");

pub const SurfaceManager = surface_mod.SurfaceManager;

// ─── Wire format ──────────────────────────────────────────────────────────────

pub fn readUint(data: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, data[offset..][0..4], .little);
}

pub fn readInt(data: []const u8, offset: usize) i32 {
    return std.mem.readInt(i32, data[offset..][0..4], .little);
}

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

// ─── Header ───────────────────────────────────────────────────────────────────

pub const Header = extern struct {
    object_id      : u32,
    size_and_opcode: u32,
    pub fn size(self: Header) u16   { return @intCast(self.size_and_opcode >> 16); }
    pub fn opcode(self: Header) u16 { return @intCast(self.size_and_opcode & 0xFFFF); }
};

// ─── Cliente ──────────────────────────────────────────────────────────────────

pub const Client = struct {
    fd          : i32,
    recv_buf    : [4096]u8 = undefined,
    recv_len    : usize = 0,
    next_id     : u32 = 0xFF000000,

    // IDs de objetos bindeados
    compositor_id: u32 = 0,
    shm_id       : u32 = 0,
    xdg_id       : u32 = 0,
    seat_id      : u32 = 0,

    pub fn init(fd: i32) Client { return .{ .fd = fd }; }

    pub fn recv(self: *Client) ![]u8 {
        const n = linux.read(@intCast(self.fd), self.recv_buf[self.recv_len..].ptr,
            self.recv_buf.len - self.recv_len);
        const bytes: isize = @bitCast(n);
        if (bytes < 0) {
            const err = std.posix.errno(n);
            if (err == .AGAIN) {
                // No hay datos disponibles — no es error
                if (self.recv_len > 0) return self.recv_buf[0..self.recv_len];
                return error.WouldBlock;
            }
            return error.Disconnected;
        }
        if (bytes == 0) return error.Disconnected;
        self.recv_len += @intCast(bytes);
        return self.recv_buf[0..self.recv_len];
    }

    pub fn consume(self: *Client, n: usize) void {
        if (n >= self.recv_len) { self.recv_len = 0; }
        else {
            std.mem.copyForwards(u8, &self.recv_buf, self.recv_buf[n..self.recv_len]);
            self.recv_len -= n;
        }
    }

    pub fn send(self: *Client, data: []const u8) void {
        _ = linux.write(@intCast(self.fd), data.ptr, data.len);
    }

    pub fn sendEvent(self: *Client, object_id: u32, opcode: u16, payload: []const u8) void {
        const total: u32 = @intCast(8 + payload.len);
        var h: [8]u8 = undefined;
        std.mem.writeInt(u32, h[0..4], object_id, .little);
        std.mem.writeInt(u32, h[4..8], (total << 16) | opcode, .little);
        std.log.info("send: obj={} op={} size={}", .{object_id, opcode, total});
        self.send(&h);
        if (payload.len > 0) self.send(payload);
    }

    pub fn newId(self: *Client) u32 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }
};

// ─── Globals ──────────────────────────────────────────────────────────────────

pub const globals = [_]struct { name: []const u8, version: u32 }{
    .{ .name = "wl_compositor", .version = 4 },
    .{ .name = "wl_shm",        .version = 1 },
    .{ .name = "xdg_wm_base",   .version = 2 },
    .{ .name = "wl_seat",       .version = 7 },
    .{ .name = "wl_output",     .version = 4 },
};

// ─── Servidor ─────────────────────────────────────────────────────────────────

pub const Server = struct {
    socket_fd: i32,
    clients  : [16]?Client = [_]?Client{null} ** 16,
    surfaces : SurfaceManager,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Server {
        _ = linux.mkdir("/run/user/1000", 0o755);
        _ = linux.unlink("/run/user/1000/wayland-0");

        const sock_rc = linux.socket(
            linux.AF.UNIX,
            linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
        const sock: i32 = @bitCast(@as(u32, @truncate(sock_rc)));
        if (sock < 0) return error.SocketFailed;

        var addr = std.posix.sockaddr.un{
            .family = linux.AF.UNIX,
            .path   = std.mem.zeroes([108]u8),
        };
        const path = "/run/user/1000/wayland-0";
        @memcpy(addr.path[0..path.len], path);

        if (@as(i32,@bitCast(@as(u32,@truncate(linux.bind(@intCast(sock),@ptrCast(&addr),@sizeOf(@TypeOf(addr))))))) < 0)
            return error.BindFailed;
        if (@as(i32,@bitCast(@as(u32,@truncate(linux.listen(@intCast(sock), 16))))) < 0)
            return error.ListenFailed;

        std.log.info("wayland: socket en {s}", .{path});
        return Server{
            .socket_fd = sock,
            .surfaces  = SurfaceManager.init(),
            .allocator = allocator,
        };
    }

    pub fn acceptClient(self: *Server) void {
        const rc = linux.accept4(@intCast(self.socket_fd), null, null,
            linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);
        const fd: i32 = @bitCast(@as(u32, @truncate(rc)));
        if (fd < 0) return;
        for (&self.clients) |*slot| {
            if (slot.* == null) {
                slot.* = Client.init(fd);
                std.log.info("wayland: cliente conectado fd={}", .{fd});
                return;
            }
        }
        _ = linux.close(@intCast(fd));
    }

    pub fn pollClients(self: *Server) void {
        for (&self.clients) |*slot| {
            var client = &(slot.* orelse continue);
            const data = client.recv() catch |err| {
                if (err == error.WouldBlock) continue;
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
                if (offset + msg_size > data.len) break;
                if (msg_size < 8) { offset += @max(msg_size, 1); continue; }
                const payload = data[offset + 8 .. offset + msg_size];
                self.dispatch(client, object_id, opcode, payload);
                offset += msg_size;
            }
            client.consume(offset);
        }
    }

    fn dispatch(self: *Server, client: *Client, object_id: u32, opcode: u16, payload: []const u8) void {
        // wl_display (id=1)
        if (object_id == 1) {
            switch (opcode) {
                0 => { // sync
                    const cb = readUint(payload, 0);
                    var b = MsgBuf{}; b.uint(0);
                    client.sendEvent(cb, 0, b.slice());
                    var d = MsgBuf{}; d.uint(cb);
                    client.sendEvent(1, 1, d.slice());
                },
                1 => { // get_registry
                    const reg_id = readUint(payload, 0);
                    std.log.info("get_registry: reg_id={}", .{reg_id});
                    for (globals, 0..) |g, i| {
                        var b = MsgBuf{};
                        b.uint(@intCast(i + 1));
                        b.string(g.name);
                        b.uint(g.version);
                        client.sendEvent(reg_id, 0, b.slice());
                    }
                },
                else => {},
            }
            return;
        }

        // wl_registry bind (cualquier objeto que no reconocemos aún)
        // Si el cliente bindea globals, guardamos los IDs
        if (opcode == 0 and payload.len >= 8) {
            const name = readUint(payload, 0);
            const new_id = readUint(payload, payload.len - 4);
            switch (name) {
                1 => { client.compositor_id = new_id; std.log.info("wl_compositor id={}", .{new_id}); },
                2 => { // wl_shm
                    client.shm_id = new_id;
                    std.log.info("wl_shm id={}", .{new_id});
                    // Anunciar formatos soportados
                    var b = MsgBuf{}; b.uint(surface_mod.WL_SHM_FORMAT_ARGB8888);
                    client.sendEvent(new_id, 0, b.slice());
                    var b2 = MsgBuf{}; b2.uint(surface_mod.WL_SHM_FORMAT_XRGB8888);
                    client.sendEvent(new_id, 0, b2.slice());
                },
                3 => { // xdg_wm_base
                    client.xdg_id = new_id;
                    std.log.info("xdg_wm_base id={}", .{new_id});
                },
                4 => { client.seat_id = new_id; },
                else => {},
            }
            return;
        }

        // wl_compositor.create_surface (opcode 0)
        if (object_id == client.compositor_id and opcode == 0) {
            const new_id = readUint(payload, 0);
            _ = self.surfaces.createSurface(new_id, client.fd);
            return;
        }

        // xdg_wm_base.pong (opcode 3) — respuesta al ping
        if (object_id == client.xdg_id and opcode == 3) return;

        // wl_shm.create_pool (opcode 0): fd via ancdata, size
        // Por ahora manejamos en pollClients con recvmsg

        // wl_surface requests
        if (self.surfaces.getSurface(object_id)) |surf| {
            switch (opcode) {
                0 => { // destroy
                    self.surfaces.destroySurface(object_id);
                },
                1 => { // attach(buffer_id, x, y)
                    if (payload.len >= 12) {
                        const buf_id = readUint(payload, 0);
                        surf.x = readInt(payload, 4);
                        surf.y = readInt(payload, 8);
                        surf.pending_buf = self.surfaces.getBuffer(buf_id);
                    }
                },
                6 => { // commit
                    if (surf.pending_buf) |pb| {
                        surf.buffer = pb;
                        surf.width  = pb.width;
                        surf.height = pb.height;
                        surf.mapped = true;
                        surf.pending_buf = null;
                        std.log.info("surface {}: commit {}x{}", .{object_id, pb.width, pb.height});
                    }
                },
                else => {},
            }
            return;
        }

        std.log.info("wayland: obj={} op={} len={} (no manejado)", .{object_id, opcode, payload.len});
    }

    pub fn deinit(self: *Server) void {
        _ = linux.close(@intCast(self.socket_fd));
        _ = linux.unlink("/run/user/1000/wayland-0");
    }
};
