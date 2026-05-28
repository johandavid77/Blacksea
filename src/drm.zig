/// drm.zig — Acceso directo a DRM/KMS sin libdrm
///
/// DRM (Direct Rendering Manager) es el subsistema del kernel que controla
/// el hardware de display. KMS (Kernel Mode Setting) es la parte que nos
/// permite configurar resolución, refresh rate, y mandar frames a pantalla.
///
/// El flujo básico para mostrar algo en pantalla:
///   1. Abrir /dev/dri/card0
///   2. Leer los recursos disponibles (connectors, CRTCs, encoders)
///   3. Encontrar un connector conectado (el monitor)
///   4. Elegir un modo de video (resolución + refresh)
///   5. Crear un "dumb buffer" — un framebuffer en RAM manejado por el kernel
///   6. Hacer mmap del buffer para escribir píxeles directamente
///   7. Llamar DRM_IOCTL_MODE_SETCRTC para que el CRTC apunte a nuestro buffer
///   8. En el loop: escribir frame → DRM_IOCTL_MODE_PAGE_FLIP → esperar vblank
///
/// Sin libdrm: todos los ioctls y structs están definidos acá mismo.

const std = @import("std");
const os = std.os;
const linux = std.os.linux;

// ─── Constantes DRM ──────────────────────────────────────────────────────────

// Magic number base para todos los ioctls de DRM
// Viene de <drm/drm.h>: #define DRM_IOCTL_BASE 'd'
const DRM_IOCTL_BASE: u8 = 'd';

// Helpers para construir números de ioctl (igual que la macro _IOWR del kernel)
fn IOC(dir: u32, typ: u32, nr: u32, size: u32) u32 {
    return (dir << 30) | (size << 16) | (typ << 8) | nr;
}
fn IOWR(nr: u32, comptime T: type) u32 {
    return IOC(3, DRM_IOCTL_BASE, nr, @sizeOf(T));
}
fn IOW(nr: u32, comptime T: type) u32 {
    return IOC(1, DRM_IOCTL_BASE, nr, @sizeOf(T));
}
fn IOR(nr: u32, comptime T: type) u32 {
    return IOC(2, DRM_IOCTL_BASE, nr, @sizeOf(T));
}

// Números de ioctl que usamos (de <drm/drm.h> y <drm/drm_mode.h>)
pub const DRM_IOCTL_GET_RESOURCES    = IOWR(0xA0, DrmModeResources);
pub const DRM_IOCTL_GET_CONNECTOR    = IOWR(0xA7, DrmModeGetConnector);
pub const DRM_IOCTL_GET_ENCODER      = IOWR(0xA6, DrmModeGetEncoder);
pub const DRM_IOCTL_GET_CRTC        = IOWR(0xA1, DrmModeCrtc);
pub const DRM_IOCTL_SET_CRTC        = IOWR(0xA2, DrmModeCrtc);
pub const DRM_IOCTL_CREATE_DUMB      = IOWR(0xB2, DrmModeCreateDumb);
pub const DRM_IOCTL_MAP_DUMB         = IOWR(0xB3, DrmModeMapDumb);
pub const DRM_IOCTL_DESTROY_DUMB     = IOWR(0xB4, DrmModeDestroyDumb);
pub const DRM_IOCTL_ADD_FB           = IOWR(0xAE, DrmModeFbCmd);
pub const DRM_IOCTL_RM_FB            = IOW(0xAF,  u32);
pub const DRM_IOCTL_PAGE_FLIP        = IOWR(0xB0, DrmModePageFlip);
pub const DRM_IOCTL_WAIT_VBLANK      = IOWR(0x3F, DrmWaitVblank);
pub const DRM_IOCTL_SET_MASTER       = IOC(0, DRM_IOCTL_BASE, 0x1E, 0);
pub const DRM_IOCTL_DROP_MASTER      = IOC(0, DRM_IOCTL_BASE, 0x1F, 0);

// Flags de page flip
pub const DRM_MODE_PAGE_FLIP_EVENT: u32 = 0x01;
pub const DRM_MODE_PAGE_FLIP_ASYNC: u32 = 0x02;

// Estados de conexión del connector
pub const DRM_MODE_CONNECTED: u32         = 1;
pub const DRM_MODE_DISCONNECTED: u32      = 2;
pub const DRM_MODE_UNKNOWNCONNECTION: u32 = 3;

// Tipos de connector
pub const DRM_MODE_CONNECTOR_HDMIA: u32 = 11;
pub const DRM_MODE_CONNECTOR_DP: u32    = 10;
pub const DRM_MODE_CONNECTOR_eDP: u32   = 14;
pub const DRM_MODE_CONNECTOR_LVDS: u32  = 7;

// ─── Structs del kernel (deben matchear EXACTAMENTE con <drm/drm_mode.h>) ────

pub const DrmModeInfo = extern struct {
    clock: u32,
    hdisplay: u16,
    hsync_start: u16,
    hsync_end: u16,
    htotal: u16,
    hskew: u16,
    vdisplay: u16,
    vsync_start: u16,
    vsync_end: u16,
    vtotal: u16,
    vscan: u16,
    vrefresh: u32,
    flags: u32,
    type: u32,
    name: [32]u8,
};

pub const DrmModeResources = extern struct {
    fb_id_ptr: u64 = 0,
    crtc_id_ptr: u64 = 0,
    connector_id_ptr: u64 = 0,
    encoder_id_ptr: u64 = 0,
    count_fbs: u32 = 0,
    count_crtcs: u32 = 0,
    count_connectors: u32 = 0,
    count_encoders: u32 = 0,
    min_width: u32 = 0,
    max_width: u32 = 0,
    min_height: u32 = 0,
    max_height: u32 = 0,
};

pub const DrmModeGetConnector = extern struct {
    encoders_ptr: u64 = 0,
    modes_ptr: u64 = 0,
    props_ptr: u64 = 0,
    prop_values_ptr: u64 = 0,
    count_modes: u32 = 0,
    count_props: u32 = 0,
    count_encoders: u32 = 0,
    encoder_id: u32 = 0,
    connector_id: u32 = 0,
    connector_type: u32 = 0,
    connector_type_id: u32 = 0,
    connection: u32 = 0,
    mm_width: u32 = 0,
    mm_height: u32 = 0,
    subpixel: u32 = 0,
    pad: u32 = 0,
};

pub const DrmModeGetEncoder = extern struct {
    encoder_id: u32 = 0,
    encoder_type: u32 = 0,
    crtc_id: u32 = 0,
    possible_crtcs: u32 = 0,
    possible_clones: u32 = 0,
};

pub const DrmModeCrtc = extern struct {
    set_connectors_ptr: u64 = 0,
    count_connectors: u32 = 0,
    crtc_id: u32 = 0,
    fb_id: u32 = 0,
    x: u32 = 0,
    y: u32 = 0,
    gamma_size: u32 = 0,
    mode_valid: u32 = 0,
    mode: DrmModeInfo = std.mem.zeroes(DrmModeInfo),
};

pub const DrmModeCreateDumb = extern struct {
    height: u32,
    width: u32,
    bpp: u32,
    flags: u32 = 0,
    handle: u32 = 0,   // out: handle del buffer
    pitch: u32 = 0,    // out: bytes por fila
    size: u64 = 0,     // out: tamaño total en bytes
};

pub const DrmModeMapDumb = extern struct {
    handle: u32,
    pad: u32 = 0,
    offset: u64 = 0,   // out: offset para mmap
};

pub const DrmModeDestroyDumb = extern struct {
    handle: u32,
};

pub const DrmModeFbCmd = extern struct {
    fb_id: u32 = 0,    // out
    width: u32,
    height: u32,
    pitch: u32,
    bpp: u32,
    depth: u32,
    handle: u32,
};

pub const DrmModePageFlip = extern struct {
    crtc_id: u32,
    fb_id: u32,
    flags: u32,
    reserved: u32 = 0,
    user_data: u64 = 0,
};

pub const DrmWaitVblank = extern struct {
    type: u32,
    sequence: u32,
    tval_sec: i64,
    tval_usec: i64,
};

// ─── Framebuffer (dumb buffer) ────────────────────────────────────────────────

pub const Framebuffer = struct {
    width: u32,
    height: u32,
    pitch: u32,       // bytes por fila (puede ser > width*4 por alignment)
    size: u64,
    handle: u32,      // handle DRM del buffer
    fb_id: u32,       // ID del framebuffer registrado en DRM
    data: []u32,      // píxeles mapeados en memoria (ARGB8888)
    mmap_ptr: [*]u8,  // puntero crudo del mmap para munmap

    /// Crear un dumb buffer y hacer mmap para acceso directo a píxeles
    pub fn create(fd: std.os.linux.fd_t, width: u32, height: u32) !Framebuffer {
        // 1. Crear el dumb buffer en el kernel
        var dumb_create = DrmModeCreateDumb{
            .width = width,
            .height = height,
            .bpp = 32,  // ARGB8888 — 4 bytes por píxel
        };
        try ioctl(fd, DRM_IOCTL_CREATE_DUMB, &dumb_create);

        // 2. Registrarlo como framebuffer DRM (le asigna un fb_id)
        var fb = DrmModeFbCmd{
            .width = width,
            .height = height,
            .pitch = dumb_create.pitch,
            .bpp = 32,
            .depth = 24,
            .handle = dumb_create.handle,
        };
        try ioctl(fd, DRM_IOCTL_ADD_FB, &fb);

        // 3. Obtener el offset para mmap
        var map = DrmModeMapDumb{ .handle = dumb_create.handle };
        try ioctl(fd, DRM_IOCTL_MAP_DUMB, &map);

        // 4. Mapear en nuestro espacio de memoria
        const ptr = try std.posix.mmap(
            null,
            @intCast(dumb_create.size),
            std.posix.PROT{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            @intCast(map.offset),
        );

        const pixel_count = dumb_create.size / 4;
        const pixels = @as([*]u32, @ptrCast(@alignCast(ptr.ptr)))[0..pixel_count];

        return Framebuffer{
            .width = width,
            .height = height,
            .pitch = dumb_create.pitch,
            .size = dumb_create.size,
            .handle = dumb_create.handle,
            .fb_id = fb.fb_id,
            .data = pixels,
            .mmap_ptr = ptr.ptr,
        };
    }

    /// Pintar un píxel. Usamos pitch/4 para el stride real (no width).
    pub inline fn setPixel(self: *Framebuffer, x: u32, y: u32, color: u32) void {
        if (x >= self.width or y >= self.height) return;
        self.data[y * (self.pitch / 4) + x] = color;
    }

    /// Llenar un rectángulo con un color sólido
    pub fn fillRect(self: *Framebuffer, x: u32, y: u32, w: u32, h: u32, color: u32) void {
        const x1 = @min(x + w, self.width);
        const y1 = @min(y + h, self.height);
        var py = y;
        while (py < y1) : (py += 1) {
            var px = x;
            while (px < x1) : (px += 1) {
                self.data[py * (self.pitch / 4) + px] = color;
            }
        }
    }

    /// Limpiar el framebuffer a un color
    pub fn clear(self: *Framebuffer, color: u32) void {
        @memset(self.data, color);
    }

    pub fn destroy(self: *Framebuffer, fd: std.os.linux.fd_t) void {
        std.posix.munmap(@alignCast(self.mmap_ptr[0..self.size]));
        var rm: u32 = self.fb_id;
        ioctl(fd, DRM_IOCTL_RM_FB, &rm) catch {};
        var dumb_destroy = DrmModeDestroyDumb{ .handle = self.handle };
        ioctl(fd, DRM_IOCTL_DESTROY_DUMB, &dumb_destroy) catch {};
    }
};

// ─── Dispositivo DRM ─────────────────────────────────────────────────────────

pub const Output = struct {
    connector_id: u32,
    crtc_id: u32,
    mode: DrmModeInfo,
    width: u32,
    height: u32,

    /// Framebuffers (doble buffering para evitar tearing)
    front: Framebuffer,
    back: Framebuffer,
    front_is_displayed: bool = true,

    /// Apuntar el CRTC a nuestro framebuffer inicial
    pub fn setCrtc(self: *Output, fd: std.os.linux.fd_t) !void {
        var connector_id = self.connector_id;
        var crtc = DrmModeCrtc{
            .crtc_id = self.crtc_id,
            .fb_id = self.front.fb_id,
            .x = 0,
            .y = 0,
            .mode_valid = 1,
            .mode = self.mode,
            .set_connectors_ptr = @intFromPtr(&connector_id),
            .count_connectors = 1,
        };
        try ioctl(fd, DRM_IOCTL_SET_CRTC, &crtc);
    }

    /// Intercambiar buffers (page flip) — muestra el back buffer
    pub fn pageFlip(self: *Output, fd: std.os.linux.fd_t) !void {
        const next_fb = if (self.front_is_displayed) self.back.fb_id else self.front.fb_id;
        var flip = DrmModePageFlip{
            .crtc_id = self.crtc_id,
            .fb_id = next_fb,
            .flags = DRM_MODE_PAGE_FLIP_EVENT,
        };
        try ioctl(fd, DRM_IOCTL_PAGE_FLIP, &flip);
        self.front_is_displayed = !self.front_is_displayed;
    }

    /// El buffer en el que podemos dibujar (el que NO está en pantalla)
    pub fn drawBuffer(self: *Output) *Framebuffer {
        return if (self.front_is_displayed) &self.back else &self.front;
    }

    pub fn destroy(self: *Output, fd: std.os.linux.fd_t) void {
        self.front.destroy(fd);
        self.back.destroy(fd);
    }
};

pub const Device = struct {
    fd: std.os.linux.fd_t,
    output: ?Output = null,
    allocator: std.mem.Allocator,

    /// Buscar automáticamente el primer card disponible en /dev/dri/
    pub fn autoDetect(allocator: std.mem.Allocator) !Device {
        var path_buf: [32]u8 = undefined;
        var i: u8 = 0;
        while (i < 10) : (i += 1) {
            const path = try std.fmt.bufPrint(&path_buf, "/dev/dri/card{d}", .{i});
            const dev = Device.open(allocator, path) catch continue;
            std.log.info("drm: usando {s}", .{path});
            return dev;
        }
        return error.NoDrmDevice;
    }

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Device {
        const fd = try std.posix.openatZ(std.posix.AT.FDCWD, @ptrCast(path.ptr), .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
        errdefer std.os.linux.close(fd);

        // Intentar tomar el master del DRM (necesario para hacer KMS)
        // Falla si ya hay otro compositor corriendo — eso es correcto
        ioctl(fd, DRM_IOCTL_SET_MASTER, @as(*anyopaque, undefined)) catch |err| {
            std.log.warn("drm: no se pudo tomar DRM master: {} (¿hay otro compositor?)", .{err});
        };

        return Device{ .fd = fd, .allocator = allocator };
    }

    /// Detectar el primer connector conectado y configurarlo
    pub fn detectOutput(self: *Device) !void {
        // Paso 1: leer cuántos recursos hay
        var res = DrmModeResources{};
        try ioctl(self.fd, DRM_IOCTL_GET_RESOURCES, &res);

        // Paso 2: alocar arrays para los IDs
        const crtc_ids = try self.allocator.alloc(u32, res.count_crtcs);
        defer self.allocator.free(crtc_ids);
        const connector_ids = try self.allocator.alloc(u32, res.count_connectors);
        defer self.allocator.free(connector_ids);
        const encoder_ids = try self.allocator.alloc(u32, res.count_encoders);
        defer self.allocator.free(encoder_ids);

        res.crtc_id_ptr = @intFromPtr(crtc_ids.ptr);
        res.connector_id_ptr = @intFromPtr(connector_ids.ptr);
        res.encoder_id_ptr = @intFromPtr(encoder_ids.ptr);
        try ioctl(self.fd, DRM_IOCTL_GET_RESOURCES, &res);

        // Paso 3: buscar un connector conectado
        for (connector_ids[0..res.count_connectors]) |conn_id| {
            var conn = DrmModeGetConnector{ .connector_id = conn_id };

            // Primera llamada: saber cuántos modos hay
            try ioctl(self.fd, DRM_IOCTL_GET_CONNECTOR, &conn);
            if (conn.connection != DRM_MODE_CONNECTED) continue;
            if (conn.count_modes == 0) continue;

            // Segunda llamada: leer los modos
            const modes = try self.allocator.alloc(DrmModeInfo, conn.count_modes);
            defer self.allocator.free(modes);
            const enc_ids = try self.allocator.alloc(u32, conn.count_encoders);
            defer self.allocator.free(enc_ids);

            conn.modes_ptr = @intFromPtr(modes.ptr);
            conn.encoders_ptr = @intFromPtr(enc_ids.ptr);
            try ioctl(self.fd, DRM_IOCTL_GET_CONNECTOR, &conn);

            // El modo preferido (índice 0) es el nativo del monitor
            const mode = modes[0];
            const width = mode.hdisplay;
            const height = mode.vdisplay;

            std.log.info("drm: monitor detectado — {}x{}@{}Hz connector_id={}", .{
                width, height, mode.vrefresh, conn_id,
            });

            // Encontrar el CRTC via el encoder
            var encoder = DrmModeGetEncoder{ .encoder_id = conn.encoder_id };
            try ioctl(self.fd, DRM_IOCTL_GET_ENCODER, &encoder);
            const crtc_id = encoder.crtc_id;

            // Crear los dos framebuffers (doble buffering)
            const front = try Framebuffer.create(self.fd, width, height);
            const back  = try Framebuffer.create(self.fd, width, height);

            self.output = Output{
                .connector_id = conn_id,
                .crtc_id = crtc_id,
                .mode = mode,
                .width = width,
                .height = height,
                .front = front,
                .back = back,
            };

            // Activar el display
            try self.output.?.setCrtc(self.fd);
            return;
        }

        return error.NoConnectedOutput;
    }

    pub fn close(self: *Device) void {
        if (self.output) |*out| out.destroy(self.fd);
        ioctl(self.fd, DRM_IOCTL_DROP_MASTER, @as(*anyopaque, undefined)) catch {};
        _ = std.os.linux.close(self.fd);
    }
};

// ─── Helper ioctl ─────────────────────────────────────────────────────────────

pub fn ioctl(fd: std.os.linux.fd_t, request: u32, arg: anytype) !void {
    const T = @TypeOf(arg);
    const ptr: usize = switch (@typeInfo(T)) {
        .pointer => @intFromPtr(arg),
        .int     => @intCast(arg),
        else     => @intFromPtr(arg),
    };
    const rc = linux.ioctl(fd, request, ptr);
    if (rc == 0) return;
    const err = std.posix.errno(rc);
    return switch (err) {
        .SUCCESS => {},
        .PERM    => error.PermissionDenied,
        .NODEV   => error.NoDevice,
        .INVAL   => error.InvalidArgument,
        .NOMEM   => error.OutOfMemory,
        else     => blk: {
            std.log.err("drm: ioctl 0x{X} falló: {}", .{request, err});
            break :blk error.IoctlFailed;
        },
    };
}
