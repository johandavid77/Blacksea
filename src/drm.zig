// drm.zig — Backend DRM/KMS para virtio-gpu (Proxmox/QEMU/SPICE)
const std = @import("std");
const linux = std.os.linux;

// ─── DRM ioctls ───────────────────────────────────────────────────────────────
const DRM_IOCTL_BASE: u8 = 0x64;
// Números de ioctl DRM hardcodeados (verificados en runtime)
const DRM_IOCTL_MODE_GETRESOURCES  : u32 = 0xc03064a0;
const DRM_IOCTL_MODE_GETCONNECTOR  : u32 = 0xc04064a7;
const DRM_IOCTL_MODE_GETENCODER    : u32 = 0xc01464a6;
const DRM_IOCTL_MODE_CREATE_DUMB   : u32 = 0xc02064b2;
const DRM_IOCTL_MODE_ADDFB         : u32 = 0xc01c64ae;
const DRM_IOCTL_MODE_MAP_DUMB      : u32 = 0xc01064b3;
const DRM_IOCTL_MODE_SETCRTC       : u32 = 0xc06864a2;
const DRM_IOCTL_MODE_PAGE_FLIP     : u32 = 0xc01864b0;
const DRM_IOCTL_MODE_DIRTYFB       : u32 = 0xc01864b1;

// ─── Structs DRM ──────────────────────────────────────────────────────────────
const DrmModeResources = extern struct {
    fb_id_ptr:        u64 = 0,
    crtc_id_ptr:      u64 = 0,
    connector_id_ptr: u64 = 0,
    encoder_id_ptr:   u64 = 0,
    count_fbs:        u32 = 0,
    count_crtcs:      u32 = 0,
    count_connectors: u32 = 0,
    count_encoders:   u32 = 0,
};

const DrmModeGetConnector = extern struct {
    encoders_ptr:   u64 = 0,
    modes_ptr:      u64 = 0,
    props_ptr:      u64 = 0,
    prop_values_ptr:u64 = 0,
    count_modes:    u32 = 0,
    count_props:    u32 = 0,
    count_encoders: u32 = 0,
    encoder_id:     u32 = 0,
    connector_id:   u32 = 0,
    connector_type: u32 = 0,
    connector_type_id: u32 = 0,
    connection:     u32 = 0,
    mm_width:       u32 = 0,
    mm_height:      u32 = 0,
    subpixel:       u32 = 0,
    pad:            u32 = 0,
};

const DrmModeModeInfo = extern struct {
    clock:       u32 = 0,
    hdisplay:    u16 = 0, hsync_start: u16 = 0, hsync_end: u16 = 0, htotal: u16 = 0, hskew: u16 = 0,
    vdisplay:    u16 = 0, vsync_start: u16 = 0, vsync_end: u16 = 0, vtotal: u16 = 0, vscan: u16 = 0,
    vrefresh:    u32 = 0,
    flags:       u32 = 0,
    type:        u32 = 0,
    name:        [32:0]u8 = std.mem.zeroes([32:0]u8),
};

const DrmModeGetEncoder = extern struct {
    encoder_id:   u32 = 0,
    encoder_type: u32 = 0,
    crtc_id:      u32 = 0,
    possible_crtcs: u32 = 0,
    possible_clones: u32 = 0,
};

const DrmModeCreateDumb = extern struct {
    height: u32 = 0,
    width:  u32 = 0,
    bpp:    u32 = 0,
    flags:  u32 = 0,
    handle: u32 = 0,
    pitch:  u32 = 0,
    size:   u64 = 0,
};

const DrmModeFbCmd = extern struct {
    fb_id:  u32 = 0,
    width:  u32 = 0,
    height: u32 = 0,
    pitch:  u32 = 0,
    bpp:    u32 = 0,
    depth:  u32 = 0,
    handle: u32 = 0,
};

const DrmModeMapDumb = extern struct {
    handle: u32 = 0,
    pad:    u32 = 0,
    offset: u64 = 0,
};

const DrmModeCrtc = extern struct {
    set_connectors_ptr: u64 = 0,
    count_connectors:   u32 = 0,
    crtc_id:   u32 = 0,
    fb_id:     u32 = 0,
    x:         u32 = 0,
    y:         u32 = 0,
    gamma_size: u32 = 0,
    mode_valid: u32 = 0,
    mode:      DrmModeModeInfo = .{},
};

const DrmModePageFlip = extern struct {
    crtc_id:  u32 = 0,
    fb_id:    u32 = 0,
    flags:    u32 = 0,
    reserved: u32 = 0,
    user_data: u64 = 0,
};

const DrmModeDirtyFb = extern struct {
    fb_id:      u32 = 0,
    flags:      u32 = 0,
    color:      u32 = 0,
    num_clips:  u32 = 0,
    clips_ptr:  u64 = 0,
};

fn drm_ioctl(fd: i32, request: u32, arg: anytype) !void {
    const rc = linux.syscall3(.ioctl, @as(usize, @bitCast(@as(isize, fd))), request, @intFromPtr(arg));
    if (@as(isize, @bitCast(rc)) < 0) {
        std.log.err("ioctl 0x{x} failed rc={}", .{request, @as(isize,@bitCast(rc))});
        return error.IoctlFailed;
    }
}

// ─── Structs públicos (misma interfaz que antes) ───────────────────────────────
pub const Framebuffer = struct {
    width:  u32,
    height: u32,
    pitch:  u32,
    size:   usize,
    data:   []u32,
    ptr:    [*]u8,

    pub fn clear(self: *Framebuffer, color: u32) void {
        @memset(self.data, color);
    }

    pub fn fillRect(self: *Framebuffer, x: u32, y: u32, w: u32, h: u32, color: u32) void {
        const dp = self.pitch / 4;
        var row: u32 = y;
        while (row < y + h and row < self.height) : (row += 1) {
            var col: u32 = x;
            while (col < x + w and col < self.width) : (col += 1) {
                const idx = row * dp + col;
                if (idx < self.data.len) self.data[idx] = color;
            }
        }
    }

    // Font bitmap 5x7 — ASCII 32-126
    const FONT_W: u32 = 5;
    const FONT_H: u32 = 7;
    const font_data = [95][7]u8{
        [7]u8{ 0x00,0x00,0x00,0x00,0x00,0x00,0x00 }, // space
        [7]u8{ 0x04,0x04,0x04,0x04,0x00,0x04,0x00 }, // !
        [7]u8{ 0x0A,0x0A,0x00,0x00,0x00,0x00,0x00 }, // "
        [7]u8{ 0x0A,0x1F,0x0A,0x0A,0x1F,0x0A,0x00 }, // #
        [7]u8{ 0x04,0x0F,0x14,0x0E,0x05,0x1E,0x04 }, // $
        [7]u8{ 0x18,0x19,0x02,0x04,0x08,0x13,0x03 }, // %
        [7]u8{ 0x08,0x14,0x14,0x08,0x15,0x12,0x0D }, // &
        [7]u8{ 0x04,0x04,0x00,0x00,0x00,0x00,0x00 }, // '
        [7]u8{ 0x02,0x04,0x08,0x08,0x08,0x04,0x02 }, // (
        [7]u8{ 0x08,0x04,0x02,0x02,0x02,0x04,0x08 }, // )
        [7]u8{ 0x00,0x04,0x15,0x0E,0x15,0x04,0x00 }, // *
        [7]u8{ 0x00,0x04,0x04,0x1F,0x04,0x04,0x00 }, // +
        [7]u8{ 0x00,0x00,0x00,0x00,0x00,0x04,0x08 }, // ,
        [7]u8{ 0x00,0x00,0x00,0x1F,0x00,0x00,0x00 }, // -
        [7]u8{ 0x00,0x00,0x00,0x00,0x00,0x04,0x00 }, // .
        [7]u8{ 0x00,0x01,0x02,0x04,0x08,0x10,0x00 }, // /
        [7]u8{ 0x0E,0x11,0x13,0x15,0x19,0x11,0x0E }, // 0
        [7]u8{ 0x04,0x0C,0x04,0x04,0x04,0x04,0x0E }, // 1
        [7]u8{ 0x0E,0x11,0x01,0x06,0x08,0x10,0x1F }, // 2
        [7]u8{ 0x1F,0x02,0x04,0x02,0x01,0x11,0x0E }, // 3
        [7]u8{ 0x02,0x06,0x0A,0x12,0x1F,0x02,0x02 }, // 4
        [7]u8{ 0x1F,0x10,0x1E,0x01,0x01,0x11,0x0E }, // 5
        [7]u8{ 0x06,0x08,0x10,0x1E,0x11,0x11,0x0E }, // 6
        [7]u8{ 0x1F,0x01,0x02,0x04,0x08,0x08,0x08 }, // 7
        [7]u8{ 0x0E,0x11,0x11,0x0E,0x11,0x11,0x0E }, // 8
        [7]u8{ 0x0E,0x11,0x11,0x0F,0x01,0x02,0x0C }, // 9
        [7]u8{ 0x00,0x04,0x00,0x00,0x04,0x00,0x00 }, // :
        [7]u8{ 0x00,0x04,0x00,0x00,0x04,0x04,0x08 }, // ;
        [7]u8{ 0x02,0x04,0x08,0x10,0x08,0x04,0x02 }, // 
        [7]u8{ 0x00,0x00,0x1F,0x00,0x1F,0x00,0x00 }, // =
        [7]u8{ 0x08,0x04,0x02,0x01,0x02,0x04,0x08 }, // >
        [7]u8{ 0x0E,0x11,0x01,0x02,0x04,0x00,0x04 }, // ?
        [7]u8{ 0x0E,0x11,0x17,0x15,0x17,0x10,0x0E }, // @
        [7]u8{ 0x0E,0x11,0x11,0x1F,0x11,0x11,0x11 }, // A
        [7]u8{ 0x1E,0x11,0x11,0x1E,0x11,0x11,0x1E }, // B
        [7]u8{ 0x0E,0x11,0x10,0x10,0x10,0x11,0x0E }, // C
        [7]u8{ 0x1C,0x12,0x11,0x11,0x11,0x12,0x1C }, // D
        [7]u8{ 0x1F,0x10,0x10,0x1E,0x10,0x10,0x1F }, // E
        [7]u8{ 0x1F,0x10,0x10,0x1E,0x10,0x10,0x10 }, // F
        [7]u8{ 0x0E,0x11,0x10,0x17,0x11,0x11,0x0F }, // G
        [7]u8{ 0x11,0x11,0x11,0x1F,0x11,0x11,0x11 }, // H
        [7]u8{ 0x0E,0x04,0x04,0x04,0x04,0x04,0x0E }, // I
        [7]u8{ 0x07,0x02,0x02,0x02,0x02,0x12,0x0C }, // J
        [7]u8{ 0x11,0x12,0x14,0x18,0x14,0x12,0x11 }, // K
        [7]u8{ 0x10,0x10,0x10,0x10,0x10,0x10,0x1F }, // L
        [7]u8{ 0x11,0x1B,0x15,0x15,0x11,0x11,0x11 }, // M
        [7]u8{ 0x11,0x19,0x15,0x13,0x11,0x11,0x11 }, // N
        [7]u8{ 0x0E,0x11,0x11,0x11,0x11,0x11,0x0E }, // O
        [7]u8{ 0x1E,0x11,0x11,0x1E,0x10,0x10,0x10 }, // P
        [7]u8{ 0x0E,0x11,0x11,0x11,0x15,0x12,0x0D }, // Q
        [7]u8{ 0x1E,0x11,0x11,0x1E,0x14,0x12,0x11 }, // R
        [7]u8{ 0x0F,0x10,0x10,0x0E,0x01,0x01,0x1E }, // S
        [7]u8{ 0x1F,0x04,0x04,0x04,0x04,0x04,0x04 }, // T
        [7]u8{ 0x11,0x11,0x11,0x11,0x11,0x11,0x0E }, // U
        [7]u8{ 0x11,0x11,0x11,0x11,0x11,0x0A,0x04 }, // V
        [7]u8{ 0x11,0x11,0x15,0x15,0x15,0x1B,0x11 }, // W
        [7]u8{ 0x11,0x11,0x0A,0x04,0x0A,0x11,0x11 }, // X
        [7]u8{ 0x11,0x11,0x0A,0x04,0x04,0x04,0x04 }, // Y
        [7]u8{ 0x1F,0x01,0x02,0x04,0x08,0x10,0x1F }, // Z
        [7]u8{ 0x0E,0x08,0x08,0x08,0x08,0x08,0x0E }, // [
        [7]u8{ 0x00,0x10,0x08,0x04,0x02,0x01,0x00 }, // backslash
        [7]u8{ 0x0E,0x02,0x02,0x02,0x02,0x02,0x0E }, // ]
        [7]u8{ 0x04,0x0A,0x11,0x00,0x00,0x00,0x00 }, // ^
        [7]u8{ 0x00,0x00,0x00,0x00,0x00,0x00,0x1F }, // _
        [7]u8{ 0x08,0x04,0x00,0x00,0x00,0x00,0x00 }, // `
        [7]u8{ 0x00,0x00,0x0E,0x01,0x0F,0x11,0x0F }, // a
        [7]u8{ 0x10,0x10,0x1E,0x11,0x11,0x11,0x1E }, // b
        [7]u8{ 0x00,0x00,0x0E,0x10,0x10,0x11,0x0E }, // c
        [7]u8{ 0x01,0x01,0x0F,0x11,0x11,0x11,0x0F }, // d
        [7]u8{ 0x00,0x00,0x0E,0x11,0x1F,0x10,0x0E }, // e
        [7]u8{ 0x06,0x09,0x08,0x1C,0x08,0x08,0x08 }, // f
        [7]u8{ 0x00,0x00,0x0F,0x11,0x0F,0x01,0x0E }, // g
        [7]u8{ 0x10,0x10,0x1E,0x11,0x11,0x11,0x11 }, // h
        [7]u8{ 0x04,0x00,0x0C,0x04,0x04,0x04,0x0E }, // i
        [7]u8{ 0x02,0x00,0x06,0x02,0x02,0x12,0x0C }, // j
        [7]u8{ 0x10,0x10,0x11,0x12,0x1C,0x12,0x11 }, // k
        [7]u8{ 0x0C,0x04,0x04,0x04,0x04,0x04,0x0E }, // l
        [7]u8{ 0x00,0x00,0x1A,0x15,0x15,0x11,0x11 }, // m
        [7]u8{ 0x00,0x00,0x1E,0x11,0x11,0x11,0x11 }, // n
        [7]u8{ 0x00,0x00,0x0E,0x11,0x11,0x11,0x0E }, // o
        [7]u8{ 0x00,0x00,0x1E,0x11,0x1E,0x10,0x10 }, // p
        [7]u8{ 0x00,0x00,0x0F,0x11,0x0F,0x01,0x01 }, // q
        [7]u8{ 0x00,0x00,0x16,0x19,0x10,0x10,0x10 }, // r
        [7]u8{ 0x00,0x00,0x0F,0x10,0x0E,0x01,0x1E }, // s
        [7]u8{ 0x08,0x08,0x1C,0x08,0x08,0x09,0x06 }, // t
        [7]u8{ 0x00,0x00,0x11,0x11,0x11,0x11,0x0F }, // u
        [7]u8{ 0x00,0x00,0x11,0x11,0x11,0x0A,0x04 }, // v
        [7]u8{ 0x00,0x00,0x11,0x15,0x15,0x15,0x0A }, // w
        [7]u8{ 0x00,0x00,0x11,0x0A,0x04,0x0A,0x11 }, // x
        [7]u8{ 0x00,0x00,0x11,0x11,0x0F,0x01,0x0E }, // y
        [7]u8{ 0x00,0x00,0x1F,0x02,0x04,0x08,0x1F }, // z
        [7]u8{ 0x02,0x04,0x04,0x08,0x04,0x04,0x02 }, // {
        [7]u8{ 0x04,0x04,0x04,0x00,0x04,0x04,0x04 }, // |
        [7]u8{ 0x08,0x04,0x04,0x02,0x04,0x04,0x08 }, // }
        [7]u8{ 0x00,0x00,0x08,0x15,0x02,0x00,0x00 }, // ~
    };
    pub fn drawText(self: *Framebuffer, x: u32, y: u32, text: []const u8, color: u32, bg: u32) void {
        const px: [*]u32 = @ptrCast(@alignCast(self.data.ptr));
        const pitch: u32 = @intCast(self.pitch / 4);
        var cx = x;
        for (text) |ch| {
            if (ch < 32 or ch > 126) { cx += FONT_W + 1; continue; }
            const glyph = font_data[ch - 32];
            var gy: u32 = 0;
            while (gy < FONT_H) : (gy += 1) {
                var gx: u32 = 0;
                while (gx < FONT_W) : (gx += 1) {
                    const bit = (glyph[gy] >> @intCast(FONT_W - 1 - gx)) & 1;
                    const py2 = y + gy;
                    const px2 = cx + gx;
                    if (py2 < self.height and px2 < self.width)
                        px[py2 * pitch + px2] = if (bit != 0) color else bg;
                }
            }
            cx += FONT_W + 1;
        }
    }
};

pub const Output = struct {
    fd:         i32 = -1,
    fd_write:   i32 = -1,
    width:      u32 = 0,
    height:     u32 = 0,
    fb:         Framebuffer = undefined,
    // DRM state
    crtc_id:     u32 = 0,
    connector_id: u32 = 0,
    fb_id:       u32 = 0,
    fb_id_back:  u32 = 0,
    dumb_handle: u32 = 0,
    dumb_handle_back: u32 = 0,
    back_data:   []u32 = &[_]u32{},
    flip_pending: bool = false,
    last_flip_ms: u64 = 0,
    pending_flip: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    mode:         DrmModeModeInfo = .{},

    pub fn drawBuffer(self: *Output) *Framebuffer { return &self.fb; }

    pub fn pageFlip(self: *Output, _: i32) !void {
        var conn_id = self.connector_id;
        var crtc = DrmModeCrtc{
            .crtc_id            = self.crtc_id,
            .fb_id              = self.fb_id,
            .mode               = self.mode,
            .mode_valid         = 1,
            .count_connectors   = 1,
            .set_connectors_ptr = @intFromPtr(&conn_id),
        };
        drm_ioctl(self.fd, DRM_IOCTL_MODE_SETCRTC, &crtc) catch {};
    }

};

pub const Device = struct {
    fd:        i32,
    output:    ?Output = null,
    allocator: std.mem.Allocator,

    pub fn autoDetect(allocator: std.mem.Allocator) !Device {
        // Intentar /dev/dri/card1 primero (virtio-gpu en Proxmox)
        const cards = [_][]const u8{ "/dev/dri/card1", "/dev/dri/card0" };
        for (cards) |path| {
            var buf: [32:0]u8 = std.mem.zeroes([32:0]u8);
            @memcpy(buf[0..path.len], path);
            const rc = linux.open(&buf, .{ .ACCMODE = .RDWR }, 0);
            const fd: i32 = @bitCast(@as(u32, @truncate(rc)));
            if (fd >= 0) {
                std.log.info("drm: usando {s}", .{path});
                return Device{ .fd = fd, .allocator = allocator };
            }
        }
        return error.NoDrmDevice;
    }

    pub fn detectOutput(self: *Device) !void {
        const fd = self.fd;

        // 1. GET_RESOURCES
        var res = DrmModeResources{};
        std.log.info("sizeof DrmModeResources={}", .{@sizeOf(DrmModeResources)});
        try drm_ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res);

        if (res.count_connectors == 0) return error.NoConnector;
        const n_conn = @min(res.count_connectors, 8);
        const n_crtc = @min(res.count_crtcs, 8);
        var connector_ids: [8]u32 = std.mem.zeroes([8]u32);
        var crtc_ids: [8]u32 = std.mem.zeroes([8]u32);
        var encoder_ids: [8]u32 = std.mem.zeroes([8]u32);
        var fb_ids: [8]u32 = std.mem.zeroes([8]u32);
        res.connector_id_ptr = @intFromPtr(&connector_ids);
        res.crtc_id_ptr      = @intFromPtr(&crtc_ids);
        res.encoder_id_ptr   = @intFromPtr(&encoder_ids);
        res.fb_id_ptr        = @intFromPtr(&fb_ids);
        try drm_ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &res);
        std.log.info("drm: res counts conn={} crtc={} enc={}", .{res.count_connectors, res.count_crtcs, res.count_encoders});

        // 2. Encontrar conector conectado
        var conn_id: u32 = 0;
        var enc_id:  u32 = 0;
        var mode:    DrmModeModeInfo = .{};
        var width:   u32 = 0;
        var height:  u32 = 0;

        for (connector_ids[0..n_conn]) |cid| {
            var modes_buf: [32]DrmModeModeInfo = std.mem.zeroes([32]DrmModeModeInfo);
            var conn = DrmModeGetConnector{
                .connector_id = cid,
                .modes_ptr    = @intFromPtr(&modes_buf),
                .count_modes  = 32,
            };
            try drm_ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &conn);
            if (conn.connection != 1) continue; // no conectado
            if (conn.count_modes == 0) continue;
            conn_id = cid;
            enc_id  = conn.encoder_id;
            mode    = modes_buf[0]; // primer modo (el preferido)
            width   = mode.hdisplay;
            height  = mode.vdisplay;
            std.log.info("drm: connector={} {}x{} mode={s}", .{cid, width, height, mode.name[0..8]});
            break;
        }
        if (conn_id == 0) return error.NoConnectedConnector;

        // 3. Obtener CRTC del encoder
        var enc = DrmModeGetEncoder{ .encoder_id = enc_id };
        try drm_ioctl(fd, DRM_IOCTL_MODE_GETENCODER, &enc);
        var crtc_id = enc.crtc_id;
        if (crtc_id == 0 and n_crtc > 0) crtc_id = crtc_ids[0];

        // 4. CREATE_DUMB buffer
        var dumb = DrmModeCreateDumb{ .width = width, .height = height, .bpp = 32 };
        try drm_ioctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &dumb);
        std.log.info("drm: dumb handle={} pitch={} size={}", .{dumb.handle, dumb.pitch, dumb.size});

        // 5. ADD_FB
        var fb_cmd = DrmModeFbCmd{
            .width  = width,
            .height = height,
            .pitch  = dumb.pitch,
            .bpp    = 32,
            .depth  = 24,
            .handle = dumb.handle,
        };
        try drm_ioctl(fd, DRM_IOCTL_MODE_ADDFB, &fb_cmd);
        std.log.info("drm: fb_id={}", .{fb_cmd.fb_id});

        // 6. MAP_DUMB
        var map = DrmModeMapDumb{ .handle = dumb.handle };
        try drm_ioctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &map);

        const size: usize = @intCast(dumb.size);
        const ptr = try std.posix.mmap(null, size,
            std.posix.PROT{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED }, fd, @intCast(map.offset));
        const pixels = @as([*]u32, @ptrCast(@alignCast(ptr.ptr)))[0..size/4];

        // 7. SET_CRTC
        var set_crtc = DrmModeCrtc{
            .crtc_id            = crtc_id,
            .fb_id              = fb_cmd.fb_id,
            .mode               = mode,
            .mode_valid         = 1,
            .count_connectors   = 1,
            .set_connectors_ptr = @intFromPtr(&conn_id),
        };
        try drm_ioctl(fd, DRM_IOCTL_MODE_SETCRTC, &set_crtc);
        std.log.info("drm: SET_CRTC ok crtc={}", .{crtc_id});

        self.output = Output{
            .fd           = fd,
            .fd_write     = fd,
            .width        = width,
            .height       = height,
            .crtc_id      = crtc_id,
            .connector_id = conn_id,
            .fb_id        = fb_cmd.fb_id,
            .dumb_handle  = dumb.handle,
            .mode         = mode,
            .fb = Framebuffer{
                .width  = width,
                .height = height,
                .pitch  = dumb.pitch,
                .size   = size,
                .data   = pixels,
                .ptr    = ptr.ptr,
            },
        };
    }

    pub fn close(self: *Device) void {
        _ = linux.close(@intCast(self.fd));
    }
};
