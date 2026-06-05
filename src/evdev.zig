const std = @import("std");
const linux = std.os.linux;

pub const EV_KEY: u16 = 0x01;
pub const EV_REL: u16 = 0x02;

pub const KEY_LEFTCTRL   : u16 = 29;
pub const KEY_LEFTSHIFT  : u16 = 42;
pub const KEY_RIGHTSHIFT : u16 = 54;
pub const KEY_LEFTALT    : u16 = 56;
pub const KEY_F1 : u16 = 59;
pub const KEY_SUPER      : u16 = 125;
pub const KEY_Q          : u16 = 16;
pub const KEY_SPACE      : u16 = 57;

pub const KEY_RELEASED: i32 = 0;
pub const KEY_PRESSED : i32 = 1;
pub const KEY_REPEAT  : i32 = 2;

pub const REL_X: u16 = 0x00;
pub const REL_Y: u16 = 0x01;

pub const InputEvent = extern struct {
    time_sec  : i64,
    time_usec : i64,
    type  : u16,
    code  : u16,
    value : i32,
    comptime { std.debug.assert(@sizeOf(InputEvent) == 24); }
};

pub const Modifiers = struct {
    ctrl : bool = false,
    shift: bool = false,
    alt  : bool = false,
    super: bool = false,
};

pub const Device = struct {
    fd: i32,

    pub fn close(self: *Device) void {
        _ = linux.close(@intCast(self.fd));
    }
};

pub const InputManager = struct {
    devices  : [32]Device = undefined,
    count    : usize = 0,
    allocator: std.mem.Allocator,
    mods     : Modifiers = .{},

    pub fn init(allocator: std.mem.Allocator) InputManager {
        return .{ .allocator = allocator };
    }

    pub fn scanDevices(self: *InputManager) !void {
        var i: u8 = 0;
        while (i < 32) : (i += 1) {
            var path: [32:0]u8 = std.mem.zeroes([32:0]u8);
            _ = std.fmt.bufPrint(&path, "/dev/input/event{d}", .{i}) catch continue;
            const rc = linux.open(&path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0);
            const fd: i32 = @bitCast(@as(u32, @truncate(rc)));
            if (fd < 0) continue;
            if (self.count >= 32) { _ = linux.close(@intCast(fd)); continue; }
            self.devices[self.count] = .{ .fd = fd };
            self.count += 1;
            std.log.info("evdev: abierto event{d}", .{i});
        }
        std.log.info("evdev: {} dispositivos", .{self.count});
    }

    pub fn deinit(self: *InputManager) void {
        for (self.devices[0..self.count]) |*dev| dev.close();
    }
};
