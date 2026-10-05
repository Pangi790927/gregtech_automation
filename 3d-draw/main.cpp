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
 * THE POOL IS THE MAIN LOOP (the user, 2026-10-05: "simply redesign it to be pool centric? the
 * drawing can be made in bursts those are cheap anyway"). colib's pool runs on this thread; a frame
 * is one task drawn in a burst, then it sleeps on the pool until the next is due, and in
 * between the pool runs everything else: the Lua coroutines that talk to the robots
 * (net_composer.h), their waits, their timers. Nothing blocks: a wait in Lua suspends that script
 * only.
 *
 * @date 2026-10-05 */

#define NOMINMAX
#define IMGUI_DEFINE_MATH_OPERATORS

/* GLFW must not drag in the system OpenGL headers: every GL declaration comes from ImGui's
embedded loader instead (the simulator's main.cpp says why). */
#define GLFW_INCLUDE_NONE

#include <chrono>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <string>

#include "imgui.h"
#include "gl_util.h"          /* pulls the GL loader in, and must precede imgui_helpers.h */
#include "imgui_helpers.h"
#include "imgui_internal.h"

/* composer plugins, the simulator's, then 3d-draw's own: */
#include "virt_composer.h"
#include "virt_composer_coroutines.h"
#include "imgui_composer.h"
#include "app_composer.h"
#include "app_mode.h"
#include "path_composer.h"
#include "world_composer.h"
#include "render_composer.h"
#include "net_composer.h"
#include "route_composer.h"
#include "virt_composer_end.h"

#include "debug.h"

namespace vc = virt_composer;
namespace imgc = imgui_composer;
namespace appc = app_composer;
namespace appm = app_mode;
namespace pathc = path_composer;
namespace worldc = world_composer;
namespace renderc = render_composer;
namespace netc = net_composer;
namespace routec = route_composer;

/* A frame every FRAME_MS: the frame task sleeps on the pool for what is left of it. */
static constexpr uint64_t FRAME_MS = 16;

/*! Calls a Lua global on a coroutine of its own, so it may wait (net_composer.h), and answers its
 * integer result, or -1 when it failed. @date 2026-10-05 */
static co::task<int64_t> call_waiting(vc::virt_state_t *vs, const char *fn) {
    auto c = vc::lua_coro_t::create(vs);
    if (c->set_call(fn) != vc::VC_ERROR_OK) {
        DBG("%s: no such function", fn);
        co_return -1;
    }
    if (co_await c->run() != vc::VC_ERROR_OK) {
        DBG("%s failed", fn);
        co_return -1;
    }
    auto [ret, err] = c->result<int64_t>();
    co_return err == vc::VC_ERROR_OK ? ret : -1;
}

/*! The program's life on the pool: the test instance runs sim_test() and stops; the window runs
 * test_init(), then a frame every FRAME_MS until it is closed, then test_shutdown(). The frame
 * itself does not wait - test_draw() is called on the main state - so a Lua function that waits
 * must run on a coroutine of its own (vc.coroutine_spawn). @date 2026-10-05 */
static co::task_t app_main(vc::virt_state_t *vs) {
    if (appm::app_is_testing()) {
        int64_t ret = co_await call_waiting(vs, "sim_test");
        printf(ret == 0 ? "TEST PASSED\n" : "TEST FAILED (see test_run/logfile.log)\n");
        co_await co::force_stop(ret == 0 ? 0 : 1);
        co_return 0;
    }
    co_await call_waiting(vs, "test_init");
    while (true) {
        auto start = std::chrono::steady_clock::now();
        if (!imgui_prepare_render() || appc::app_quit_asked())
            break;

        int fb_w = 0, fb_h = 0;
        glfwGetFramebufferSize(imgui_window, &fb_w, &fb_h);
        glViewport(0, 0, fb_w, fb_h);
        glClearColor(0.53f, 0.68f, 0.86f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

        /* A script that throws does not take the process with it: the window stays closable. */
        auto [ret, err] = vc::call_lua<int>(vs, "test_draw");
        if (err != vc::VC_ERROR_OK)
            DBG("test_draw failed: ret %d err %d", ret, (int)err);

        ImGui::Render();
        ImGui_ImplOpenGL3_RenderDrawData(ImGui::GetDrawData());
        glfwSwapBuffers(imgui_window);

        auto spent = std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - start).count();
        co_await co::sleep_ms(spent >= (int64_t)FRAME_MS ? 1 : FRAME_MS - (uint64_t)spent);
    }
    co_await call_waiting(vs, "test_shutdown");
    co_await co::force_stop(0);
    co_return 0;
}

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

    ASSERT_FN(vc::coroutines_register_meta(vs.get()));
    ASSERT_FN(imgc::register_meta(vs.get()));
    ASSERT_FN(appc::register_meta(vs.get()));
    ASSERT_FN(appm::register_meta(vs.get()));
    ASSERT_FN(pathc::register_meta(vs.get()));
    ASSERT_FN(worldc::register_meta(vs.get()));
    ASSERT_FN(renderc::register_meta(vs.get()));
    ASSERT_FN(netc::register_meta(vs.get()));
    ASSERT_FN(routec::register_meta(vs.get()));
    ASSERT_FN(vc::parse_config(vs.get(),
            appm::app_is_testing() ? "3d-draw_test.yaml" : "3d-draw.yaml"));

    auto pool = vc::luaw_get_pool(vs.get());
    pool->sched(app_main(vs.get()));
    pool->run();
    int code = (int)pool->stopval;

    /* The state first: it holds the worlds Lua made, whose GL objects need the window alive. */
    vs.reset();
    imgui_uninit();
    return code;
}
