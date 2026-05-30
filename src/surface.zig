/// surface.zig — wl_surface, wl_shm, wl_buffer
///
/// Flujo de un cliente para mostrar contenido:
///   1. bind wl_shm
///   2. wl_shm.create_pool(fd, size)  → wl_shm_pool
///   3. wl_shm_pool.create_buffer(...)→ wl_buffer
///   4. wl_surface.attach(buffer)
///   5. wl_surface.commit()
///   → compositor hace blit del buffer al framebuffer

const std = @import("std");
const linux = std.os.linux;

pub const MAX_SURFACES = 16;
pub const MAX_BUFFERS  = 32;

// ─── Formato de píxel ─────────────────────────────────────────────────────────

pub const WL_SHM_FORMAT_ARGB8888: u32 = 0;
pub const WL_SHM_FORMAT_XRGB8888: u32 = 1;

// ─── Buffer compartido ────────────────────────────────────────────────────────

pub const Buffer = struct {
    id     : u32,
    fd     : i32,
    data   : []u8,    // mmap del fd del cliente
    width  : i32,
    height : i32,
    stride : i32,
    format : u32,
    busy   : bool = false,  // true = siendo mostrado

    pub fn destroy(self: *Buffer) void {
        if (self.data.len > 0) {
            std.posix.munmap(@alignCast(self.data));
        }
        if (self.fd >= 0) {
            _ = linux.close(@intCast(self.fd));
        }
        self.* = std.mem.zeroes(Buffer);
        self.fd = -1;
    }
};

// ─── Superficie ───────────────────────────────────────────────────────────────

pub const Surface = struct {
    id          : u32,
    client_fd   : i32,    // fd del cliente dueño
    buffer      : ?*Buffer = null,   // buffer actual (committed)
    pending_buf : ?*Buffer = null,   // buffer pendiente (attached, no committed)
    x           : i32 = 0,
    y           : i32 = 0,
    width       : i32 = 0,
    height      : i32 = 0,
    mapped      : bool = false,      // visible en pantalla

    // xdg_surface/xdg_toplevel IDs asociados
    xdg_surface_id  : u32 = 0,
    xdg_toplevel_id : u32 = 0,
    title           : [64]u8 = std.mem.zeroes([64]u8),

    pub fn getTitle(self: *Surface) []const u8 {
        return std.mem.sliceTo(&self.title, 0);
    }
};

// ─── Gestor de superficies ────────────────────────────────────────────────────

pub const SurfaceManager = struct {
    surfaces : [MAX_SURFACES]Surface = std.mem.zeroes([MAX_SURFACES]Surface),
    buffers  : [MAX_BUFFERS]Buffer   = std.mem.zeroes([MAX_BUFFERS]Buffer),
    count    : usize = 0,

    pub fn init() SurfaceManager {
        var sm = SurfaceManager{};
        for (&sm.buffers) |*b| b.fd = -1;
        return sm;
    }

    pub fn createSurface(self: *SurfaceManager, id: u32, client_fd: i32) ?*Surface {
        for (&self.surfaces) |*s| {
            if (s.id == 0) {
                s.* = std.mem.zeroes(Surface);
                s.id = id;
                s.client_fd = client_fd;
                self.count += 1;
                std.log.info("surface: creada id={}", .{id});
                return s;
            }
        }
        return null;
    }

    pub fn getSurface(self: *SurfaceManager, id: u32) ?*Surface {
        for (&self.surfaces) |*s| {
            if (s.id == id) return s;
        }
        return null;
    }

    pub fn destroySurface(self: *SurfaceManager, id: u32) void {
        for (&self.surfaces) |*s| {
            if (s.id == id) {
                s.* = std.mem.zeroes(Surface);
                if (self.count > 0) self.count -= 1;
                std.log.info("surface: destruida id={}", .{id});
                return;
            }
        }
    }

    pub fn createBuffer(
        self   : *SurfaceManager,
        id     : u32,
        fd     : i32,
        width  : i32,
        height : i32,
        stride : i32,
        format : u32,
        offset  : i32,
    ) ?*Buffer {
        for (&self.buffers) |*b| {
            if (b.fd == -1) {
                const size: usize = @intCast(stride * height);
                // mmap del fd del cliente para leer sus píxeles
                const ptr = std.posix.mmap(
                    null, size,
                    std.posix.PROT{ .READ = true },
                    .{ .TYPE = .SHARED },
                    fd, @intCast(offset),
                ) catch {
                    std.log.err("surface: mmap buffer falló", .{});
                    _ = linux.close(@intCast(fd));
                    return null;
                };
                b.* = Buffer{
                    .id     = id,
                    .fd     = fd,
                    .data   = ptr,
                    .width  = width,
                    .height = height,
                    .stride = stride,
                    .format = format,
                };
                std.log.info("surface: buffer id={} {}x{} stride={}", .{id, width, height, stride});
                return b;
            }
        }
        return null;
    }

    pub fn getBuffer(self: *SurfaceManager, id: u32) ?*Buffer {
        for (&self.buffers) |*b| {
            if (b.fd >= 0 and b.id == id) return b;
        }
        return null;
    }

    /// Blit de una superficie al framebuffer del compositor
    /// src_pixels: píxeles del cliente (ARGB8888)
    /// dst: framebuffer del compositor
    pub fn blitSurface(
        surface  : *Surface,
        dst      : []u32,
        dst_w    : u32,
        dst_h    : u32,
        dst_pitch: u32,
    ) void {
        const buf = surface.buffer orelse return;
        if (buf.data.len == 0) return;

        const src_pixels = @as([*]const u32, @ptrCast(@alignCast(buf.data.ptr)));
        const src_stride = @as(u32, @intCast(buf.stride)) / 4;

        const x0: u32 = @intCast(@max(0, surface.x));
        const y0: u32 = @intCast(@max(0, surface.y));
        const x1: u32 = @min(x0 + @as(u32, @intCast(buf.width)),  dst_w);
        const y1: u32 = @min(y0 + @as(u32, @intCast(buf.height)), dst_h);

        var dy: u32 = y0;
        while (dy < y1) : (dy += 1) {
            const sy = dy - y0;
            var dx: u32 = x0;
            while (dx < x1) : (dx += 1) {
                const sx = dx - x0;
                const pixel = src_pixels[sy * src_stride + sx];
                // Copiar píxel directo (XRGB8888 no usa alpha)
                dst[dy * (dst_pitch / 4) + dx] = pixel | 0xFF000000;
            }
        }
    }
};
