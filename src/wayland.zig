/// wayland.zig — Protocolo Wayland desde cero
const std = @import("std");
const linux = std.os.linux;
const surface_mod = @import("surface.zig");

pub const SurfaceManager = surface_mod.SurfaceManager;
const xdg_mod = @import("xdg_shell.zig");
const seat_mod = @import("seat.zig");
pub const XdgManager = xdg_mod.XdgManager;

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
    pub fn fixed(self: *MsgBuf, v: i32) void { self.uint(@bitCast(v << 8)); }
    pub fn slice(self: *MsgBuf) []const u8 { return self.data[0..self.len]; }
};

pub const Client = struct {
    fd       : i32,
    recv_buf : [65536]u8 = undefined,
    recv_len : usize = 0,
    next_id  : u32 = 0xFF000000,
    compositor_id: u32 = 0,
    shm_id       : u32 = 0,
    xdg_id       : u32 = 0,
    seat_id      : u32 = 0,
    pool_id      : u32 = 0,
    pool_fd      : i32 = -1,
    pool_map      : []u8 = &[_]u8{},
    pool_size     : usize = 0,
    fd_queue      : [8]i32 = [_]i32{-1} ** 8,
    fd_queue_len  : usize = 0,
    pool_ids     : [8]u32 = std.mem.zeroes([8]u32),
    pool_count   : usize = 0,
    xdg_surface_ids: [8]u32 = std.mem.zeroes([8]u32),
    xdg_surface_count: usize = 0,
    last_wl_surface_id: u32 = 0,
    configure_serial: u32 = 0,
    pointer_surface_id: u32 = 0,
    has_keyboard_focus: bool = false,
    prev_buf_id: u32 = 0,
    last_xdg_surface_id: u32 = 0,
    reg_id: u32 = 2, // default wl_registry id
    keyboard_id : u32 = 0,
    pointer_id  : u32 = 0,
    frame_cb_id        : u32  = 0,
    cursor_surface_id  : u32  = 0,
    cursor_hotspot_x   : i32  = 0,
    cursor_hotspot_y   : i32  = 0,
    keyboard_given     : bool = false,
    needs_blit  : bool = false,
    dead        : bool = false,

    pub fn init(fd: i32) Client { return .{ .fd = fd }; }

    pub fn send(self: *Client, data: []const u8) void {
        var sent: usize = 0;
        while (sent < data.len) {
            const rc = linux.sendto(@intCast(self.fd), data[sent..].ptr,
                data.len - sent, linux.MSG.NOSIGNAL, null, 0);
            const n: isize = @bitCast(rc);
            if (n < 0) { _ = linux.nanosleep(&.{ .sec = 0, .nsec = 100_000 }, null); continue; } // EAGAIN — reintentar
            if (n == 0) { self.dead = true; return; } // EOF real
            sent += @intCast(n);
        }
    }

    pub fn sendEvent(self: *Client, object_id: u32, opcode: u16, payload: []const u8) void {
        if (opcode == 0) std.log.info("SEND0 fd={} obj={} plen={}", .{self.fd, object_id, payload.len});
        if (self.dead) return;
        if (self.fd != 11) std.log.info("SEND fd={} obj={} op={} plen={}", .{self.fd, object_id, opcode, payload.len});
        const total: u32 = @intCast(8 + payload.len);
        // Enviar header+payload en un solo writev para atomicidad
        var h: [8]u8 = undefined;
        std.mem.writeInt(u32, h[0..4], object_id, .little);
        std.mem.writeInt(u32, h[4..8], (total << 16) | opcode, .little);
        if (payload.len == 0) {
            self.send(&h);
        } else {
            var iovs = [2]std.posix.iovec_const{
                .{ .base = &h, .len = 8 },
                .{ .base = payload.ptr, .len = payload.len },
            };
            const msg = linux.msghdr_const{
                .name = null, .namelen = 0,
                .iov = @ptrCast(&iovs), .iovlen = 2,
                .control = null, .controllen = 0, .flags = 0,
            };
            const rc = linux.sendmsg(@intCast(self.fd), @ptrCast(&msg), linux.MSG.NOSIGNAL);
            _ = rc;
        }
    }

    pub fn newId(self: *Client) u32 {
        const id = self.next_id; self.next_id += 1; return id;
    }
};

pub const globals = [_]struct { name: []const u8, version: u32 }{
    .{ .name = "wl_compositor", .version = 5 },
    .{ .name = "wl_shm",        .version = 1 },
    .{ .name = "xdg_wm_base",   .version = 2 },
    .{ .name = "wl_seat",      .version = 5 },
    .{ .name = "wl_output",        .version = 5 },
    .{ .name = "wl_subcompositor",      .version = 1 },
    .{ .name = "wl_data_device_manager",    .version = 3 },
};

pub const Server = struct {
    socket_fd: i32,
    clients  : [16]?Client = [_]?Client{null} ** 16,
    surfaces : SurfaceManager,
    xdg      : XdgManager,
    allocator: std.mem.Allocator,
    serial   : u32 = 1,
    focused_fd: i32 = -1,
    screen_w: u32 = 1280,
    screen_h: u32 = 720,

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
        return Server{ .socket_fd = sock, .surfaces = SurfaceManager.init(), .xdg = XdgManager.init(),
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
                        // // Esperar datos iniciales del cliente recién conectado
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

            // recvmsg para capturar SCM_RIGHTS del shm fd
            var cmsg_main: [256]u8 align(8) = std.mem.zeroes([256]u8);
            var iov_main = std.posix.iovec{
                .base = client.recv_buf[client.recv_len..].ptr,
                .len  = client.recv_buf.len - client.recv_len,
            };
            var rmsg_main = linux.msghdr{
                .name = null, .namelen = 0,
                .iov = @ptrCast(&iov_main), .iovlen = 1,
                .control = &cmsg_main, .controllen = cmsg_main.len,
                .flags = 0,
            };
            const n = linux.recvmsg(@intCast(client.fd), &rmsg_main, 0);
            if (rmsg_main.controllen >= @sizeOf(linux.cmsghdr)) {
                const cm: *linux.cmsghdr = @ptrCast(@alignCast(&cmsg_main));
                if (cm.level == linux.SOL.SOCKET and cm.type == 1) {
                    const data_len = cm.len - @sizeOf(linux.cmsghdr);
                    const n_fds = data_len / @sizeOf(i32);
                    var fi: usize = 0;
                    while (fi < n_fds) : (fi += 1) {
                        const off = @sizeOf(linux.cmsghdr) + fi * @sizeOf(i32);
                        const sfd: *i32 = @ptrCast(@alignCast(&cmsg_main[off]));
                        if (client.fd_queue_len < 8) {
                            client.fd_queue[client.fd_queue_len] = sfd.*;
                            client.fd_queue_len += 1;
                        }
                        client.pool_fd = sfd.*;
                        std.log.info("SCM_RIGHTS: fd={}", .{sfd.*});
                    }
                }
            }
            const bytes: isize = @bitCast(n);
            if (bytes < 0) { continue; } // EAGAIN o error temporal
            if (client.dead) {
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
        if (object_id == client.seat_id or object_id == 7) std.log.info("DISPATCH_SEAT obj={} op={} plen={} seat_id={} fd={}", .{object_id, opcode, payload.len, client.seat_id, client.fd});
        std.log.info("DISPATCH obj={} op={} len={} shm_id={} comp_id={}", .{object_id, opcode, payload.len, client.shm_id, client.compositor_id});
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
                client.reg_id = reg_id;
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

        // registry bind — para cualquier reg_id del cliente
        if (object_id == client.reg_id and opcode == 0 and payload.len >= 8) {
            const name   = readUint(payload, 0);
            std.log.info("bind fd={} name={} new_id={}", .{client.fd, readUint(payload,0), readUint(payload,8)});
            const new_id = readUint(payload, payload.len - 4);
            switch (name) {
                1 => { client.compositor_id = new_id; },
                2 => {
                    client.shm_id = new_id;
                    var b = MsgBuf{}; b.uint(surface_mod.WL_SHM_FORMAT_ARGB8888);
                    client.sendEvent(new_id, 0, b.slice());  std.log.info("BINDSEND L345 fd={} obj={} name={}", .{client.fd, new_id, name});
                    var b2 = MsgBuf{}; b2.uint(surface_mod.WL_SHM_FORMAT_XRGB8888);
                    client.sendEvent(new_id, 0, b2.slice());  std.log.info("BINDSEND2 L347 fd={} obj={} name={}", .{client.fd, new_id, name});
                },
                3 => { client.xdg_id = new_id; std.log.info("bind xdg fd={} xdg_id={}", .{client.fd, new_id}); },
                4 => {
                    client.seat_id = new_id;
                    // wl_seat::capabilities event (op=0): keyboard|pointer = 3
                    var b = MsgBuf{}; b.uint(3);
                    client.sendEvent(new_id, 0, b.slice());  std.log.info("BINDSEND L354 fd={} obj={} name={}", .{client.fd, new_id, name});
                    // wl_seat::name event (op=1)
                    var n = MsgBuf{}; n.string("seat0");
                    client.sendEvent(new_id, 1, n.slice());
                        std.log.info("wl_seat bound fd={} seat_id={}", .{client.fd, new_id});
                },
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

        // wl_shm.create_pool: new_id(u32) + fd(via SCM_RIGHTS) + size(i32)
        // Como no tenemos SCM_RIGHTS, usamos el archivo /tmp/bs_buf directamente
        std.log.info("dispatch: obj={} shm_id={} op={}", .{object_id, client.shm_id, opcode});
        if (object_id == client.shm_id and opcode == 0 and payload.len >= 8) {
            const pool_id = readUint(payload, 0);
            const size: u32 = if (payload.len >= 8) readUint(payload, 4) else 0;
            const client_fd: u32 = 0; _ = client_fd;
            // Abrir archivo directamente
            var path: [32:0]u8 = std.mem.zeroes([32:0]u8);
            _ = std.fmt.bufPrint(&path, "/tmp/bs_buf", .{}) catch {};
            // Usar SCM_RIGHTS fd si ya lo recibimos, sino abrir archivo
            // Sacar el primer fd de la cola
            var file_fd: i32 = -1;
            if (client.fd_queue_len > 0) {
                file_fd = client.fd_queue[0];
                // Shift queue
                var qi: usize = 0;
                while (qi + 1 < client.fd_queue_len) : (qi += 1) client.fd_queue[qi] = client.fd_queue[qi+1];
                client.fd_queue[client.fd_queue_len-1] = -1;
                client.fd_queue_len -= 1;
            } else file_fd = client.pool_fd;
            if (file_fd < 0) {
                const file_rc = linux.open(&path, .{ .ACCMODE = .RDONLY }, 0);
                file_fd = @bitCast(@as(u32, @truncate(file_rc)));
            }
                const real_sz = linux.lseek(@intCast(file_fd), 0, linux.SEEK.END);
                _ = linux.lseek(@intCast(file_fd), 0, linux.SEEK.SET);
            std.log.info("create_pool id={} size={} pool_fd={} real={}", .{pool_id, size, file_fd, real_sz});
            client.pool_fd = file_fd;
                if (client.pool_map.len > 0) std.posix.munmap(@alignCast(client.pool_map));
                // Guardar fd y size del pool para pread en blitSurface
                client.pool_size = @intCast(size);
            client.pool_id = pool_id;
            if (client.pool_count < 8) {
                client.pool_ids[client.pool_count] = pool_id;
                client.pool_count += 1;
            }
            return;
        }

        // wl_shm_pool.create_buffer — aceptar cualquier pool conocido
        const is_pool = blk: {
            for (client.pool_ids[0..client.pool_count]) |pid| {
                if (pid == object_id) break :blk true;
            }
            break :blk false;
        };
        // wl_shm_pool.resize (opcode 1) y destroy (opcode 2) — ignorar
        if (is_pool and (opcode == 1 or opcode == 2)) { return; }
        if (is_pool and opcode == 0 and payload.len >= 20) {
            const buf_id = readUint(payload, 0);
            const offset = readInt(payload, 4);
            const width  = readInt(payload, 8);
            const height = readInt(payload, 12);
            const stride = readInt(payload, 16);
            const format = if (payload.len >= 24) readUint(payload, 20) else 1;
            std.log.info("create_buffer id={} offset={} {}x{} stride={} fd={}", .{buf_id, offset, width, height, stride, client.pool_fd});
            _ = self.surfaces.createBuffer(buf_id, client.pool_fd, width, height, stride, format, offset);
            return;
        }

        // wl_pointer requests — ignorar todos excepto set_cursor
        if (object_id == client.pointer_id) {
            if (opcode == 0 and payload.len >= 12) { // set_cursor
                client.cursor_surface_id = readUint(payload, 4);
                client.cursor_hotspot_x  = @bitCast(readUint(payload, 8));
                client.cursor_hotspot_y  = @bitCast(readUint(payload, 12));
            }
            return; // ignorar release y cualquier otro opcode
        }
        if (object_id == client.pointer_id and opcode == 0 and payload.len >= 12) {
            client.cursor_surface_id = readUint(payload, 4);
            client.cursor_hotspot_x  = @bitCast(readUint(payload, 8));
            client.cursor_hotspot_y  = @bitCast(readUint(payload, 12));
            return;
        }
        // wl_seat.get_pointer (opcode 0)
        if (opcode == 0 and payload.len == 4 and
            (object_id == client.seat_id or
             (client.seat_id == 0 and object_id > 1 and
              object_id != client.compositor_id and object_id != client.shm_id))) {
            if (client.seat_id == 0) client.seat_id = object_id;
            client.pointer_id = readUint(payload, 0);
            std.log.info("get_pointer fd={} seat={} pid={}", .{client.fd, object_id, client.pointer_id});
            return;
        }
        // wl_seat.get_keyboard (opcode 1)
        if (opcode == 1 and payload.len == 4 and
            (object_id == client.seat_id or
             (client.seat_id == 0 and object_id > 1 and
              object_id != client.compositor_id and object_id != client.shm_id))) {
            if (client.seat_id == 0) client.seat_id = object_id;
            client.keyboard_id = readUint(payload, 0);
            std.log.info("get_keyboard fd={} seat={} kid={} payload_len={}", .{client.fd, object_id, client.keyboard_id, payload.len});
            std.log.info("keyboard_id set fd={} kid={}", .{client.fd, client.keyboard_id});
            seat_mod.sendKeymap(client.fd, client.keyboard_id);
            // enter se envía en wl_surface.commit cuando toplevel está listo
            return;
        }

        // xdg_wm_base.get_xdg_surface (opcode 2)
        if (object_id == client.xdg_id and opcode == 2 and payload.len >= 8) {
            const xdg_surface_id = readUint(payload, 0);
            const wl_surface_id  = readUint(payload, 4);
            std.log.info("xdg: get_xdg_surface id={} surface={}", .{xdg_surface_id, wl_surface_id});
            // Registrar la asociación
            if (client.xdg_surface_count < 8) {
                client.xdg_surface_ids[client.xdg_surface_count] = xdg_surface_id;
                client.xdg_surface_count += 1;
            }
            // Setear xdg_surface_id en la surface y guardar wl_surface_id en client
            if (self.surfaces.getSurface(wl_surface_id, client.fd)) |s| {
                s.xdg_surface_id = xdg_surface_id;
            }
            client.last_wl_surface_id = wl_surface_id;
            client.last_xdg_surface_id = xdg_surface_id;
        // NO enviar configure aquí — esperar get_toplevel
            return;
        }

        // xdg_wm_base.pong (opcode 3)
        if (object_id == client.xdg_id and opcode == 3) return;

        // xdg_surface.get_toplevel (opcode 1)
        var is_xdg_surface = false;
        for (client.xdg_surface_ids[0..client.xdg_surface_count]) |xid| {
            if (xid == object_id) { is_xdg_surface = true; break; }
        }
        if (is_xdg_surface and opcode == 1 and payload.len >= 4) {
            const toplevel_id = readUint(payload, 0);
            // surf_id: wl_surface_id guardado en get_xdg_surface
            const surf_id: u32 = client.last_wl_surface_id;
            _ = self.xdg.createToplevel(toplevel_id, object_id, surf_id, client.fd);
            if (self.surfaces.getSurface(surf_id, client.fd)) |s| {
                s.xdg_toplevel_id = toplevel_id;
            }
            // Contar clientes activos con toplevel para calcular dimensiones
            var n_tops: u32 = 0;
            for (self.surfaces.surfaces) |s2| {
                if (s2.xdg_toplevel_id > 0 and s2.mapped) n_tops += 1;
            }
            n_tops += 1; // incluir este nuevo
            const W: u32 = 1280; const H: u32 = 768;
            const bar: u32 = 33; const gap: u32 = 6;
            // Re-configure a todos los clientes existentes con nuevas dimensiones
            if (n_tops >= 2) {
            var ridx: u32 = 0;
                for (self.surfaces.surfaces) |s2| {
                    if (s2.xdg_toplevel_id == 0 or !s2.mapped or s2.client_fd == client.fd) continue;
                    const rw: u32 = if (ridx == 0) W/2 - gap - gap/2 else W/2 - gap - gap/2;
                    const stack_c: u32 = n_tops - 1;
                    const rh: u32 = if (ridx == 0) H - bar - gap*2
                                    else (H - bar - gap * (stack_c + 1)) / stack_c;
                    for (&self.clients) |*slot2| {
                        if (slot2.*) |*cl2| {
                            if (cl2.fd == s2.client_fd) {
                                xdg_mod.sendToplevelConfigure(cl2.fd, s2.xdg_toplevel_id, @as(i32, @intCast(rw)), @as(i32, @intCast(rh)));
                                self.serial += 1;
                            cl2.configure_serial += 1;
                            xdg_mod.sendXdgSurfaceConfigure(cl2.fd, cl2.last_xdg_surface_id, cl2.configure_serial);
                            }
                        }
                    }
                    ridx += 1;
                }
            }
            const is_master = (n_tops == 1);
            const cfg_w: u32 = if (is_master) W - gap*2 else W/2 - gap - gap/2;
            const cfg_h: u32 = H - bar - gap*2;
            // Enviar toplevel configure + xdg_surface configure
            std.log.info("get_toplevel: fd={} toplevel_id={} xdg_surf_id={} cfg_w={} cfg_h={}", .{client.fd, toplevel_id, client.last_xdg_surface_id, cfg_w, cfg_h});
            xdg_mod.sendToplevelConfigure(client.fd, toplevel_id, @as(i32, @intCast(cfg_w)), @as(i32, @intCast(cfg_h)));
            client.configure_serial += 1;
            xdg_mod.sendXdgSurfaceConfigure(client.fd, client.last_xdg_surface_id, client.configure_serial);
            // Leave al cliente anterior
            // if (self.focused_fd != -1 and self.focused_fd != client.fd) {
            // for (&self.clients) |*slot2| {
            // if (slot2.*) |*cl2| {
            // if (cl2.fd == self.focused_fd and cl2.keyboard_id > 0) {
            // for (self.surfaces.surfaces) |s2| {
            // if (s2.xdg_toplevel_id > 0 and s2.client_fd == cl2.fd and s2.id > 0) {
            // self.serial += 1;
            // seat_mod.sendKeyboardLeave(cl2.fd, cl2.keyboard_id, s2.id, self.serial);
            // break;
            // }
            // }
            // }
            // }
            // }
            // }
        }

        // xdg_surface.ack_configure (opcode 4)
        if (is_xdg_surface and opcode == 4) {
            std.log.info("xdg: ack_configure", .{});
            return;
        }

        // xdg_toplevel requests
        if (self.xdg.getToplevel(object_id)) |tl| {
            switch (opcode) {
                0 => { // destroy
                    self.xdg.destroyToplevel(object_id);
                },
                2 => { // set_title
                    if (payload.len >= 4) {
                        const slen = readUint(payload, 0);
                        const copy = @min(slen, 127);
                        if (payload.len >= 4 + copy) {
                            @memcpy(tl.title[0..copy], payload[4..4+copy]);
                            tl.title[copy] = 0;
                            std.log.info("xdg: title={s}", .{tl.getTitle()});
                        }
                    }
                },
                3 => { // set_app_id
                    if (payload.len >= 4) {
                        const slen = readUint(payload, 0);
                        const copy = @min(slen, 127);
                        if (payload.len >= 4 + copy) {
                            @memcpy(tl.app_id[0..copy], payload[4..4+copy]);
                            tl.app_id[copy] = 0;
                        }
                    }
                },
                else => {}, // ignorar set_min_size, set_max_size, etc
            }
            return;
        }

        // wl_buffer.destroy — ignorar silenciosamente
        if (self.surfaces.getBuffer(object_id) != null and opcode == 0) {
            return;
        }

        if (self.surfaces.getSurface(object_id, client.fd)) |surf| {
            switch (opcode) {
                0 => self.surfaces.destroySurface(object_id),
                1 => { // attach
                    if (payload.len >= 12) {
                        const buf_id = readUint(payload, 0);
                        // x,y en attach son deprecated — ignorar
                        surf.pending_buf = self.surfaces.getBuffer(buf_id);
                    }
                },
                3 => { // frame callback
                    if (payload.len >= 4) {
                        const cb_id = readUint(payload, 0);
                        client.frame_cb_id = cb_id;
                        std.log.info("frame_cb set: fd={} cb_id={}", .{client.fd, cb_id});
                    }
                    return;
                },
                6 => { // commit
                    client.needs_blit = true;
                // Leer buffer SHM al momento del commit (estado final)
                if (surf.pending_buf) |pb2| {
                    if (pb2.fd >= 0 and pb2.data.len > 0) {
                        _ = linux.pread(@intCast(pb2.fd), pb2.data.ptr, pb2.data.len, @intCast(pb2.offset));
                    }
                }
                    if (surf.pending_buf) |pb| {
                        // Liberar buffer anterior si existe
                        if (surf.buffer) |old_buf| {
                            if (old_buf != pb) {
                                if (old_buf.id == client.prev_buf_id) { } else {
                                std.log.info("wl_buffer release id={}", .{old_buf.id});
                                client.sendEvent(old_buf.id, 0, &[_]u8{});
                                client.prev_buf_id = old_buf.id;
                                }


                            }
                        }
                        // Release del buffer anterior (ahora libre)
                        if (surf.buffer) |ob| {
                    if (ob.id != pb.id) {
                        client.prev_buf_id = ob.id;
                    }
                }
                        surf.buffer = pb;
                        surf.width  = pb.width;
                        surf.height = pb.height;
                        surf.mapped = true;
                        surf.pending_buf = null;
                        std.log.info("surface {} commit {}x{}", .{object_id, pb.width, pb.height});
                        // Solo ventanas toplevel reciben foco
                if (client.keyboard_id > 0 and !client.keyboard_given and
                surf.xdg_toplevel_id > 0) {
                    client.keyboard_given = true;
                    if (self.focused_fd == -1) {
                        self.focused_fd = client.fd;
                        self.serial += 1;
                        if (client.last_wl_surface_id > 0) {
                            self.serial += 1;
                            seat_mod.sendKeyboardEnter(client.fd, client.keyboard_id, surf.id, self.serial);
                            client.has_keyboard_focus = true;
                        }
                        seat_mod.sendModifiers(client.fd, client.keyboard_id, self.serial, 0, 0, 0, 0);
                    }
                }
            }
                },
                else => {},
            }
            return;
        }
        // wl_buffer.destroy (op=0) — cualquier objeto conocido como buffer
        if (opcode == 0 and payload.len == 0) {
            // Puede ser wl_buffer.destroy o wl_surface.destroy — ignorar ambos
            return;
        }
        // Mensaje desconocido — ignorar
    }

    pub fn deinit(self: *Server) void {
        _ = linux.close(@intCast(self.socket_fd));
        _ = linux.unlink("/run/user/1000/wayland-0");
    }
};
