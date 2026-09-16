#ifndef APP_COMPOSER_H
#define APP_COMPOSER_H

/*! app_composer.h - the few things a flying camera needs from the window that ImGui does not offer:
 * an unbounded mouse, and a way to ask for the process to stop.
 *
 * Core: ImGui reports the cursor, and a cursor stops at the edge of the screen. A first-person view
 * needs a mouse that keeps moving after that, so capturing the pointer has to be asked of GLFW
 * directly - ImGui has no call for it, and imgui_composer.h is a leaf over ImGui alone. This file
 * is the counterpart leaf over the window.
 *
 * Everything else about the camera stays in Lua. This layer answers "how far did the mouse move
 * since you last asked"; what that means for yaw and pitch, and how fast, is a script's business.
 *
 * @date 2026-09-16 */

#include "virt_composer.h"
#include "imgui_helpers.h"

#include <tuple>

namespace app_composer {

namespace vc = virt_composer;
namespace appc = app_composer;

/*! The capture state, and the cursor position the last delta was measured from.
 *
 * `have_last` guards the first frame after capture begins: the cursor jumps to wherever GLFW parks
 * it when the pointer is hidden, and reporting that jump as mouse movement would spin the view
 * once, hard, every time the user pressed the capture key.
 * @date 2026-09-16 */
struct app_state_t {
    bool captured = false;
    bool have_last = false;
    double last_x = 0, last_y = 0;
    bool quit_asked = false;
};

inline app_state_t g_app;

/*! Hides the pointer and lets it travel without bound, or gives it back.
 *
 * GLFW_CURSOR_DISABLED is what makes the movement unbounded; the cursor stops existing as a screen
 * position and glfwGetCursorPos starts reporting an ever-growing virtual one, which is exactly what
 * mouse_delta() below wants.
 * @date 2026-09-16 */
inline void mouse_capture(bool on) {
    if (!imgui_window)
        return;
    appc::g_app.captured = on;
    appc::g_app.have_last = false;
    glfwSetInputMode(imgui_window, GLFW_CURSOR, on ? GLFW_CURSOR_DISABLED : GLFW_CURSOR_NORMAL);
}

/*! Is the pointer currently captured? @date 2026-09-16 */
inline bool mouse_captured() { return appc::g_app.captured; }

/*! How far the pointer has moved since this was last called, in pixels, as a two element table.
 *
 * Answers zero when nothing is captured, and zero on the first call after capture begins - see
 * `have_last` above. Reading it is what resets it, so exactly one caller per frame should ask.
 * @date 2026-09-16 */
inline std::tuple<double, double> mouse_delta() {
    app_state_t &a = appc::g_app;
    if (!a.captured || !imgui_window)
        return {0.0, 0.0};

    double x = 0, y = 0;
    glfwGetCursorPos(imgui_window, &x, &y);

    if (!a.have_last) {
        a.last_x = x;
        a.last_y = y;
        a.have_last = true;
        return {0.0, 0.0};
    }

    double dx = x - a.last_x;
    double dy = y - a.last_y;
    a.last_x = x;
    a.last_y = y;
    return {dx, dy};
}

/*! Asks the frame loop to stop after this frame. The loop is what actually leaves, so the shutdown
 * Lua does on the way out still runs. @date 2026-09-16 */
inline void app_quit() { appc::g_app.quit_asked = true; }

/*! Has a quit been asked for? Read by main.cpp, not by scripts. @date 2026-09-16 */
inline bool app_quit_asked() { return appc::g_app.quit_asked; }

/*! Seconds since GLFW was initialised - the clock a script paces movement with.
 * @date 2026-09-16 */
inline double app_time() { return glfwGetTime(); }

/*! Puts the four calls above on the vc table. @date 2026-09-16 */
inline int register_meta(vc::virt_state_t *vs) {
    DBG_SCOPE();

    std::vector<luaL_Reg> app_tab_funcs = {
        {"mouse_capture", vc::luaw_function_wrapper<
               /* FN:    */ appc::mouse_capture,
               /* PARAMS:*/ bool
        >},
        {"mouse_captured", vc::luaw_function_wrapper<
               /* FN:    */ appc::mouse_captured
        >},
        {"mouse_delta", vc::luaw_function_wrapper<
               /* FN:    */ appc::mouse_delta
        >},
        {"app_quit", vc::luaw_function_wrapper<
               /* FN:    */ appc::app_quit
        >},
        {"app_time", vc::luaw_function_wrapper<
               /* FN:    */ appc::app_time
        >},
    };

    ASSERT_FN(add_lua_tab_funcs(vs, app_tab_funcs));

    return vc::VC_ERROR_OK;
}

} /* namespace app_composer */

#endif /* APP_COMPOSER_H */
