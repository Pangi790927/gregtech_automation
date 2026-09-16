#ifndef PATH_COMPOSER_H
#define PATH_COMPOSER_H

#include "virt_composer.h"
#include "path_utils.h"

#include <algorithm>
#include <filesystem>
#include <system_error>
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

/*! Is there a directory at this path?
 *
 * Core: the one thing a caller walking a saved directory cannot work out for itself. list_dir()
 * answers with bare names and says nothing about what they are, so restoring a tree of files needs
 * to be able to ask which entries to descend into.
 * @date 2026-09-17 */
inline bool is_dir(const char *path) {
    if (!path)
        return false;
    std::error_code ec;
    return std::filesystem::is_directory(path_get_relative(path), ec);
}

/*! Creates a directory and every missing parent of it, and answers whether it is there afterwards.
 *
 * Core: exposed because Lua's standard library cannot make a directory at all - io.open will not
 * create the folder a file is asked to live in, so a save laid out as a tree cannot be written
 * from Lua without this. os.execute could shell out, but that spawns a console window, which this
 * application has already been burned by once (see this file's header).
 *
 * An existing directory is a success, not an error: saving happens repeatedly over the same tree.
 * @date 2026-09-17 */
inline bool make_dirs(const char *path) {
    if (!path)
        return false;
    std::error_code ec;
    std::string full = path_get_relative(path);
    std::filesystem::create_directories(full, ec);
    return std::filesystem::is_directory(full, ec);
}

/*! Deletes a file or a whole directory tree, and answers how many entries went.
 *
 * Core: needed by saving, not by any user-facing feature. A hard disk is written out as real files
 * in a real folder, so a file the guest DELETED has to stop existing on the host too - otherwise
 * every save is a union of every state the disk has ever been in, and a removed file comes back on
 * the next load. The tree is cleared and rewritten, which is the simplest thing that cannot leave a
 * ghost behind.
 *
 * Errors are swallowed the way list_dir's are, and a missing path is zero rather than a failure.
 * @date 2026-09-17 */
inline double remove_all(const char *path) {
    if (!path)
        return 0.0;
    std::error_code ec;
    auto n = std::filesystem::remove_all(path_get_relative(path), ec);
    return ec ? 0.0 : (double)n;
}

/*! Registers the calls above on the vc table, each with a path_ prefix. Named with a prefix rather than nested, because that is how every other composer
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
        {"path_is_dir", vc::luaw_function_wrapper<
               /* FN:    */ pathc::is_dir,
               /* PARAMS:*/ const char *
        >},
        {"path_make_dirs", vc::luaw_function_wrapper<
               /* FN:    */ pathc::make_dirs,
               /* PARAMS:*/ const char *
        >},
        {"path_remove_all", vc::luaw_function_wrapper<
               /* FN:    */ pathc::remove_all,
               /* PARAMS:*/ const char *
        >},
    };

    ASSERT_FN(add_lua_tab_funcs(vs, path_tab_funcs));

    return vc::VC_ERROR_OK;
}

} /* namespace path_composer */

#endif /* PATH_COMPOSER_H */
