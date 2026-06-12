//! config.zig — Configuración de Blacksea via Lua
const std = @import("std");
const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lualib.h");
    @cInclude("lauxlib.h");
});

pub const Config = struct {
    border_width:  u32  = 2,
    border_color:  u32  = 0xFF4A90D9,
    gap:           u32  = 8,
    mod_key:       []const u8 = "super",
    wallpaper_path: [256]u8 = [_]u8{0} ** 256,

    pub fn load(self: *Config, path: []const u8) !void {
        const L = c.luaL_newstate() orelse return error.LuaInit;
        defer c.lua_close(L);
        c.luaL_openlibs(L);

        var buf: [256]u8 = undefined;
        const cpath = try std.fmt.bufPrintZ(&buf, "{s}", .{path});

        if (c.luaL_dofile(L, cpath.ptr) != 0) {
            var err_buf: [256]u8 = undefined;
            const err_s = if (c.lua_isstring(L, -1) != 0) blk: { var _l: usize = 0; const _p = c.lua_tolstring(L, -1, &_l); if (_p) |p| { const n = @min(_l, 255); @memcpy(err_buf[0..n], @as([*]const u8, @ptrCast(p))[0..n]); err_buf[n] = 0; break :blk err_buf[0..n+1]; } break :blk "unknown\x00"; } else "unknown\x00";
            const err: [*:0]const u8 = @ptrCast(err_s.ptr);
            std.log.warn("config error: {s}", .{err});
            return; // usar defaults
        }

        // border_width
        _ = c.lua_getglobal(L, "border_width");
        if (c.lua_isnumber(L, -1) != 0)
            self.border_width = @intCast(c.lua_tointeger(L, -1));
        c.lua_pop(L, 1);

        // gap
        _ = c.lua_getglobal(L, "gap");
        if (c.lua_isnumber(L, -1) != 0)
            self.gap = @intCast(c.lua_tointeger(L, -1));
        c.lua_pop(L, 1);

        // wallpaper_path
        _ = c.lua_getglobal(L, "wallpaper");
        if (c.lua_isstring(L, -1) != 0) {
            var s_buf: [256]u8 = undefined;
            if (c.lua_isstring(L, -1) == 0) return;
            var s_len: usize = 0;
            const s_raw = c.lua_tolstring(L, -1, &s_len) orelse return;
            const s_n = @min(s_len, 255);
            @memcpy(s_buf[0..s_n], @as([*]const u8, @ptrCast(s_raw))[0..s_n]);
            s_buf[s_n] = 0;
            const s: [*:0]const u8 = @ptrCast(&s_buf);
            const slen = std.mem.len(s);
            const copy_len = @min(slen, 255);
            @memcpy(self.wallpaper_path[0..copy_len], s[0..copy_len]);
            self.wallpaper_path[copy_len] = 0;
        }
        c.lua_pop(L, 1);
        std.log.info("config: border={} gap={}", .{self.border_width, self.gap});
    }
};
