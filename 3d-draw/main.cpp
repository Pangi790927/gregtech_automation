/*! main.cpp - 3d-draw's program: open a window, build the Lua state, and run the frame loop that
 * hands each frame to scripts/main.lua.
 *
 * Core: the robots' world, plans and control, laid out as math_writer is (the user, 2026-10-05,
 * 3d-draw/redesign/06-pc.md): this file owns almost nothing. It registers the composers onto a
 * virt_composer state and calls three Lua globals - test_init, test_draw and test_shutdown - as
 * the simulator's main.cpp does, whose shape this is. The composers are the simulator's own
 * headers, included as they are and never copied (simulator/render_composer.h and its
 * neighbours); what 3d-draw adds of its own comes as composers beside this file.
 *
 * The frame is drawn in a fixed order for the reason the simulator's main.cpp gives: clear both
 * buffers, let Lua draw the world into them, then put ImGui's draw data on top - imgui_render()
 * clears only the colour buffer, which would leave the world painted over by its own last frame.
 *
 * `--test` runs the testing instance: 3d-draw_test.yaml's script, its `sim_test()`, no frame loop,
 * and an exit code (app_mode.h keeps its files under test_run/).
 *
 * @date 2026-10-05 */

#define NOMINMAX
#define IMGUI_DEFINE_MATH_OPERATORS

/* GLFW must not drag in the system OpenGL headers: every GL declaration comes from ImGui's
embedded loader instead (the simulator's main.cpp says why). */
#define GLFW_INCLUDE_NONE

#include <cstdio>
#include <cstring>
#include <filesystem>
#include <string>

#include "imgui.h"
#include "gl_util.h"          /* pulls the GL loader in, and must precede imgui_helpers.h */
#include "imgui_helpers.h"
#include "imgui_internal.h"

/* composer plugins, all the simulator's: */
#include "imgui_composer.h"
#include "app_composer.h"
#include "app_mode.h"
#include "path_composer.h"
#include "world_composer.h"
#include "render_composer.h"
#include "virt_composer_end.h"

#include "debug.h"

namespace vc = virt_composer;
namespace imgc = imgui_composer;
namespace appc = app_composer;
namespace appm = app_mode;
namespace pathc = path_composer;
namespace worldc = world_composer;
namespace renderc = render_composer;

int main(int argc, char const *argv[]) {
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--test") == 0)
            appm::set_testing(true);
        else
            printf("ignoring unknown argument: %s\n", argv[i]);
    }

    if (appm::app_is_testing()) {
        std::error_code ec;
        std::filesystem::create_directories(appm::TESTING_PREFIX, ec);
        /* A test instance never appears on screen (simulator/CLAUDE.md, "Testing"). */
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
    glfwSetWindowTitle(imgui_window, "gregtech_automation - 3d-draw");

    /* After the window: render_init() reaches into GL, whose entry points ImGui's backend loads. */
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
    ASSERT_FN(renderc::register_meta(vs.get()));
    ASSERT_FN(vc::parse_config(vs.get(),
            appm::app_is_testing() ? "3d-draw_test.yaml" : "3d-draw.yaml"));

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
        glClearColor(0.53f, 0.68f, 0.86f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

        /* A script that throws does not take the process with it: the window stays closable. */
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

    /* The state first: it holds the worlds Lua made, whose GL objects need the window alive. */
    vs.reset();
    imgui_uninit();
    return 0;
}
