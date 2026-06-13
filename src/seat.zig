/// seat.zig — wl_seat, wl_keyboard, wl_pointer
/// Maneja input de teclado y puntero para clientes Wayland
const std = @import("std");
const linux = std.os.linux;

// Opcodes de eventos wl_keyboard
pub const WL_KEYBOARD_KEYMAP  : u16 = 0;
pub const WL_KEYBOARD_ENTER   : u16 = 1;
pub const WL_KEYBOARD_LEAVE   : u16 = 2;
pub const WL_KEYBOARD_KEY     : u16 = 3;
pub const WL_KEYBOARD_MODIFIERS: u16 = 4;

// Opcodes de eventos wl_pointer
pub const WL_POINTER_ENTER  : u16 = 0;
pub const WL_POINTER_LEAVE  : u16 = 1;
pub const WL_POINTER_MOTION : u16 = 2;
pub const WL_POINTER_BUTTON : u16 = 3;
pub const WL_POINTER_AXIS   : u16 = 4;

pub const WL_KEYBOARD_KEY_STATE_RELEASED: u32 = 0;
pub const WL_KEYBOARD_KEY_STATE_PRESSED : u32 = 1;

fn sendTo(fd: i32, data: []const u8) void {
    _ = linux.sendto(@intCast(fd), data.ptr, data.len, linux.MSG.NOSIGNAL, null, 0);
}

fn writeU32(buf: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, buf[off..][0..4], v, .little);
}
fn writeI32(buf: []u8, off: usize, v: i32) void {
    std.mem.writeInt(i32, buf[off..][0..4], v, .little);
}

fn sendEvent(fd: i32, obj: u32, op: u16, payload: []const u8) void {
    const total: u32 = @intCast(8 + payload.len);
    var h: [8]u8 = undefined;
    writeU32(&h, 0, obj);
    writeU32(&h, 4, (total << 16) | op);
    sendTo(fd, &h);
    if (payload.len > 0) sendTo(fd, payload);
}

/// Enviar wl_seat.capabilities al cliente
pub fn sendSeatCapabilities(fd: i32, seat_id: u32) void {
    // capabilities: 1=pointer, 2=keyboard, 3=ambos
    var p: [4]u8 = undefined;
    writeU32(&p, 0, 3);
    sendEvent(fd, seat_id, 0, &p);
    std.log.info("wl_seat bound id={} capabilities enviadas", .{seat_id});
}

/// Enviar wl_keyboard keymap (XKB_KEYMAP_FORMAT_XKB_V1 = 1)
/// Usamos el keymap mínimo del sistema
pub fn sendKeymap(fd: i32, keyboard_id: u32) void {
    // Abrir el keymap del sistema
    const keymap_path = "/usr/share/X11/xkb/keymaps/xkbcomp";
    _ = keymap_path;

    // Keymap XKB mínimo funcional
    const keymap_str =
        "xkb_keymap {\n" ++
        "  xkb_keycodes { include \"evdev+aliases(qwerty)\" };\n" ++
        "  xkb_types { include \"complete\" };\n" ++
        "  xkb_compat { include \"complete\" };\n" ++
        "  xkb_symbols { include \"pc+us+inet(evdev)\" };\n" ++
        "  xkb_geometry { include \"pc(pc105)\" };\n" ++
        "};\n";

    // Crear memfd con el keymap
    const mfd = linux.memfd_create("wl_keymap", 0);
    const mfd_i: i32 = @bitCast(@as(u32, @truncate(mfd)));
    if (mfd_i < 0) {
        std.log.err("memfd_create falló", .{});
        return;
    }

    _ = linux.write(@intCast(mfd_i), keymap_str.ptr, keymap_str.len);

    // Enviar keymap via SCM_RIGHTS
    const keymap_size: u32 = @intCast(keymap_str.len + 1);
    var payload: [8]u8 = undefined;
    writeU32(&payload, 0, 1); // format = XKB_V1
    writeU32(&payload, 4, keymap_size);

    // Necesitamos enviar el fd via SCM_RIGHTS junto con el mensaje
    var cmsg_buf: [256]u8 align(8) = std.mem.zeroes([256]u8);
    const cmsg_len = @sizeOf(linux.cmsghdr) + @sizeOf(i32);
    const cmsg: *linux.cmsghdr = @ptrCast(@alignCast(&cmsg_buf));
    cmsg.len   = cmsg_len;
    cmsg.level = linux.SOL.SOCKET;
    cmsg.type  = 1; // SCM_RIGHTS
    const fdptr: *i32 = @ptrCast(@alignCast(&cmsg_buf[@sizeOf(linux.cmsghdr)]));
    fdptr.* = mfd_i;

    // Header del mensaje Wayland
    const total: u32 = 8 + 8;
    var hdr: [8]u8 = undefined;
    writeU32(&hdr, 0, keyboard_id);
    writeU32(&hdr, 4, (total << 16) | WL_KEYBOARD_KEYMAP);

    // Combinar header + payload
    var msg_data: [16]u8 = undefined;
    @memcpy(msg_data[0..8], &hdr);
    @memcpy(msg_data[8..16], &payload);

    var iov = std.posix.iovec{
        .base = &msg_data,
        .len  = msg_data.len,
    };
    var msghdr = linux.msghdr{
        .name       = null,
        .namelen    = 0,
        .iov        = @ptrCast(&iov),
        .iovlen     = 1,
        .control    = &cmsg_buf,
        .controllen = cmsg_len,
        .flags      = 0,
    };
    _ = linux.sendmsg(@intCast(fd), @ptrCast(&msghdr), linux.MSG.NOSIGNAL);
    _ = linux.close(@intCast(mfd_i));
    std.log.info("wl_keyboard keymap enviado fd={}", .{keyboard_id});
    // repeat_info: rate=25 delay=600
    var ri: [8]u8 = undefined;
    std.mem.writeInt(u32, ri[0..4], 25, .little);
    std.mem.writeInt(u32, ri[4..8], 600, .little);
    sendEvent(fd, keyboard_id, 5, &ri);
}

/// Enviar wl_keyboard.enter (el cliente recibe el foco)
/// Enviar wl_keyboard.leave (opcode 1)
pub fn sendKeyboardLeave(fd: i32, keyboard_id: u32, surface_id: u32, serial: u32) void {
    var p: [12]u8 = undefined;
    writeU32(&p, 0, serial);
    writeU32(&p, 4, surface_id);
    writeU32(&p, 8, 0); // keys array len = 0
    sendEvent(fd, keyboard_id, 1, &p);
    std.log.info("wl_keyboard leave surface={}", .{surface_id});
}

pub fn sendKeyboardEnter(fd: i32, keyboard_id: u32, surface_id: u32, serial: u32) void {
    // payload: serial(u32) + surface(u32) + keys_array_len(u32) = 12 bytes
    var p: [12]u8 = undefined;
    writeU32(&p, 0, serial);
    writeU32(&p, 4, surface_id);
    writeU32(&p, 8, 0); // array vacío de teclas presionadas
    sendEvent(fd, keyboard_id, WL_KEYBOARD_ENTER, &p);
    std.log.info("wl_keyboard enter fd={} surface={}", .{fd, surface_id});
}

/// Enviar wl_keyboard.key
pub fn sendKey(fd: i32, keyboard_id: u32, serial: u32, time: u32, key: u32, state: u32) void {
    var p: [16]u8 = undefined;
    writeU32(&p, 0, serial);
    writeU32(&p, 4, time);
    writeU32(&p, 8, key);
    writeU32(&p, 12, state);
    sendEvent(fd, keyboard_id, WL_KEYBOARD_KEY, &p);
}

/// Enviar wl_keyboard.modifiers
pub fn sendModifiers(fd: i32, keyboard_id: u32, serial: u32, mods_dep: u32, mods_lat: u32, mods_lock: u32, group: u32) void {
    var p: [20]u8 = undefined;
    writeU32(&p, 0, serial);
    writeU32(&p, 4, mods_dep);
    writeU32(&p, 8, mods_lat);
    writeU32(&p, 12, mods_lock);
    writeU32(&p, 16, group);
    sendEvent(fd, keyboard_id, WL_KEYBOARD_MODIFIERS, &p);
}

/// Enviar wl_pointer.enter
pub fn sendPointerEnter(fd: i32, pointer_id: u32, serial: u32, surface_id: u32, sx: i32, sy: i32) void {
    var p: [16]u8 = undefined;
    writeU32(&p, 0, serial);
    writeU32(&p, 4, surface_id);
    writeI32(&p, 8, sx << 8);
    writeI32(&p, 12, sy << 8);
    sendEvent(fd, pointer_id, WL_POINTER_ENTER, &p);
}

/// Enviar wl_pointer.motion
pub fn sendPointerMotion(fd: i32, pointer_id: u32, time: u32, sx: i32, sy: i32) void {
    var p: [12]u8 = undefined;
    writeU32(&p, 0, time);
    writeI32(&p, 4, sx << 8);
    writeI32(&p, 8, sy << 8);
    sendEvent(fd, pointer_id, WL_POINTER_MOTION, &p);
}

/// Enviar wl_pointer.button
pub fn sendPointerButton(fd: i32, pointer_id: u32, serial: u32, time: u32, button: u32, state: u32) void {
    var p: [20]u8 = undefined;
    writeU32(&p, 0, serial);
    writeU32(&p, 4, time);
    writeU32(&p, 8, button);
    writeU32(&p, 12, state);
    writeU32(&p, 16, 0);
    sendEvent(fd, pointer_id, WL_POINTER_BUTTON, &p);
}

pub fn sendPointerLeave(fd: i32, pointer_id: u32, surface_id: u32, serial: u32) void {
    var p: [8]u8 = undefined;
    writeU32(&p, 0, serial);
    writeU32(&p, 4, surface_id);
    sendEvent(fd, pointer_id, 2, &p);
}
pub fn sendPointerFrame(fd: i32, pointer_id: u32) void {
    sendEvent(fd, pointer_id, 5, &[_]u8{});
}
