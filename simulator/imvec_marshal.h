#ifndef IMVEC_MARSHAL_H
#define IMVEC_MARSHAL_H

/*! imvec_marshal.h - how an ImVec2 crosses the Lua boundary, in both directions.
 *
 * Core: a plain `{x = , y = }` table. Every ImGui call that takes or returns a position or a size
 * goes through this, so it has to exist before imgui_composer.h is parsed - which is why that file
 * includes this one at its top rather than relying on an ordering in main.cpp.
 *
 * Why it is its own file here: in math_writer these two specializations live inside
 * char_draw_composer.h, beside the glyph renderer that first needed them. This project has no glyph
 * renderer and wants none, and the conversion is not about fonts - so it is lifted out on its own
 * rather than dragging sixteen kilobytes of unrelated drawing along for two tables. The shape of
 * the table is copied exactly, so a script written against either project reads the same.
 *
 * @date 2026-09-16 */

#include "virt_composer.h"
#include "imgui.h"

namespace virt_composer {

template <ssize_t index>
struct luaw_param_t<ImVec2, index> {
    ImVec2 luaw_single_param(lua_State *L);
};

template <>
struct luaw_returner_t<ImVec2> {
    void luaw_ret_push(lua_State *L, ImVec2 v);
};

/*! Reads `{x = , y = }` off the stack. A nil argument answers (0, 0) rather than raising: an
 * optional position is common on the ImGui calls this serves, and zero is what they mean by it.
 * @date 2026-09-16 */
template <ssize_t index>
inline ImVec2 luaw_param_t<ImVec2, index>::luaw_single_param(lua_State *L) {
    ImVec2 ret;
    if (lua_isnil(L, index))
        return ret;
    lua_getfield(L, index, "x");
    ret.x = (float)lua_tonumber(L, -1);
    lua_pop(L, 1);
    lua_getfield(L, index, "y");
    ret.y = (float)lua_tonumber(L, -1);
    lua_pop(L, 1);
    return ret;
}

/*! Pushes `{x = , y = }`. @date 2026-09-16 */
inline void luaw_returner_t<ImVec2>::luaw_ret_push(lua_State *L, ImVec2 v) {
    lua_createtable(L, 0, 2);
    lua_pushnumber(L, v.x);
    lua_setfield(L, -2, "x");
    lua_pushnumber(L, v.y);
    lua_setfield(L, -2, "y");
}

} /* namespace virt_composer */

#endif /* IMVEC_MARSHAL_H */
