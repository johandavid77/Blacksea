#include "lua.h"
#include "lauxlib.h"

const char* bs_lua_tostring(lua_State* L, int idx, size_t* len) {
    return lua_tolstring(L, idx, len);
}

int bs_lua_dofile(lua_State* L, const char* filename) {
    return luaL_dofile(L, filename);
}

int bs_lua_getglobal(lua_State* L, const char* name) {
    return lua_getglobal(L, name);
}

lua_Integer bs_lua_tointeger(lua_State* L, int idx) {
    return lua_tointeger(L, idx);
}

int bs_lua_isnumber(lua_State* L, int idx) {
    return lua_isnumber(L, idx);
}

void bs_lua_pop(lua_State* L, int n) {
    lua_pop(L, n);
}

int bs_lua_isstring2(lua_State* L, int idx) {
    return lua_isstring(L, idx);
}
