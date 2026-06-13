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

pub const MAX_SURFACES = 64;
pub const MAX_BUFFERS  = 32;

// ─── Formato de píxel ─────────────────────────────────────────────────────────

pub const WL_SHM_FORMAT_ARGB8888: u32 = 0;
pub const WL_SHM_FORMAT_XRGB8888: u32 = 1;

// ─── Buffer compartido ────────────────────────────────────────────────────────

pub const Buffer = struct {
    id     : u32,
    fd     : i32,
    data   : []u8,
    width  : i32,
    height : i32,
    stride : i32,
    format : u32,
    offset : usize = 0,
    busy   : bool = false,
};

pub fn bufferDestroy(self: *Buffer) void {
    if (self.data.len > 0) std.heap.page_allocator.free(self.data);
    // NO cerrar fd — pertenece al shm pool del cliente
    self.* = std.mem.zeroes(Buffer);
    self.fd = -1;
}


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
    keyboard_entered : bool = false,
    last_tiled_w  : i32 = 0,
    last_tiled_h  : i32 = 0,

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
        // Verificar si ya existe para este cliente
        for (&self.surfaces) |*s| {
            if (s.id == id and s.client_fd == client_fd) return s;
        }
        // Buscar slot vacío
        for (&self.surfaces) |*s| {
            if (s.id == 0) {
                s.* = std.mem.zeroes(Surface);
                s.id = id;
                s.client_fd = client_fd;
                self.count += 1;
                std.log.info("surface: creada id={} fd={}", .{id, client_fd});
                return s;
            }
        }
        return null;
    }

    pub fn getSurface(self: *SurfaceManager, id: u32, client_fd: i32) ?*Surface {
        for (&self.surfaces) |*s| {
            if (s.id == id and s.client_fd == client_fd) return s;
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
        self    : *SurfaceManager,
        id      : u32,
        fd      : i32,
        width   : i32,
        height  : i32,
        stride  : i32,
        format  : u32,
        offset  : i32,
    ) ?*Buffer {
        for (&self.buffers) |*b| {
            if (b.id == id and b.fd == -1) { // slot para reusar
                // Reusar slot — desmapear el mmap anterior
                if (b.data.len > 0) std.heap.page_allocator.free(b.data);
                b.fd = -1;
            }
        }
        for (&self.buffers) |*b| {
            if (b.fd == -1 and b.id == 0) { // slot vacío
                const size: usize = @intCast(stride * height);
                const off: usize = @intCast(offset);
            _ = off + size; // map_total no usado
            // Guardar fd y offset — leeremos en blitSurface cuando foot haya pintado
            const buf_mem = std.heap.page_allocator.alloc(u8, size) catch return null;
            @memset(buf_mem, 0);
            const ptr = buf_mem;
                b.* = Buffer{
                    .id     = id,
                    .fd     = fd,
                .offset = off,
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
            if (b.id == id and b.id > 0) return b; // fd puede ser -1 con pread
        }
        return null;
    }

    /// Blit de una superficie al framebuffer del compositor
    /// src_pixels: píxeles del cliente (ARGB8888)
    /// dst: framebuffer del compositor
    pub fn blitSurface(
        self     : *SurfaceManager,
        surf     : *Surface,
        dst      : []u32,
        dst_w    : u32,
        dst_h    : u32,
        dst_pitch: u32,
    ) void {
        _ = self;
        const buf = surf.buffer orelse return;
        // Validar posición
        if (surf.x >= @as(i32, @intCast(dst_w)) or surf.y >= @as(i32, @intCast(dst_h))) return;
        if (buf.data.len == 0) return;
        if (buf.width <= 0 or buf.height <= 0 or buf.stride <= 0) return;
        // Leer datos frescos via pread
        if (buf.fd >= 0 and buf.data.len > 0) {
            const nr = linux.pread(@intCast(buf.fd), buf.data.ptr, buf.data.len, @intCast(buf.offset));
            const nri = @as(isize, @bitCast(nr));
        if (surf.id == 3) std.log.info("pread surf3 fd={} off={} len={} nr={} b0={x}", .{buf.fd, buf.offset, buf.data.len, nri, buf.data[0]});
        }
        // Verificar que el fd del buffer sigue abierto
        if (buf.fd < 0) return;
        const sw: u32 = @intCast(buf.width);
        const sh: u32 = @intCast(buf.height);
        const src_stride: u32 = @intCast(@divTrunc(buf.stride, 4));
        const npixels: usize = buf.data.len / 4;
        if (npixels == 0) return;
        const src = @as([*]const u32, @ptrCast(@alignCast(buf.data.ptr)))[0..npixels];

        const x0: u32 = if (surf.x >= 0) @intCast(surf.x) else 0;
        const y0: u32 = if (surf.y >= 0) @intCast(surf.y) else 0;
        // Filas/cols del source a saltar cuando la superficie tiene offset negativo
        const src_skip_y: u32 = if (surf.y < 0) @intCast(-surf.y) else 0;
        const src_skip_x: u32 = if (surf.x < 0) @intCast(-surf.x) else 0;
        if (surf.id == 3) std.log.info("blit surf3 x={} y={} sw={} sh={} x0={} y0={}", .{surf.x, surf.y, sw, sh, x0, y0});
        const x1: u32 = @min(x0 + sw, dst_w);
        const y1: u32 = @min(y0 + sh, dst_h);
        const dp: u32 = dst_pitch / 4;

        var dy: u32 = y0;
        while (dy < y1) : (dy += 1) {
            const sy: u32 = dy - y0 + src_skip_y;
            var dx: u32 = x0;
            while (dx < x1) : (dx += 1) {
            const sx: u32 = dx - x0 + src_skip_x;
                const si: usize = sy * src_stride + sx;
                const di: usize = dy * dp + dx;
                if (si >= src.len or di >= dst.len) continue;
                dst[di] = src[si] | 0xFF000000;
            }
    }
    }
};
