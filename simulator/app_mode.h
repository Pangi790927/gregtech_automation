#ifndef APP_MODE_H
#define APP_MODE_H

/*! app_mode.h - which of the two instances this process is, and where its files live.
 *
 * Two modes, chosen by argv (main.cpp):
 *
 *   PRESENTATION (no arguments) - the real simulator, the one a person runs. A window, a frame
 *       loop that keeps going until it is closed, and files where they have always been:
 *       world.save, disks.save, settings.save.
 *
 *   TESTING ("--test") - the one an automated session drives. No frame loop at all: the test script
 *       runs, says what happened, and the process exits. Every file it touches moves under
 *       test_run/.
 *
 * Both halves of that exist because of a specific failure. The separation of FILES is math_writer's
 * reasoning and it applies here word for word - a test that boots a machine and types into it will
 * happily overwrite a real world and a real hard disk, and a save containing a hundred and eighty
 * files of operating system is not something to be rescuing from git. The separation of MODE is the
 * other half: a test written into the application's own startup left the simulator running
 * afterwards with a blank window, because running is what an application does, and then closed it -
 * which looked exactly like the application being broken.
 *
 * Separation is by PREFIX rather than by per-file flags: one directory to delete, one to ignore,
 * and a data file added later is separated automatically as long as it goes through
 * app_data_prefix(). Lua concatenates the paths itself - which file lives where belongs to the Lua
 * that owns it, not here.
 *
 * @date 2026-09-17 */

#include "virt_composer.h"

#include <string>

namespace app_mode {

namespace vc = virt_composer;
namespace appm = app_mode;

inline bool g_testing = false;

/*! The scenario being run, or empty for none. Set by `--scene <folder>`.
 *
 * A SCENE IS A SAVE WITH A SCRIPT ON TOP. The folder holds the same things a save directory does -
 * the map, the settings, the hard disks - and beside them a `scene.lua` naming the positions the
 * scenario cares about and a `controller.lua`, the invisible hand that works the world while the
 * program under test runs. Pointing the data prefix at it is what makes all the existing saving
 * and loading work on a scene without knowing anything about scenes.
 * @date 2026-09-17 */
inline std::string g_scene_dir;

/*! Everything the testing instance writes goes under here. The trailing slash is included so a
 * caller can concatenate without knowing which mode it is in. @date 2026-09-17 */
inline const char *TESTING_PREFIX = "test_run/";

inline void set_testing(bool on) { g_testing = on; }

/*! Points the simulator at a scenario folder. @date 2026-09-17 */
inline void set_scene_dir(const std::string &dir) { g_scene_dir = dir; }

/*! The scenario folder, with a trailing slash, or empty when none was asked for.
 * @date 2026-09-17 */
inline std::string app_scene_dir() {
    if (g_scene_dir.empty())
        return {};
    std::string out = g_scene_dir;
    if (out.back() != '/' && out.back() != '\\')
        out += "/";
    return out;
}

/*! Is this the testing instance? Lua asks so a test script can refuse to run in the real one.
 * @date 2026-09-17 */
inline bool app_is_testing() { return g_testing; }

/*! "" in presentation mode, "test_run/" in testing mode. @date 2026-09-17 */
inline std::string app_data_prefix() {
    /* A scene owns its own files, so it wins: running one must not read or write the world a
    person was building by hand. The testing instance still separates itself underneath, so a test
    that loads a scene writes into the scene's test_run rather than into the scene. */
    if (!g_scene_dir.empty())
        return appm::app_scene_dir() + (g_testing ? std::string(TESTING_PREFIX) : std::string());
    return g_testing ? std::string(TESTING_PREFIX) : std::string();
}

inline int register_meta(vc::virt_state_t *vs) {
    DBG_SCOPE();

    std::vector<luaL_Reg> app_tab_funcs = {
        {"app_is_testing",  vc::luaw_function_wrapper<appm::app_is_testing>},
        {"app_data_prefix", vc::luaw_function_wrapper<appm::app_data_prefix>},
        {"app_scene_dir",   vc::luaw_function_wrapper<appm::app_scene_dir>},
    };

    ASSERT_FN(add_lua_tab_funcs(vs, app_tab_funcs));

    return vc::VC_ERROR_OK;
}

} /* namespace app_mode */

#endif /* APP_MODE_H */
