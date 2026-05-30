/// wayland.zig — Protocolo Wayland desde cero
const std = @import("std");
const linux = std.os.linux;
const surface_mod = @import("surface.zig");

pub const SurfaceManager = surface_mod.SurfaceManager;

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
    pub fn string(self: *MsgBuf, s: []const u8) void {
        const slen: u32 = @intCast(s.len + 1);
        self.uint(slen);
        @memcpy(self.data[self.len..self.len + s.len], s);
        self.len += s.len;
        self.data[self.len] = 0; self.len += 1;
        const pad = (4 - (slen % 4)) % 4;
        @memset(self.data[self.len..self.len + pad], 0);
        self.len += pad;
    }
    pub fn slice(self: *MsgBuf) []const u8 { return self.data[0..self.len]; }
};

pub const Client = struct {
    fd       : i32,
    recv_buf : [4096]u8 = undefined,
    recv_len : usize = 0,
    next_id  : u32 = 0xFF000000,
    compositor_id: u32 = 0,
    shm_id       : u32 = 0,
    xdg_id       : u32 = 0,
    seat_id      : u32 = 0,

    pub fn init(fd: i32) Client { return .{ .fd = fd }; }

    pub fn send(self: *Client, data: []const u8) void {
        var sent: usize = 0;
        while (sent < data.len) {
            const rc = linux.sendto(@intCast(self.fd), data[sent..].ptr,
                data.len - sent, linux.MSG.NOSIGNAL, null, 0);
            const n: isize = @bitCast(rc);
            if (n <= 0) break;
            sent += @intCast(n);
        }
    }

    pub fn sendEvent(self: *Client, object_id: u32, opcode: u16, payload: []const u8) void {
        const total: u32 = @intCast(8 + payload.len);
        var h: [8]u8 = undefined;
        std.mem.writeInt(u32, h[0..4], object_id, .little);
        std.mem.writeInt(u32, h[4..8], (total << 16) | opcode, .little);
        self.send(&h);
        if (payload.len > 0) self.send(payload);
    }

    pub fn newId(self: *Client) u32 {
        const id = self.next_id; self.next_id += 1; return id;
    }
};

pub const globals = [_]struct { name: []const u8, version: u32 }{
    .{ .name = "wl_compositor", .version = 4 },
    .{ .name = "wl_shm",        .version = 1 },
    .{ .name = "xdg_wm_base",   .version = 2 },
    .{ .name = "wl_seat",       .version = 7 },
    .{ .name = "wl_output",     .version = 4 },
};

pub const Server = struct {
    socket_fd: i32,
    clients  : [16]?Client = [_]?Client{null} ** 16,
    surfaces : SurfaceManager,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Server {
        _ = linux.mkdir("/run/user/1000", 0o755);
        _ = linux.unlink("/run/user/1000/wayland-0");

        const sock_rc = linux.socket(linux.AF.UNIX,
            linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        const sock: i32 = @bitCast(@as(u32, @truncate(sock_rc)));
        if (sock < 0) return error.SocketFailed;

        var addr = std.posix.sockaddr.un{
            .family = linux.AF.UNIX,
            .path   = std.mem.zeroes([108]u8),
        };
        const path = "/run/user/1000/wayland-0";
        @memcpy(addr.path[0..path.len], path);

        if (@as(i32,@bitCast(@as(u32,@truncate(linux.bind(@intCast(sock),
            @ptrCast(&addr),@sizeOf(@TypeOf(addr))))))) < 0) return error.BindFailed;
        if (@as(i32,@bitCast(@as(u32,@truncate(linux.listen(
            @intCast(sock), 16))))) < 0) return error.ListenFailed;

        std.log.info("wayland: socket en {s}", .{path});
        return Server{ .socket_fd = sock, .surfaces = SurfaceManager.init(),
            .allocator = allocator };
    }

    /// Poll bloqueante hasta 16ms — acepta nuevos clientes y procesa mensajes
    pub fn poll(self: *Server) void {
        var pfds: [17]linux.pollfd = undefined;
        var nfds: usize = 0;

        pfds[0] = .{ .fd = self.socket_fd, .events = linux.POLL.IN, .revents = 0 };
        nfds = 1;

        for (self.clients) |slot| {
            if (slot) |c| {
                pfds[nfds] = .{ .fd = c.fd, .events = linux.POLL.IN, .revents = 0 };
                nfds += 1;
            }
        }

        _ = linux.poll(@ptrCast(&pfds), nfds, 16);

        // Aceptar nuevos clientes
        if (pfds[0].revents & linux.POLL.IN != 0) {
            const rc = linux.accept4(@intCast(self.socket_fd), null, null,
                linux.SOCK.CLOEXEC);
            const fd: i32 = @bitCast(@as(u32, @truncate(rc)));
            if (fd >= 0) {
                for (&self.clients) |*slot| {
                    if (slot.* == null) {
                        slot.* = Client.init(fd);
                        std.log.info("wayland: cliente fd={}", .{fd});
                        // Esperar datos iniciales del cliente recién conectado
                        var new_pfd = linux.pollfd{ .fd = fd, .events = linux.POLL.IN, .revents = 0 };
                        const pr = linux.poll(@ptrCast(&new_pfd), 1, 200);
                        std.log.info("poll nuevo cliente: rc={} revents={}", .{pr, new_pfd.revents});
                        // Leer y procesar inmediatamente si hay datos
                        if (new_pfd.revents & linux.POLL.IN != 0) {
                            var new_client = &(slot.* orelse break);
                            const nr = linux.read(@intCast(fd),
                                new_client.recv_buf[0..].ptr, new_client.recv_buf.len);
                            std.log.info("leido {} bytes del cliente nuevo", .{nr});
                            if (@as(isize, @bitCast(nr)) > 0) {
                                const b = new_client.recv_buf[0..@intCast(@as(isize,@bitCast(nr)))];
                                if (b.len >= 8) {
                                    const oid2 = readUint(b, 0);
                                    const sop2 = readUint(b, 4);
                                    std.log.info("msg: obj={} size={} op={}", .{oid2, sop2>>16, sop2&0xFFFF});
                                }
                            }
                            if (@as(isize, @bitCast(nr)) > 0) {
                                new_client.recv_len = @intCast(nr);
                                // Dispatch inmediato
                                var off: usize = 0;
                                while (off + 8 <= new_client.recv_len) {
                                    const oid = readUint(new_client.recv_buf[0..new_client.recv_len], off);
                                    const sop = readUint(new_client.recv_buf[0..new_client.recv_len], off + 4);
                                    const msz: u16 = @intCast(sop >> 16);
                                    const opc: u16 = @intCast(sop & 0xFFFF);
                                    if (msz < 8 or off + msz > new_client.recv_len) break;
                                    const pl = new_client.recv_buf[off + 8 .. off + msz];
                                    self.dispatch(new_client, oid, opc, pl);
                                    off += msz;
                                }
                                new_client.recv_len = 0;
                            }
                        }
                        break;
                    }
                }
            }
        }

        // Procesar mensajes de clientes existentes
        for (&self.clients) |*slot| {
            var client = &(slot.* orelse continue);

            // Buscar el fd del cliente en el array de pfds
            var pfd_idx: usize = 0;
            var found = false;
            for (pfds[1..nfds], 1..) |pfd, i| {
                if (pfd.fd == client.fd) { pfd_idx = i; found = true; break; }
            }
            if (!found) continue;
            if (pfds[pfd_idx].revents & linux.POLL.IN == 0) continue;

            // Leer datos
            const n = linux.read(@intCast(client.fd),
                client.recv_buf[client.recv_len..].ptr,
                client.recv_buf.len - client.recv_len);
            const bytes: isize = @bitCast(n);
            if (bytes <= 0) {
                _ = linux.close(@intCast(client.fd));
                slot.* = null;
                continue;
            }
            client.recv_len += @intCast(bytes);

            // Dispatch mensajes
            var offset: usize = 0;
            while (offset + 8 <= client.recv_len) {
                const object_id = readUint(client.recv_buf[0..client.recv_len], offset);
                const size_op   = readUint(client.recv_buf[0..client.recv_len], offset + 4);
                const msg_size  : u16 = @intCast(size_op >> 16);
                const opcode    : u16 = @intCast(size_op & 0xFFFF);
                if (msg_size < 8 or offset + msg_size > client.recv_len) break;
                const payload = client.recv_buf[offset + 8 .. offset + msg_size];
                self.dispatch(client, object_id, opcode, payload);
                offset += msg_size;
            }
            if (offset > 0) {
                std.mem.copyForwards(u8, &client.recv_buf,
                    client.recv_buf[offset..client.recv_len]);
                client.recv_len -= offset;
            }
        }
    }

    fn dispatch(self: *Server, client: *Client, object_id: u32, opcode: u16, payload: []const u8) void {
        if (object_id == 1) {
            switch (opcode) {
                0 => { // sync
                    if (payload.len >= 4) {
                        const cb = readUint(payload, 0);
                        var b = MsgBuf{}; b.uint(0);
                        client.sendEvent(cb, 0, b.slice());
                        var d = MsgBuf{}; d.uint(cb);
                        client.sendEvent(1, 1, d.slice());
                    }
                },
                1 => { // get_registry
                    if (payload.len >= 4) {
                        const reg_id = readUint(payload, 0);
                        std.log.info("get_registry reg_id={}", .{reg_id});
                        for (globals, 0..) |g, i| {
                            var b = MsgBuf{};
                            b.uint(@intCast(i + 1));
                            b.string(g.name);
                            b.uint(g.version);
                            client.sendEvent(reg_id, 0, b.slice());
                        }
                        std.log.info("globals enviados", .{});
                    }
                },
                else => {},
            }
            return;
        }

        // registry bind
        if (opcode == 0 and payload.len >= 8) {
            const name   = readUint(payload, 0);
            const new_id = readUint(payload, payload.len - 4);
            switch (name) {
                1 => { client.compositor_id = new_id; },
                2 => {
                    client.shm_id = new_id;
                    var b = MsgBuf{}; b.uint(surface_mod.WL_SHM_FORMAT_ARGB8888);
                    client.sendEvent(new_id, 0, b.slice());
                    var b2 = MsgBuf{}; b2.uint(surface_mod.WL_SHM_FORMAT_XRGB8888);
                    client.sendEvent(new_id, 0, b2.slice());
                },
                3 => { client.xdg_id = new_id; },
                4 => { client.seat_id = new_id; },
                else => {},
            }
            return;
        }

        if (object_id == client.compositor_id and opcode == 0) {
            if (payload.len >= 4) {
                const new_id = readUint(payload, 0);
                _ = self.surfaces.createSurface(new_id, client.fd);
            }
            return;
        }

        if (self.surfaces.getSurface(object_id)) |surf| {
            switch (opcode) {
                0 => self.surfaces.destroySurface(object_id),
                1 => { // attach
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
                        std.log.info("surface {} commit {}x{}", .{object_id, pb.width, pb.height});
                    }
                },
                else => {},
            }
            return;
        }
    }

    pub fn deinit(self: *Server) void {
        _ = linux.close(@intCast(self.socket_fd));
        _ = linux.unlink("/run/user/1000/wayland-0");
    }
};
