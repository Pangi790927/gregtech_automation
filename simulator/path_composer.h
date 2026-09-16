#ifndef PATH_COMPOSER_H
#define PATH_COMPOSER_H

#include "virt_composer.h"
#include "path_utils.h"

#include <algorithm>
#include <string>
#include <vector>

/*! path_composer.h - forwards ../utils/path_utils.h's filesystem queries to Lua.
 *
 * Core: Lua's standard library cannot enumerate a directory. `io.open` opens a FILE and gives back
 * a stream; there is no readdir and no glob anywhere in the stdlib, which is why LuaFileSystem
 * exists as a separate C library. `io.popen` is present (VIRT_COMPOSER_ENABLE_LUA_IO opens the
 * whole io library) and could shell out, but that spawns a console - a thing this application has
 * already been burned by once - and needs a different command string per platform. So the listing
 * comes from C++, where path_utils::list_dir already did it for both platforms.
 *
 * A LEAF, in the same sense imgui_composer.h is: it exposes an existing lower layer and nothing
 * depends on its shape. It computes nothing of its own except the normalisation below.
 *
 * Detail: everything here resolves APP-LOCAL rather than cwd-local, through
 * path_get_relative() - so a script asking for "scripts" gets the scripts directory beside the
 * executable no matter where the process was launched from. An absolute path is passed through
 * untouched.
 *
 * @date 2026-09-12 01:40 */

namespace path_composer {

namespace vc = virt_composer;
namespace pathc = path_composer;

/*! Every entry of `dirname`, as bare names, sorted.
 *
 * Core: the listing Lua gets is the same on both platforms - names only, no "." and no "..", in a
 * fixed order. `dirname` is resolved app-local, so "scripts" means the one beside the executable.
 *
 * SORTED BECAUSE ORDER IS MEANING TO A CALLER. The first use of this is finding transform_*.lua
 * plugins, and the order they load is the order they appear in a menu. Linux's readdir hands back
 * whatever order the filesystem stored them in, which is stable for nobody, so a directory that
 * listed one way on the developer's machine would list another way elsewhere.
 *
 * Detail - THE NORMALISATION, and why it is here rather than in path_utils.h. list_dir() answers
 * differently per platform: the Windows branch builds entry.path().string(), which is the full
 * path, while the Linux branch pushes ent->d_name, which is the bare name, and includes "." and
 * ".." because readdir does. Straightening that in path_utils.h would change what every other
 * consumer of that shared header already receives, and this file does not know who those are. So
 * the adjustment is made at this boundary, where the only thing affected is what Lua sees. If the
 * discrepancy is ever fixed at the source, the trimming below becomes a no-op rather than a
 * conflict.
 *
 * Params: `dirname` - a path relative to the executable's directory, or an absolute one.
 * Returns the entry names; empty when the directory does not exist or cannot be read. A missing
 * directory is not an error here - a caller asking "what plugins are there" wants an empty list,
 * not an exception.
 *
 * @date 2026-09-12 01:40 */
inline std::vector<std::string> list_dir(const char *dirname) {
    std::vector<std::string> out;
    if (!dirname)
        return out;

    /* Errors are swallowed on purpose: std::filesystem::directory_iterator THROWS on a missing
     * directory, while the Linux branch returns {} for the same case. Catching here is what makes
     * the two agree, and what keeps a typo in a Lua path from taking the application down. */
    std::vector<std::string> raw;
    try {
        raw = ::list_dir(path_get_relative(dirname));
    }
    catch (...) {
        return out;
    }

    for (auto &entry : raw) {
        std::string name = path_get_name(entry);
        if (name.empty() || name == "." || name == "..")
            continue;
        out.push_back(name);
    }
    std::sort(out.begin(), out.end());
    return out;
}

/*! The directory the executable sits in, with its trailing separator.
 *
 * Core: what every relative path above is resolved against. Exposed so a script that has to build a
 * path for something else - a log, a save - uses the same anchor this file does instead of assuming
 * the working directory is the app's.
 * @date 2026-09-12 01:40 */
inline std::string module_dir() {
    return path_get_module_dir();
}

/*! Resolves one app-local path to an absolute one, the same way list_dir resolves its argument.
 *
 * Core: the conversion itself, so Lua can hand the result to io.open - which is cwd-relative and
 * knows nothing about where the executable lives. An absolute path in is the same path out.
 * @date 2026-09-12 01:40 */
inline std::string resolve(const char *path) {
    return path ? path_get_relative(path) : path_get_module_dir();
}

/*! Registers the three calls above on the vc table as path_list_dir, path_module_dir and
 * path_resolve. Named with a prefix rather than nested, because that is how every other composer
 * here puts its functions on the one shared table.
 * @date 2026-09-12 01:40 */
inline int register_meta(vc::virt_state_t *vs) {
    DBG_SCOPE();

    std::vector<luaL_Reg> path_tab_funcs = {
        {"path_list_dir", vc::luaw_function_wrapper<
               /* FN:    */ pathc::list_dir,
               /* PARAMS:*/ const char *
        >},
        {"path_module_dir", vc::luaw_function_wrapper<
               /* FN:    */ pathc::module_dir
        >},
        {"path_resolve", vc::luaw_function_wrapper<
               /* FN:    */ pathc::resolve,
               /* PARAMS:*/ const char *
        >},
    };

    ASSERT_FN(add_lua_tab_funcs(vs, path_tab_funcs));

    return vc::VC_ERROR_OK;
}

} /* namespace path_composer */

#endif /* PATH_COMPOSER_H */
