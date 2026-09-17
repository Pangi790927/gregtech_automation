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
#include <filesystem>
#include <string>

#include "imgui.h"
#include "gl_util.h"          /* pulls the GL loader in, and must precede imgui_helpers.h */
#include "imgui_helpers.h"
#include "imgui_internal.h"

/* composer plugins: */
#include "imgui_composer.h"
#include "app_composer.h"
#include "app_mode.h"
#include "path_composer.h"
#include "world_composer.h"
#include "machine_composer.h"
#include "render_composer.h"
#include "virt_composer_end.h"

#include "debug.h"

namespace vc = virt_composer;
namespace imgc = imgui_composer;
namespace appc = app_composer;
namespace appm = app_mode;
namespace pathc = path_composer;
namespace worldc = world_composer;
namespace machc = machine_composer;
namespace renderc = render_composer;

int main(int argc, char const *argv[]) {
    /*! --test picks the testing instance: its own files, its own script, and no frame loop.
     *
     * Read before anything else, because the logger and the window both want to know. */
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--test") == 0) {
            appm::set_testing(true);
        }
        else if (strcmp(argv[i], "--scene") == 0 && i + 1 < argc) {
            /* A scenario: its own map, its own disks, and a controller script that works the
            world while the program under test runs. See app_mode.h. */
            appm::set_scene_dir(argv[++i]);
        }
        else {
            printf("ignoring unknown argument: %s\n", argv[i]);
        }
    }

    if (!appm::app_scene_dir().empty()) {
        std::error_code ec;
        std::filesystem::create_directories(appm::app_scene_dir(), ec);
        printf("scene: %s\n", appm::app_scene_dir().c_str());
    }

    if (appm::app_is_testing()) {
        std::error_code ec;
        std::filesystem::create_directories(appm::TESTING_PREFIX, ec);
        /* A test instance must never appear on screen. The env vars are what imgui_helpers.h
        reads; setting them here means a test cannot flash a window because a launcher forgot. */
#if defined(_WIN32)
        if (!getenv("VC_WINDOW_START_HIDDEN")) _putenv_s("VC_WINDOW_START_HIDDEN", "1");
#else
        setenv("VC_WINDOW_START_HIDDEN", "1", 0);
#endif
    }

    logger_init((appm::app_data_prefix() + "logfile").c_str());

    if (imgui_init() < 0) {
        DBG("could not open a window");
        return -1;
    }
    static std::string ini_path = appm::app_data_prefix() + "imgui.ini";
    ImGui::GetIO().IniFilename = ini_path.c_str();
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
    ASSERT_FN(appm::register_meta(vs.get()));
    ASSERT_FN(pathc::register_meta(vs.get()));
    ASSERT_FN(worldc::register_meta(vs.get()));
    ASSERT_FN(machc::register_meta(vs.get()));
    ASSERT_FN(renderc::register_meta(vs.get()));
    /* The testing instance loads its own entry script, so the real one is never even parsed under
    --test - a test cannot accidentally run the application. */
    ASSERT_FN(vc::parse_config(vs.get(),
            appm::app_is_testing() ? "simulator_test.yaml" : "simulator.yaml"));

    /*! The testing instance runs `sim_test()` and stops. It never calls test_init, so it cannot
     *  load the real world by accident, and it never enters the frame loop, so it cannot sit there
     *  afterwards waiting to be closed. */
    if (appm::app_is_testing()) {
        auto [ret, err] = vc::call_lua<int>(vs.get(), "sim_test");
        bool ok = (err == vc::VC_ERROR_OK && ret == 0);
        if (!ok)
            DBG("sim_test failed: ret %d err %d", ret, (int)err);
        printf(ok ? "TEST PASSED\n" : "TEST FAILED (see test_run/logfile.log)\n");
        vs.reset();
        imgui_uninit();
        return ok ? 0 : 1;
    }

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
