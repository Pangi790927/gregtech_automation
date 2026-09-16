#ifndef IMGUI_COMPOSER_H
#define IMGUI_COMPOSER_H

/* The ImVec2 conversions this file needs in both directions. In math_writer they sit inside
char_draw_composer.h; this project has no glyph renderer, so they were lifted into a file of
their own - see imvec_marshal.h. Included here rather than left to main.cpp, because the
specializations must be visible before the wrappers below are instantiated. */
#include "imvec_marshal.h"

#include "virt_composer.h"
#include "imgui_impl_glfw.h"
#include "imgui_impl_opengl3.h"
#include "imgui_internal.h"

namespace virt_composer {

extern inline std::unordered_map<std::string, ImGuiKey> imgui_key_from_str;
extern inline std::unordered_map<std::string, ImGuiMouseButton_> imgui_mousebtn_from_str;
extern inline std::unordered_map<std::string, ImGuiTableFlags_> imgui_table_flags_from_str;
extern inline std::unordered_map<std::string, ImGuiTableColumnFlags_> imgui_table_col_flags_from_str;
extern inline std::unordered_map<std::string, ImGuiChildFlags_> imgui_child_flags_from_str;
extern inline std::unordered_map<std::string, ImGuiSelectableFlags_> imgui_selectable_flags_from_str;

template <> inline ImGuiKey get_enum_val<ImGuiKey>(fkyaml::node &n);
template <> inline ImGuiMouseButton_ get_enum_val<ImGuiMouseButton_>(fkyaml::node &n);

} /* namespace virt_composer */

namespace imgui_composer {

namespace vc = virt_composer;
namespace imgc = imgui_composer;

inline std::vector<uint32_t> input_queue_chars() {
    auto &io = ImGui::GetIO();
    return std::vector<uint32_t>(io.InputQueueCharacters.begin(), io.InputQueueCharacters.end());
}

inline ImVec2 get_display_size() {
    return ImGui::GetIO().DisplaySize;
}

/*! Every ImGuiKey name paired with its integer value, as a Lua array of {name, id} pairs -
 * `{{"ImGuiKey_A", 546}, {"ImGuiKey_Tab", 512}, ...}`.
 *
 * Added 2026-09-07 for scripts/keymap.lua, whose F1 panel lets a binding be typed as text
 * ("Ctrl+Shift+K") and therefore has to know which key names actually exist before it can accept
 * one. Lua can already read any SINGLE constant as `vc.ImGuiKey_A` (add_lua_flag_mapping puts them
 * all on the vc table below), but it cannot ENUMERATE them, and it has no way back from an id to a
 * name - which is what displaying a loaded binding needs. Both directions come from this one call.
 *
 * Returns the same `imgui_key_from_str` table that already backs those constants and
 * get_enum_val<ImGuiKey>, rather than a second list to keep in sync - the pattern
 * add_lua_flag_mapping's own doc asks for.
 *
 * A vector-of-pairs, not the map itself: luaw_returner_t has no unordered_map specialization (it
 * covers vector, tuple and pair), and this needs no new conversion machinery to work. Called once
 * at load, never per frame. */
inline std::vector<std::pair<std::string, int>> key_names() {
    std::vector<std::pair<std::string, int>> out;
    out.reserve(vc::imgui_key_from_str.size());
    for (const auto &[name, key] : vc::imgui_key_from_str)
        out.emplace_back(name, (int)key);
    return out;
}

/*! This frame's vertical mouse wheel delta (positive = away from the user, the usual "scroll up"
 * direction) - not previously exposed; debug_input_pipe.cpp could already inject a wheel event
 * (AddMouseWheelEvent), but nothing could read the resulting io.MouseWheel back out from Lua. */
inline float get_mouse_wheel() {
    return ImGui::GetIO().MouseWheel;
}

/*! Where the ImGui_Add* calls draw: the foreground when asked, the current window otherwise.
 *
 * Added for this project. A window draw list is CLIPPED TO ITS WINDOW, and outside any Begin the
 * current window is ImGui's implicit debug one - so a heads-up display drawn at screen coordinates
 * was being drawn correctly and then clipped away to nothing. math_writer never met this because
 * everything it draws is inside a window it opened.
 *
 * The foreground list has no window and no clip rect, and is composited over every window, which is
 * what a crosshair and a hotbar want. The flag is explicit rather than guessed from whether a window
 * happens to be open, because "am I inside a Begin" is not a question ImGui answers honestly - there
 * is always a current window. */
inline bool draw_to_foreground = false;

inline void set_draw_foreground(bool on) { draw_to_foreground = on; }

inline ImDrawList *draw_list() {
    if (draw_to_foreground)
        return ImGui::GetForegroundDrawList();
    ImGuiWindow *window = ImGui::GetCurrentWindow();
    if (window->SkipItems)
        return nullptr;
    return ImGui::GetWindowDrawList();
}

inline void add_line(ImVec2 p1, ImVec2 p2, uint32_t col, float thickness) {
    if (auto *dl = draw_list())
        dl->AddLine(p1, p2, col, thickness);
}

inline void add_rect(ImVec2 p_min, ImVec2 p_max, uint32_t col, float rounding, float thickness) {
    if (auto *dl = draw_list())
        dl->AddRect(p_min, p_max, col, rounding, 0, thickness);
}

inline void add_rect_filled(ImVec2 p_min, ImVec2 p_max, uint32_t col, float rounding) {
    if (auto *dl = draw_list())
        dl->AddRectFilled(p_min, p_max, col, rounding, 0);
}

inline void add_circle(ImVec2 center, float radius, uint32_t col, float thickness) {
    if (auto *dl = draw_list())
        dl->AddCircle(center, radius, col, 0, thickness);
}

/*! An arc: the part of a circle between two angles, radians, ImGui's own convention (y grows
 * downward, angle 0 at 3 o'clock, sweeping toward PI/2 = down). Drawn with the path API since
 * ImDrawList has no AddArc - a padlock's shackle is the current user, a semicircle from PI to
 * 2*PI sitting on top of its body. */
inline void add_arc(ImVec2 center, float radius, uint32_t col, float a_min, float a_max,
                    float thickness) {
    if (auto *dl = draw_list()) {
        dl->PathArcTo(center, radius, a_min, a_max, 0);
        dl->PathStroke(col, 0, thickness);
    }
}

inline void add_circle_filled(ImVec2 center, float radius, uint32_t col) {
    if (auto *dl = draw_list())
        dl->AddCircleFilled(center, radius, col, 0);
}

inline void add_triangle(ImVec2 p1, ImVec2 p2, ImVec2 p3, uint32_t col, float thickness) {
    if (auto *dl = draw_list())
        dl->AddTriangle(p1, p2, p3, col, thickness);
}

inline void add_triangle_filled(ImVec2 p1, ImVec2 p2, ImVec2 p3, uint32_t col) {
    if (auto *dl = draw_list())
        dl->AddTriangleFilled(p1, p2, p3, col);
}

/*! Not requested, but the same shape as triangle/rect and just as cheap to expose - a 4-point
 * poly. Straightforward to drop if unwanted. */
inline void add_quad(ImVec2 p1, ImVec2 p2, ImVec2 p3, ImVec2 p4, uint32_t col, float thickness) {
    if (auto *dl = draw_list())
        dl->AddQuad(p1, p2, p3, p4, col, thickness);
}

inline void add_quad_filled(ImVec2 p1, ImVec2 p2, ImVec2 p3, ImVec2 p4, uint32_t col) {
    if (auto *dl = draw_list())
        dl->AddQuadFilled(p1, p2, p3, p4, col);
}

/*! Also not requested: raw ImGui-font text (not the char.lua glyph catalog / fontset_t). Handy
 * for quick debug/UI labels without going through char_draw. Straightforward to drop if unwanted. */
/*! A textured quad with four free corners - what draws the little angled block models in the
 * selector. ImGui interpolates the texture across two triangles, which is exact for the
 * parallelograms an isometric cube is made of.
 *
 * `tex` arrives from Lua as a number because ImTextureID is a 64-bit integer and the OpenGL backend
 * stores the GL texture name directly in it. */
inline void add_image_quad(double tex, ImVec2 p1, ImVec2 p2, ImVec2 p3, ImVec2 p4,
        ImVec2 uv1, ImVec2 uv2, ImVec2 uv3, ImVec2 uv4, uint32_t col) {
    if (auto *dl = draw_list())
        dl->AddImageQuad((ImTextureID)(uint64_t)tex, p1, p2, p3, p4, uv1, uv2, uv3, uv4, col);
}

inline void add_text(ImVec2 pos, uint32_t col, const char *text) {
    if (auto *dl = draw_list())
        dl->AddText(pos, col, text);
}

/*! Every ImGuiKey that went down THIS FRAME, as a Lua array of ids.
 *
 * Added 2026-09-07 for the F2 keybind recorder, whose rule is "when you press a key, it adds it to
 * the recording". A PRESS, not a held state, is what that asks for: press-and-release Ctrl, then
 * press E, and Ctrl still belongs to the combo - which a "what is currently held" query would have
 * already forgotten by the time E arrives. The recorder unions this into its accumulator each
 * frame and commits only when the user clicks the tick.
 *
 * Scans the whole named-key range (~165 keys) per call, so call it ONCE a frame and only while
 * actually recording - never per binding. */
inline std::vector<int> keys_pressed() {
    std::vector<int> out;
    for (int k = ImGuiKey_NamedKey_BEGIN; k < ImGuiKey_NamedKey_END; k++)
        if (ImGui::IsKeyPressed((ImGuiKey)k, false))
            out.push_back(k);
    return out;
}

/*! True while ImGui itself wants the keyboard - i.e. a text field has focus.
 *
 * IMPORTANT for every caller: ImGui taking the keyboard does NOT stop ImGui_IsKeyPressed() from
 * returning true, so without checking this, typing "z" into a bind field also triggers the app's
 * own undo. The F1/F2 panels swallow input while open, so they are safe today; anything that puts
 * a widget on screen ALONGSIDE the editor has to stand its own key handling down on this. */
/*! Does ImGui want the mouse this frame - a widget hovered, a window dragged? Added for this
 * project: the world is directly behind the panel, so a click that ImGui is already using must not
 * also reach the block under it. math_writer's copy needed only the keyboard counterpart. */
inline bool want_capture_mouse() {
    return ImGui::GetIO().WantCaptureMouse;
}

inline bool want_capture_keyboard() {
    return ImGui::GetIO().WantCaptureKeyboard;
}

/*! A window. Added for this project, which draws its interface into a real ImGui window where
 * math_writer draws everything into the foreground list and so never needed one.
 *
 * `ImGui::Begin` takes a `bool *` for the close button, which Lua cannot hand it; passing nullptr
 * asks for a window with no close button, which is what a permanent panel wants. The return says
 * whether the window is un-collapsed and worth filling - but End() must be called either way, the
 * same rule that holds in C++. */
inline bool begin_window(const char *name, int flags) {
    return ImGui::Begin(name ? name : "window", nullptr, (ImGuiWindowFlags)flags);
}

inline void end_window() {
    ImGui::End();
}

/*! Float slider, as a value in / (changed, value) out pair - ImGui takes a float* it writes
 * through, the same pointer problem checkbox() and input_text() have. */
inline std::pair<bool, float> slider_float(const char *label, float v, float v_min, float v_max) {
    bool changed = ImGui::SliderFloat(label, &v, v_min, v_max);
    return {changed, v};
}

/*! Checkbox, as a value in / (changed, value) out pair - ImGui takes a bool* it writes through,
 * which Lua has no way to hand it. Same shape as input_text() below. */
inline std::pair<bool, bool> checkbox(const char *label, bool v) {
    bool changed = ImGui::Checkbox(label, &v);
    return {changed, v};
}

/*! Text field, as a string in / (changed, text) out pair - same pointer problem as checkbox().
 *
 * The buffer is local and rebuilt every frame from `text`, which is correct rather than merely
 * convenient: ImGui keeps its own editing state internally, keyed by the widget's id, and writes
 * the result back into whatever buffer it is handed. The caller passes the value it is holding and
 * stores what comes back. `max_len` bounds the edit; anything longer is truncated by ImGui. */
inline std::pair<bool, std::string> input_text(const char *label, const char *text, int max_len) {
    if (max_len < 1)
        max_len = 1;
    std::vector<char> buf((size_t)max_len + 1, 0);
    std::snprintf(buf.data(), buf.size(), "%s", text ? text : "");
    bool changed = ImGui::InputText(label, buf.data(), buf.size());
    return {changed, std::string(buf.data())};
}

/*! ImGui::Text() is printf-style, and these labels carry user-entered LaTeX names that can contain
 * a '%'. The makefiles pass -Wno-format-security, so the compiler will NOT warn about it. Always
 * TextUnformatted - there is deliberately no Text() binding. */
inline void text_unformatted(const char *text) {
    ImGui::TextUnformatted(text ? text : "");
}

/*! Size-only font push. ImGui 1.92's PushFont(font, size) takes NULL as "keep the current font"
 * and a size as "use this size", which is exactly the knob the help page wants - the widget font
 * here is ImGui's own, entirely separate from char_draw_composer's glyph fontset. */
inline void push_font_size(float size) {
    ImGui::PushFont(NULL, size);
}

/*! The layout cursor in ABSOLUTE (screen) coordinates, which is the space the ImGui_Add* draw
 * functions work in - GetCursorPos() is window-relative and cannot be used to place a drawn shape
 * next to a widget. Needed by the F2 panel's record indicator, which is a real circle drawn beside
 * a button rather than a character in the font. */
inline ImVec2 get_cursor_screen_pos() {
    return ImGui::GetCursorScreenPos();
}

/*! The current font's size in pixels. Exposed so a panel can ask for "twice the normal size"
 * rather than hard-coding 26 and silently becoming wrong the day the base font changes. */
inline float get_font_size() {
    return ImGui::GetFontSize();
}

inline ImVec2 calc_text_size(const char *text) {
    return ImGui::CalcTextSize(text ? text : "");
}

inline int register_meta(vc::virt_state_t *vs) {
    DBG_SCOPE();

    std::vector<luaL_Reg> imgui_tab_funcs = {
        {"ImGui_IsKeyDown", vc::luaw_function_wrapper<
               /* FN:    */ static_cast<bool(*)(ImGuiKey)>(ImGui::IsKeyDown),
               /* PARAMS:*/ vc::bm_t<ImGuiKey>
        >},
        {"ImGui_IsKeyPressed", vc::luaw_function_wrapper<
               /* FN:    */ static_cast<bool(*)(ImGuiKey, bool)>(ImGui::IsKeyPressed),
               /* PARAMS:*/ vc::bm_t<ImGuiKey>,
                            bool
        >},
        {"ImGui_IsKeyReleased", vc::luaw_function_wrapper<
               /* FN:    */ static_cast<bool(*)(ImGuiKey)>(ImGui::IsKeyReleased),
               /* PARAMS:*/ vc::bm_t<ImGuiKey>
        >},
        {"ImGui_IsKeyChordPressed", vc::luaw_function_wrapper<
               /* FN:    */ static_cast<bool(*)(ImGuiKeyChord)>(ImGui::IsKeyChordPressed),
               /* PARAMS:*/ vc::bm_t<ImGuiKey>
        >},
        {"ImGui_input_queue_chars", vc::luaw_function_wrapper<
               /* FN:    */ input_queue_chars
        >},
        {"ImGui_key_names", vc::luaw_function_wrapper<
               /* FN:    */ key_names
        >},
        {"ImGui_keys_pressed", vc::luaw_function_wrapper<
               /* FN:    */ keys_pressed
        >},
        {"ImGui_WantCaptureMouse", vc::luaw_function_wrapper<
               /* FN:    */ want_capture_mouse
        >},
        {"ImGui_WantCaptureKeyboard", vc::luaw_function_wrapper<
               /* FN:    */ want_capture_keyboard
        >},

        /* Widgets ------------------------------------------------------------------------------ */
        /* Added 2026-09-07 for the F1 help page and the F2 keybind customiser, which need real
         * interactive widgets rather than the draw-list output everything else here produces.
         * Overloaded ImGui entry points are disambiguated with static_cast, same as the key and
         * mouse blocks above. */
        {"ImGui_Button", vc::luaw_function_wrapper<
               /* FN:    */ static_cast<bool(*)(const char *, const ImVec2 &)>(ImGui::Button),
               /* PARAMS:*/ const char *, ImVec2
        >},
        {"ImGui_SmallButton", vc::luaw_function_wrapper<
               ImGui::SmallButton, const char *
        >},
        {"ImGui_Selectable", vc::luaw_function_wrapper<
               static_cast<bool(*)(const char *, bool, ImGuiSelectableFlags, const ImVec2 &)>(
                       ImGui::Selectable),
               const char *, bool, int, ImVec2
        >},
        {"ImGui_Begin", vc::luaw_function_wrapper<
               /* FN:    */ begin_window, const char *, int
        >},
        {"ImGui_End", vc::luaw_function_wrapper<
               /* FN:    */ end_window
        >},
        {"ImGui_SliderFloat", vc::luaw_function_wrapper<
               /* FN:    */ slider_float, const char *, float, float, float
        >},
        {"ImGui_Checkbox", vc::luaw_function_wrapper<
               /* FN:    */ checkbox, const char *, bool
        >},
        {"ImGui_InputText", vc::luaw_function_wrapper<
               /* FN:    */ input_text, const char *, const char *, int
        >},
        {"ImGui_Text", vc::luaw_function_wrapper<
               /* FN:    */ text_unformatted, const char *
        >},
        {"ImGui_Separator", vc::luaw_function_wrapper<
               ImGui::Separator
        >},
        {"ImGui_SameLine", vc::luaw_function_wrapper<
               ImGui::SameLine, float, float
        >},
        {"ImGui_Spacing", vc::luaw_function_wrapper<
               ImGui::Spacing
        >},
        {"ImGui_SetCursorPos", vc::luaw_function_wrapper<
               ImGui::SetCursorPos, ImVec2
        >},
        {"ImGui_GetCursorPos", vc::luaw_function_wrapper<
               ImGui::GetCursorPos
        >},
        {"ImGui_SetKeyboardFocusHere", vc::luaw_function_wrapper<
               ImGui::SetKeyboardFocusHere, int
        >},
        {"ImGui_IsItemActive", vc::luaw_function_wrapper<
               ImGui::IsItemActive
        >},
        {"ImGui_CalcTextSize", vc::luaw_function_wrapper<
               /* FN:    */ calc_text_size, const char *
        >},
        {"ImGui_GetFontSize", vc::luaw_function_wrapper<
               /* FN:    */ get_font_size
        >},
        {"ImGui_GetCursorScreenPos", vc::luaw_function_wrapper<
               /* FN:    */ get_cursor_screen_pos
        >},
        /* Reserves a rectangle of layout space without drawing anything - the correct way to make
         * room for something drawn straight onto the draw list (the help page's formulas). Moving
         * the cursor with SetCursorPos() instead asserts the moment it passes the content edge:
         * "Code uses SetCursorPos() to extend window boundaries. Please submit an item e.g.
         * Dummy() afterwards". */
        {"ImGui_Dummy", vc::luaw_function_wrapper<
               ImGui::Dummy, ImVec2
        >},
        /* Scroll state of the CURRENT window (so, inside a BeginChild, that child's). Added
         * 2026-09-07 so the help page's arrows can scroll the page first and only change chapter
         * once there is nothing left to scroll - which needs to know both where the scroll is and
         * where it ends. */
        {"ImGui_GetScrollY", vc::luaw_function_wrapper<
               ImGui::GetScrollY
        >},
        {"ImGui_GetScrollMaxY", vc::luaw_function_wrapper<
               ImGui::GetScrollMaxY
        >},
        {"ImGui_SetScrollY", vc::luaw_function_wrapper<
               static_cast<void(*)(float)>(ImGui::SetScrollY), float
        >},
        /* PushID/PopID is NOT optional in either panel: an ImGui widget's identity IS its label,
         * so N table rows each holding a field labelled "##bind" are all the SAME widget - typing
         * in row 3 edits row 1. Every row must push its own id. */
        {"ImGui_PushID", vc::luaw_function_wrapper<
               static_cast<void(*)(const char *)>(ImGui::PushID), const char *
        >},
        {"ImGui_PopID", vc::luaw_function_wrapper<
               ImGui::PopID
        >},
        {"ImGui_PushFont", vc::luaw_function_wrapper<
               /* FN:    */ push_font_size, float
        >},
        {"ImGui_PopFont", vc::luaw_function_wrapper<
               ImGui::PopFont
        >},
        {"ImGui_BeginChild", vc::luaw_function_wrapper<
               static_cast<bool(*)(const char *, const ImVec2 &, ImGuiChildFlags,
                       ImGuiWindowFlags)>(ImGui::BeginChild),
               const char *, ImVec2, int, int
        >},
        {"ImGui_EndChild", vc::luaw_function_wrapper<
               ImGui::EndChild
        >},

        /* Tables ------------------------------------------------------------------------------- */
        {"ImGui_BeginTable", vc::luaw_function_wrapper<
               ImGui::BeginTable, const char *, int, int, ImVec2, float
        >},
        {"ImGui_EndTable", vc::luaw_function_wrapper<
               ImGui::EndTable
        >},
        {"ImGui_TableNextRow", vc::luaw_function_wrapper<
               ImGui::TableNextRow, int, float
        >},
        {"ImGui_TableNextColumn", vc::luaw_function_wrapper<
               ImGui::TableNextColumn
        >},
        {"ImGui_TableSetColumnIndex", vc::luaw_function_wrapper<
               ImGui::TableSetColumnIndex, int
        >},
        {"ImGui_TableSetupColumn", vc::luaw_function_wrapper<
               ImGui::TableSetupColumn, const char *, int, float, unsigned int
        >},
        {"ImGui_TableHeadersRow", vc::luaw_function_wrapper<
               ImGui::TableHeadersRow
        >},

        /* Mouse -------------------------------------------------------------------------------- */
        /* NOTE: IsMouseDown/Clicked/Released/DoubleClicked are overloaded once
         * imgui_internal.h is visible (owner-aware variants) - disambiguate to the public,
         * non-owner-aware overload, same as ImGui_IsKeyDown/Pressed/Released above. */
        {"ImGui_IsMouseDown", vc::luaw_function_wrapper<
               /* FN:    */ static_cast<bool(*)(ImGuiMouseButton)>(ImGui::IsMouseDown),
               /* PARAMS:*/ vc::bm_t<ImGuiMouseButton_>
        >},
        {"ImGui_IsMouseClicked", vc::luaw_function_wrapper<
               /* FN:    */ static_cast<bool(*)(ImGuiMouseButton, bool)>(ImGui::IsMouseClicked),
               /* PARAMS:*/ vc::bm_t<ImGuiMouseButton_>,
                            bool
        >},
        {"ImGui_IsMouseReleased", vc::luaw_function_wrapper<
               /* FN:    */ static_cast<bool(*)(ImGuiMouseButton)>(ImGui::IsMouseReleased),
               /* PARAMS:*/ vc::bm_t<ImGuiMouseButton_>
        >},
        {"ImGui_IsMouseDoubleClicked", vc::luaw_function_wrapper<
               /* FN:    */ static_cast<bool(*)(ImGuiMouseButton)>(ImGui::IsMouseDoubleClicked),
               /* PARAMS:*/ vc::bm_t<ImGuiMouseButton_>
        >},
        {"ImGui_IsMouseReleasedWithDelay", vc::luaw_function_wrapper<
               ImGui::IsMouseReleasedWithDelay, vc::bm_t<ImGuiMouseButton_>, float
        >},
        {"ImGui_GetMouseClickedCount", vc::luaw_function_wrapper<
               ImGui::GetMouseClickedCount, vc::bm_t<ImGuiMouseButton_>
        >},
        {"ImGui_IsMouseHoveringRect", vc::luaw_function_wrapper<
               ImGui::IsMouseHoveringRect, ImVec2, ImVec2, bool
        >},
        {"ImGui_GetMousePos", vc::luaw_function_wrapper<
               ImGui::GetMousePos
        >},
        {"ImGui_GetDisplaySize", vc::luaw_function_wrapper<
               get_display_size
        >},
        {"ImGui_GetMouseWheel", vc::luaw_function_wrapper<
               get_mouse_wheel
        >},
        {"ImGui_IsMouseDragging", vc::luaw_function_wrapper<
               ImGui::IsMouseDragging, vc::bm_t<ImGuiMouseButton_>, float
        >},
        {"ImGui_GetMouseDragDelta", vc::luaw_function_wrapper<
               ImGui::GetMouseDragDelta, vc::bm_t<ImGuiMouseButton_>, float
        >},
        {"ImGui_ResetMouseDragDelta", vc::luaw_function_wrapper<
               ImGui::ResetMouseDragDelta, vc::bm_t<ImGuiMouseButton_>
        >},
        {"ImGui_GetClipboardText", vc::luaw_function_wrapper<
               ImGui::GetClipboardText
        >},
        {"ImGui_SetClipboardText", vc::luaw_function_wrapper<
               ImGui::SetClipboardText, const char *
        >},

        /* Drawing (operate on the current window's draw list) ---------------------------------- */
        {"ImGui_SetDrawForeground", vc::luaw_function_wrapper<
               /* FN:    */ set_draw_foreground, bool
        >},
        {"ImGui_AddLine", vc::luaw_function_wrapper<
               add_line, ImVec2, ImVec2, uint32_t, float
        >},
        {"ImGui_AddRect", vc::luaw_function_wrapper<
               add_rect, ImVec2, ImVec2, uint32_t, float, float
        >},
        {"ImGui_AddRectFilled", vc::luaw_function_wrapper<
               add_rect_filled, ImVec2, ImVec2, uint32_t, float
        >},
        {"ImGui_AddCircle", vc::luaw_function_wrapper<
               add_circle, ImVec2, float, uint32_t, float
        >},
        {"ImGui_AddCircleFilled", vc::luaw_function_wrapper<
               add_circle_filled, ImVec2, float, uint32_t
        >},
        {"ImGui_AddArc", vc::luaw_function_wrapper<
               add_arc, ImVec2, float, uint32_t, float, float, float
        >},
        {"ImGui_AddTriangle", vc::luaw_function_wrapper<
               add_triangle, ImVec2, ImVec2, ImVec2, uint32_t, float
        >},
        {"ImGui_AddTriangleFilled", vc::luaw_function_wrapper<
               add_triangle_filled, ImVec2, ImVec2, ImVec2, uint32_t
        >},
        {"ImGui_AddQuad", vc::luaw_function_wrapper<
               add_quad, ImVec2, ImVec2, ImVec2, ImVec2, uint32_t, float
        >},
        {"ImGui_AddQuadFilled", vc::luaw_function_wrapper<
               add_quad_filled, ImVec2, ImVec2, ImVec2, ImVec2, uint32_t
        >},
        {"ImGui_AddImageQuad", vc::luaw_function_wrapper<
               add_image_quad, double, ImVec2, ImVec2, ImVec2, ImVec2,
                               ImVec2, ImVec2, ImVec2, ImVec2, uint32_t
        >},
        {"ImGui_AddText", vc::luaw_function_wrapper<
               add_text, ImVec2, uint32_t, const char *
        >},
    };

    ASSERT_FN(add_lua_tab_funcs(vs, imgui_tab_funcs));

    vc::add_lua_flag_mapping(vs, vc::imgui_key_from_str);
    /* Added 2026-09-07 alongside the widget/table block, so Lua writes
     * vc.ImGuiTableFlags_Borders rather than a magic integer into ImGui_BeginTable(). Same
     * one-table-backs-both pattern the key map already uses. */
    vc::add_lua_flag_mapping(vs, vc::imgui_table_flags_from_str);
    vc::add_lua_flag_mapping(vs, vc::imgui_table_col_flags_from_str);
    vc::add_lua_flag_mapping(vs, vc::imgui_child_flags_from_str);
    vc::add_lua_flag_mapping(vs, vc::imgui_selectable_flags_from_str);
    vc::add_lua_flag_mapping(vs, vc::imgui_mousebtn_from_str);

    return vc::VC_ERROR_OK;
}

} /* namespace imgui_composer */

namespace virt_composer {

inline std::unordered_map<std::string, ImGuiTableFlags_> imgui_table_flags_from_str = {
    { "ImGuiTableFlags_None",             ImGuiTableFlags_None },
    { "ImGuiTableFlags_Resizable",        ImGuiTableFlags_Resizable },
    { "ImGuiTableFlags_RowBg",            ImGuiTableFlags_RowBg },
    { "ImGuiTableFlags_Borders",          ImGuiTableFlags_Borders },
    { "ImGuiTableFlags_BordersInnerV",    ImGuiTableFlags_BordersInnerV },
    { "ImGuiTableFlags_BordersOuter",     ImGuiTableFlags_BordersOuter },
    { "ImGuiTableFlags_ScrollY",          ImGuiTableFlags_ScrollY },
    { "ImGuiTableFlags_SizingFixedFit",   ImGuiTableFlags_SizingFixedFit },
    { "ImGuiTableFlags_SizingStretchProp",ImGuiTableFlags_SizingStretchProp },
};

inline std::unordered_map<std::string, ImGuiTableColumnFlags_> imgui_table_col_flags_from_str = {
    { "ImGuiTableColumnFlags_None",         ImGuiTableColumnFlags_None },
    { "ImGuiTableColumnFlags_WidthFixed",   ImGuiTableColumnFlags_WidthFixed },
    { "ImGuiTableColumnFlags_WidthStretch", ImGuiTableColumnFlags_WidthStretch },
    { "ImGuiTableColumnFlags_NoResize",     ImGuiTableColumnFlags_NoResize },
};

inline std::unordered_map<std::string, ImGuiChildFlags_> imgui_child_flags_from_str = {
    { "ImGuiChildFlags_None",    ImGuiChildFlags_None },
    { "ImGuiChildFlags_Borders", ImGuiChildFlags_Borders },
};

inline std::unordered_map<std::string, ImGuiSelectableFlags_> imgui_selectable_flags_from_str = {
    { "ImGuiSelectableFlags_None",           ImGuiSelectableFlags_None },
    { "ImGuiSelectableFlags_SpanAllColumns", ImGuiSelectableFlags_SpanAllColumns },
    { "ImGuiSelectableFlags_AllowDoubleClick", ImGuiSelectableFlags_AllowDoubleClick },
};

inline std::unordered_map<std::string, ImGuiKey> imgui_key_from_str = {
    { "ImGuiKey_None", ImGuiKey_None },
    { "ImGuiKey_NamedKey_BEGIN", ImGuiKey_NamedKey_BEGIN },
    { "ImGuiKey_Tab", ImGuiKey_Tab },
    { "ImGuiKey_LeftArrow", ImGuiKey_LeftArrow },
    { "ImGuiKey_RightArrow", ImGuiKey_RightArrow },
    { "ImGuiKey_UpArrow", ImGuiKey_UpArrow },
    { "ImGuiKey_DownArrow", ImGuiKey_DownArrow },
    { "ImGuiKey_PageUp", ImGuiKey_PageUp },
    { "ImGuiKey_PageDown", ImGuiKey_PageDown },
    { "ImGuiKey_Home", ImGuiKey_Home },
    { "ImGuiKey_End", ImGuiKey_End },
    { "ImGuiKey_Insert", ImGuiKey_Insert },
    { "ImGuiKey_Delete", ImGuiKey_Delete },
    { "ImGuiKey_Backspace", ImGuiKey_Backspace },
    { "ImGuiKey_Space", ImGuiKey_Space },
    { "ImGuiKey_Enter", ImGuiKey_Enter },
    { "ImGuiKey_Escape", ImGuiKey_Escape },
    { "ImGuiKey_LeftCtrl", ImGuiKey_LeftCtrl },
    { "ImGuiKey_LeftShift", ImGuiKey_LeftShift },
    { "ImGuiKey_LeftAlt", ImGuiKey_LeftAlt },
    { "ImGuiKey_LeftSuper", ImGuiKey_LeftSuper },
    { "ImGuiKey_RightCtrl", ImGuiKey_RightCtrl },
    { "ImGuiKey_RightShift", ImGuiKey_RightShift },
    { "ImGuiKey_RightAlt", ImGuiKey_RightAlt },
    { "ImGuiKey_RightSuper", ImGuiKey_RightSuper },
    { "ImGuiKey_Menu", ImGuiKey_Menu },
    { "ImGuiKey_0", ImGuiKey_0 },
    { "ImGuiKey_1", ImGuiKey_1 },
    { "ImGuiKey_2", ImGuiKey_2 },
    { "ImGuiKey_3", ImGuiKey_3 },
    { "ImGuiKey_4", ImGuiKey_4 },
    { "ImGuiKey_5", ImGuiKey_5 },
    { "ImGuiKey_6", ImGuiKey_6 },
    { "ImGuiKey_7", ImGuiKey_7 },
    { "ImGuiKey_8", ImGuiKey_8 },
    { "ImGuiKey_9", ImGuiKey_9 },
    { "ImGuiKey_A", ImGuiKey_A },
    { "ImGuiKey_B", ImGuiKey_B },
    { "ImGuiKey_C", ImGuiKey_C },
    { "ImGuiKey_D", ImGuiKey_D },
    { "ImGuiKey_E", ImGuiKey_E },
    { "ImGuiKey_F", ImGuiKey_F },
    { "ImGuiKey_G", ImGuiKey_G },
    { "ImGuiKey_H", ImGuiKey_H },
    { "ImGuiKey_I", ImGuiKey_I },
    { "ImGuiKey_J", ImGuiKey_J },
    { "ImGuiKey_K", ImGuiKey_K },
    { "ImGuiKey_L", ImGuiKey_L },
    { "ImGuiKey_M", ImGuiKey_M },
    { "ImGuiKey_N", ImGuiKey_N },
    { "ImGuiKey_O", ImGuiKey_O },
    { "ImGuiKey_P", ImGuiKey_P },
    { "ImGuiKey_Q", ImGuiKey_Q },
    { "ImGuiKey_R", ImGuiKey_R },
    { "ImGuiKey_S", ImGuiKey_S },
    { "ImGuiKey_T", ImGuiKey_T },
    { "ImGuiKey_U", ImGuiKey_U },
    { "ImGuiKey_V", ImGuiKey_V },
    { "ImGuiKey_W", ImGuiKey_W },
    { "ImGuiKey_X", ImGuiKey_X },
    { "ImGuiKey_Y", ImGuiKey_Y },
    { "ImGuiKey_Z", ImGuiKey_Z },
    { "ImGuiKey_F1", ImGuiKey_F1 },
    { "ImGuiKey_F2", ImGuiKey_F2 },
    { "ImGuiKey_F3", ImGuiKey_F3 },
    { "ImGuiKey_F4", ImGuiKey_F4 },
    { "ImGuiKey_F5", ImGuiKey_F5 },
    { "ImGuiKey_F6", ImGuiKey_F6 },
    { "ImGuiKey_F7", ImGuiKey_F7 },
    { "ImGuiKey_F8", ImGuiKey_F8 },
    { "ImGuiKey_F9", ImGuiKey_F9 },
    { "ImGuiKey_F10", ImGuiKey_F10 },
    { "ImGuiKey_F11", ImGuiKey_F11 },
    { "ImGuiKey_F12", ImGuiKey_F12 },
    { "ImGuiKey_F13", ImGuiKey_F13 },
    { "ImGuiKey_F14", ImGuiKey_F14 },
    { "ImGuiKey_F15", ImGuiKey_F15 },
    { "ImGuiKey_F16", ImGuiKey_F16 },
    { "ImGuiKey_F17", ImGuiKey_F17 },
    { "ImGuiKey_F18", ImGuiKey_F18 },
    { "ImGuiKey_F19", ImGuiKey_F19 },
    { "ImGuiKey_F20", ImGuiKey_F20 },
    { "ImGuiKey_F21", ImGuiKey_F21 },
    { "ImGuiKey_F22", ImGuiKey_F22 },
    { "ImGuiKey_F23", ImGuiKey_F23 },
    { "ImGuiKey_F24", ImGuiKey_F24 },
    { "ImGuiKey_Apostrophe", ImGuiKey_Apostrophe },
    { "ImGuiKey_Comma", ImGuiKey_Comma },
    { "ImGuiKey_Minus", ImGuiKey_Minus },
    { "ImGuiKey_Period", ImGuiKey_Period },
    { "ImGuiKey_Slash", ImGuiKey_Slash },
    { "ImGuiKey_Semicolon", ImGuiKey_Semicolon },
    { "ImGuiKey_Equal", ImGuiKey_Equal },
    { "ImGuiKey_LeftBracket", ImGuiKey_LeftBracket },
    { "ImGuiKey_Backslash", ImGuiKey_Backslash },
    { "ImGuiKey_RightBracket", ImGuiKey_RightBracket },
    { "ImGuiKey_GraveAccent", ImGuiKey_GraveAccent },
    { "ImGuiKey_CapsLock", ImGuiKey_CapsLock },
    { "ImGuiKey_ScrollLock", ImGuiKey_ScrollLock },
    { "ImGuiKey_NumLock", ImGuiKey_NumLock },
    { "ImGuiKey_PrintScreen", ImGuiKey_PrintScreen },
    { "ImGuiKey_Pause", ImGuiKey_Pause },
    { "ImGuiKey_Keypad0", ImGuiKey_Keypad0 },
    { "ImGuiKey_Keypad1", ImGuiKey_Keypad1 },
    { "ImGuiKey_Keypad2", ImGuiKey_Keypad2 },
    { "ImGuiKey_Keypad3", ImGuiKey_Keypad3 },
    { "ImGuiKey_Keypad4", ImGuiKey_Keypad4 },
    { "ImGuiKey_Keypad5", ImGuiKey_Keypad5 },
    { "ImGuiKey_Keypad6", ImGuiKey_Keypad6 },
    { "ImGuiKey_Keypad7", ImGuiKey_Keypad7 },
    { "ImGuiKey_Keypad8", ImGuiKey_Keypad8 },
    { "ImGuiKey_Keypad9", ImGuiKey_Keypad9 },
    { "ImGuiKey_KeypadDecimal", ImGuiKey_KeypadDecimal },
    { "ImGuiKey_KeypadDivide", ImGuiKey_KeypadDivide },
    { "ImGuiKey_KeypadMultiply", ImGuiKey_KeypadMultiply },
    { "ImGuiKey_KeypadSubtract", ImGuiKey_KeypadSubtract },
    { "ImGuiKey_KeypadAdd", ImGuiKey_KeypadAdd },
    { "ImGuiKey_KeypadEnter", ImGuiKey_KeypadEnter },
    { "ImGuiKey_KeypadEqual", ImGuiKey_KeypadEqual },
    { "ImGuiKey_AppBack", ImGuiKey_AppBack },
    { "ImGuiKey_AppForward", ImGuiKey_AppForward },
    { "ImGuiKey_Oem102", ImGuiKey_Oem102 },
    { "ImGuiKey_GamepadStart", ImGuiKey_GamepadStart },
    { "ImGuiKey_GamepadBack", ImGuiKey_GamepadBack },
    { "ImGuiKey_GamepadFaceLeft", ImGuiKey_GamepadFaceLeft },
    { "ImGuiKey_GamepadFaceRight", ImGuiKey_GamepadFaceRight },
    { "ImGuiKey_GamepadFaceUp", ImGuiKey_GamepadFaceUp },
    { "ImGuiKey_GamepadFaceDown", ImGuiKey_GamepadFaceDown },
    { "ImGuiKey_GamepadDpadLeft", ImGuiKey_GamepadDpadLeft },
    { "ImGuiKey_GamepadDpadRight", ImGuiKey_GamepadDpadRight },
    { "ImGuiKey_GamepadDpadUp", ImGuiKey_GamepadDpadUp },
    { "ImGuiKey_GamepadDpadDown", ImGuiKey_GamepadDpadDown },
    { "ImGuiKey_GamepadL1", ImGuiKey_GamepadL1 },
    { "ImGuiKey_GamepadR1", ImGuiKey_GamepadR1 },
    { "ImGuiKey_GamepadL2", ImGuiKey_GamepadL2 },
    { "ImGuiKey_GamepadR2", ImGuiKey_GamepadR2 },
    { "ImGuiKey_GamepadL3", ImGuiKey_GamepadL3 },
    { "ImGuiKey_GamepadR3", ImGuiKey_GamepadR3 },
    { "ImGuiKey_GamepadLStickLeft", ImGuiKey_GamepadLStickLeft },
    { "ImGuiKey_GamepadLStickRight", ImGuiKey_GamepadLStickRight },
    { "ImGuiKey_GamepadLStickUp", ImGuiKey_GamepadLStickUp },
    { "ImGuiKey_GamepadLStickDown", ImGuiKey_GamepadLStickDown },
    { "ImGuiKey_GamepadRStickLeft", ImGuiKey_GamepadRStickLeft },
    { "ImGuiKey_GamepadRStickRight", ImGuiKey_GamepadRStickRight },
    { "ImGuiKey_GamepadRStickUp", ImGuiKey_GamepadRStickUp },
    { "ImGuiKey_GamepadRStickDown", ImGuiKey_GamepadRStickDown },
    { "ImGuiKey_MouseLeft", ImGuiKey_MouseLeft },
    { "ImGuiKey_MouseRight", ImGuiKey_MouseRight },
    { "ImGuiKey_MouseMiddle", ImGuiKey_MouseMiddle },
    { "ImGuiKey_MouseX1", ImGuiKey_MouseX1 },
    { "ImGuiKey_MouseX2", ImGuiKey_MouseX2 },
    { "ImGuiKey_MouseWheelX", ImGuiKey_MouseWheelX },
    { "ImGuiKey_MouseWheelY", ImGuiKey_MouseWheelY },
    { "ImGuiKey_ReservedForModCtrl", ImGuiKey_ReservedForModCtrl },
    { "ImGuiKey_ReservedForModShift", ImGuiKey_ReservedForModShift },
    { "ImGuiKey_ReservedForModAlt", ImGuiKey_ReservedForModAlt },
    { "ImGuiKey_ReservedForModSuper", ImGuiKey_ReservedForModSuper },
    { "ImGuiKey_NamedKey_END", ImGuiKey_NamedKey_END },
    { "ImGuiKey_NamedKey_COUNT", ImGuiKey_NamedKey_COUNT },
    { "ImGuiMod_None", ImGuiMod_None },
    { "ImGuiMod_Ctrl", ImGuiMod_Ctrl },
    { "ImGuiMod_Shift", ImGuiMod_Shift },
    { "ImGuiMod_Alt", ImGuiMod_Alt },
    { "ImGuiMod_Super", ImGuiMod_Super },
    { "ImGuiMod_Mask_", ImGuiMod_Mask_ },
};

template <> inline ImGuiKey get_enum_val<ImGuiKey>(fkyaml::node &n) {
    return get_enum_val(n, imgui_key_from_str);
}

inline std::unordered_map<std::string, ImGuiMouseButton_> imgui_mousebtn_from_str = {
    { "ImGuiMouseButton_Left", ImGuiMouseButton_Left },
    { "ImGuiMouseButton_Right", ImGuiMouseButton_Right },
    { "ImGuiMouseButton_Middle", ImGuiMouseButton_Middle },
};

template <> inline ImGuiMouseButton_ get_enum_val<ImGuiMouseButton_>(fkyaml::node &n) {
    return get_enum_val(n, imgui_mousebtn_from_str);
}


} /* namespace virt_composer */

#endif
