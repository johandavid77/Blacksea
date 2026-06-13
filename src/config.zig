//! config.zig — Configuración de Blacksea via Lua
const std = @import("std");
const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lualib.h");
    @cInclude("lauxlib.h");
});
extern fn bs_lua_tostring(L: ?*anyopaque, idx: c_int, len: ?*usize) ?[*]const u8;
extern fn bs_lua_dofile(L: ?*anyopaque, filename: [*c]const u8) c_int;
extern fn bs_lua_getglobal(L: ?*anyopaque, name: [*c]const u8) c_int;
extern fn bs_lua_tointeger(L: ?*anyopaque, idx: c_int) i64;
extern fn bs_lua_isnumber(L: ?*anyopaque, idx: c_int) c_int;
extern fn bs_lua_pop(L: ?*anyopaque, n: c_int) void;
extern fn bs_lua_isstring2(L: ?*anyopaque, idx: c_int) c_int;


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

        if (bs_lua_dofile(L, @as([*c]const u8, @ptrCast(cpath.ptr))) != 0) {
            const err_s: []const u8 = "lua error";
            const err: [*:0]const u8 = @ptrCast(err_s.ptr);
            std.log.warn("config error: {s}", .{err});
            return; // usar defaults
        }

        // border_width
        _ = bs_lua_getglobal(L, "border_width");
        if (bs_lua_isnumber(L, -1) != 0)
            self.border_width = @intCast(bs_lua_tointeger(L, -1));
        bs_lua_pop(L, 1);

        // gap
        _ = bs_lua_getglobal(L, "gap");
        if (bs_lua_isnumber(L, -1) != 0)
            self.gap = @intCast(bs_lua_tointeger(L, -1));
        bs_lua_pop(L, 1);

        // wallpaper_path
        _ = bs_lua_getglobal(L, "wallpaper");
        if (bs_lua_isstring2(L, -1) != 0) {
            var s_buf: [256]u8 = undefined;
            if (bs_lua_isstring2(L, -1) == 0) return;
            const s_cstr = bs_lua_tostring(L, -1, null);
            if (s_cstr == null) return;
            const s_raw: [*c]const u8 = @ptrCast(s_cstr);
            const s_len: usize = if (s_cstr) |p| std.mem.len(@as([*:0]const u8, @ptrCast(p))) else 0;
            const s_n = @min(s_len, 255);
            @memcpy(s_buf[0..s_n], @as([*]const u8, @ptrCast(s_raw))[0..s_n]);
            s_buf[s_n] = 0;
            const s: [*:0]const u8 = @ptrCast(&s_buf);
            const slen = std.mem.len(s);
            const copy_len = @min(slen, 255);
            @memcpy(self.wallpaper_path[0..copy_len], s[0..copy_len]);
            self.wallpaper_path[copy_len] = 0;
        }
        bs_lua_pop(L, 1);
        std.log.info("config: border={} gap={}", .{self.border_width, self.gap});
    }
};
