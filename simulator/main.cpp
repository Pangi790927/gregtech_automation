/*! main.cpp - the simulator's entry point: open a window, build the Lua state, and run the frame
 * loop that hands each frame to scripts/main.lua.
 *
 * Core: this file owns almost nothing. It sets up GLFW and ImGui, registers the composers onto a
 * virt_composer state, and then calls three Lua globals - test_init, test_draw and test_shutdown -
 * exactly as math_writer's main.cpp does. Everything the simulator actually does happens on one
 * side or the other of that boundary: the world, the renderer and the assets in the composer
 * headers, and the camera, the input and the interface in scripts/.
 *
 * The frame is drawn in a fixed order, and the order is the reason this file does its own end of
 * frame rather than calling imgui_helpers.h's imgui_render(). That helper clears only the colour
 * buffer and then immediately draws ImGui, which leaves nowhere for a 3D pass to go: the depth
 * buffer would never be cleared, and the world would be painted over. So the sequence here is
 * clear both buffers, let Lua draw the world into them, then put ImGui's own draw data on top.
 *
 * @date 2026-09-16 */

#define NOMINMAX
#define IMGUI_DEFINE_MATH_OPERATORS

/* GLFW must not drag in the system OpenGL headers: every GL declaration in this program comes from
ImGui's embedded loader instead, and having both would mean two sets of declarations for the same
functions. Defined before anything includes GLFW, which imgui_helpers.h does. */
#define GLFW_INCLUDE_NONE

#include <cstdio>
#include <cstring>
#include <string>

#include "imgui.h"
#include "gl_util.h"          /* pulls the GL loader in, and must precede imgui_helpers.h */
#include "imgui_helpers.h"
#include "imgui_internal.h"

/* composer plugins: */
#include "imgui_composer.h"
#include "app_composer.h"
#include "path_composer.h"
#include "world_composer.h"
#include "machine_composer.h"
#include "render_composer.h"
#include "virt_composer_end.h"

#include "debug.h"

namespace vc = virt_composer;
namespace imgc = imgui_composer;
namespace appc = app_composer;
namespace pathc = path_composer;
namespace worldc = world_composer;
namespace machc = machine_composer;
namespace renderc = render_composer;

int main(int argc, char const *argv[]) {
    for (int i = 1; i < argc; i++)
        printf("ignoring unknown argument: %s\n", argv[i]);

    logger_init("logfile");

    if (imgui_init() < 0) {
        DBG("could not open a window");
        return -1;
    }
    ImGui::GetIO().IniFilename = "imgui.ini";
    glfwSetWindowTitle(imgui_window, "gregtech_automation - opencomputers simulator");

    /* The Lua state is built after the window, because render_init() below reaches straight into GL
    and every entry point it uses is loaded by ImGui's backend during imgui_init(). */
    auto vs = vc::create_state();
    if (!vs) {
        DBG("could not create the lua state");
        imgui_uninit();
        return -1;
    }

    ASSERT_FN(imgc::register_meta(vs.get()));
    ASSERT_FN(appc::register_meta(vs.get()));
    ASSERT_FN(pathc::register_meta(vs.get()));
    ASSERT_FN(worldc::register_meta(vs.get()));
    ASSERT_FN(machc::register_meta(vs.get()));
    ASSERT_FN(renderc::register_meta(vs.get()));
    ASSERT_FN(vc::parse_config(vs.get(), "simulator.yaml"));

    {
        auto [ret, err] = vc::call_lua<int>(vs.get(), "test_init");
        if (err != vc::VC_ERROR_OK)
            DBG("test_init failed: ret %d err %d", ret, (int)err);
    }

    while (true) {
        if (!imgui_prepare_render())
            break;
        if (appc::app_quit_asked())
            break;

        int fb_w = 0, fb_h = 0;
        glfwGetFramebufferSize(imgui_window, &fb_w, &fb_h);
        glViewport(0, 0, fb_w, fb_h);

        /* A flat daylight sky. The depth buffer goes with it - see this file's header for why that
        cannot be left to imgui_render(). */
        glClearColor(0.53f, 0.68f, 0.86f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

        /* One frame of the application: the script reads input, moves the camera, draws the world
        through vc.render_world() and builds whatever interface it wants. A script that throws does
        not take the process with it - the loop keeps running, so the window stays closable and a
        reload is still possible while the error is on screen. */
        auto [ret, err] = vc::call_lua<int>(vs.get(), "test_draw");
        if (err != vc::VC_ERROR_OK)
            DBG("test_draw failed: ret %d err %d", ret, (int)err);

        ImGui::Render();
        ImGui_ImplOpenGL3_RenderDrawData(ImGui::GetDrawData());
        glfwSwapBuffers(imgui_window);
    }

    {
        auto [ret, err] = vc::call_lua<int>(vs.get(), "test_shutdown");
        if (err != vc::VC_ERROR_OK)
            DBG("test_shutdown failed: ret %d err %d", ret, (int)err);
    }

    /* The state goes first. It holds the only references to the worlds and cells Lua made, and
    closing the lua_State is what releases them; doing it before the window closes keeps any GL
    object a destructor might touch still valid. */
    vs.reset();
    imgui_uninit();
    return 0;
}
