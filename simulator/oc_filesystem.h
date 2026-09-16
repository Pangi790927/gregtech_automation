#ifndef OC_FILESYSTEM_H
#define OC_FILESYSTEM_H

/*! oc_filesystem.h - the storage behind a `filesystem` component: a tree of files in memory.
 *
 * Core: OpenComputers' filesystem component is a managed one - the guest asks for paths and
 * handles, not for sectors - so what backs it is a directory tree, and this is that tree plus the
 * handful of operations the component exposes. Nothing here touches the real disk. A floppy is
 * filled from the mod's jar at boot and a hard disk starts empty and lives as long as the machine
 * it belongs to.
 *
 * The path rules are the component's, not the host's: everything is relative to the filesystem's
 * own root, a leading slash is ignored rather than meaning the host's root, `..` cannot climb above
 * the root, and comparisons are exact. A guest cannot address anything outside its own filesystem,
 * which is the point.
 *
 * @date 2026-09-16 */

#include <algorithm>
#include <cstdint>
#include <map>
#include <string>
#include <unordered_map>
#include <vector>

namespace oc_filesystem {

/*! One entry in the tree: either a directory with children, or a file with bytes.
 *
 * `children` is ordered rather than hashed so that listing a directory answers in a stable order.
 * A shell printing its files in a different order every run would look broken.
 * @date 2026-09-16 */
struct node_t {
    bool dir = false;
    std::string data;
    std::map<std::string, node_t> children;
    double mtime = 0;
};

/*! An open file. `pos` is a byte offset; a write handle points into the node's own data.
 * @date 2026-09-16 */
struct handle_t {
    std::string path;
    bool write = false;
    size_t pos = 0;
    bool open = true;
};

/*! Splits a component path into its segments, resolving `.` and `..` and refusing to climb out.
 *
 * Returns the segments. A path that tries to walk above the root simply stops there, which is what
 * makes the root a boundary rather than a suggestion.
 * @date 2026-09-16 */
inline std::vector<std::string> split(const std::string &path) {
    std::vector<std::string> out;
    std::string seg;
    auto flush = [&]() {
        if (seg.empty() || seg == ".") {
            seg.clear();
            return;
        }
        if (seg == "..") {
            if (!out.empty())
                out.pop_back();
            seg.clear();
            return;
        }
        out.push_back(seg);
        seg.clear();
    };
    for (char c : path) {
        if (c == '/' || c == '\\')
            flush();
        else
            seg.push_back(c);
    }
    flush();
    return out;
}

/*! A filesystem: a root directory, a label, and whatever is currently open in it.
 * @date 2026-09-16 */
struct filesystem_t {
    node_t root;
    bool read_only = false;
    std::string label;
    std::unordered_map<int, handle_t> handles;
    int next_handle = 1;
    /*! How much this filesystem claims to hold. A hard disk's capacity is fiction at this stage,
     * but `df` and OpenOS's installer both ask, and zero would read as a full disk.
     * @date 2026-09-16 */
    uint64_t capacity = 2 * 1024 * 1024;

    filesystem_t() { root.dir = true; }

    /*! The node at `path`, or null when nothing is there. The root answers for an empty path.
     * @date 2026-09-16 */
    node_t *find(const std::string &path) {
        node_t *cur = &root;
        for (const std::string &seg : split(path)) {
            if (!cur->dir)
                return nullptr;
            auto it = cur->children.find(seg);
            if (it == cur->children.end())
                return nullptr;
            cur = &it->second;
        }
        return cur;
    }

    /*! The directory that would contain `path`, creating it when asked, and the final name.
     *
     * Returns null when a parent exists but is a file, which is what makes writing to `a/b` fail
     * cleanly when `a` is a file rather than silently replacing it.
     * @date 2026-09-16 */
    node_t *parent_of(const std::string &path, std::string &name, bool create) {
        std::vector<std::string> segs = split(path);
        if (segs.empty())
            return nullptr;
        name = segs.back();
        segs.pop_back();

        node_t *cur = &root;
        for (const std::string &seg : segs) {
            auto it = cur->children.find(seg);
            if (it == cur->children.end()) {
                if (!create)
                    return nullptr;
                node_t made;
                made.dir = true;
                it = cur->children.emplace(seg, made).first;
            }
            if (!it->second.dir)
                return nullptr;
            cur = &it->second;
        }
        return cur;
    }

    /*! Makes a directory and every directory above it. Answers false only when the path runs
     * through an existing file. @date 2026-09-16 */
    bool make_directory(const std::string &path) {
        std::string name;
        node_t *parent = parent_of(path, name, true);
        if (!parent)
            return false;
        auto it = parent->children.find(name);
        if (it != parent->children.end())
            return it->second.dir;
        node_t made;
        made.dir = true;
        parent->children.emplace(name, made);
        return true;
    }

    /*! Writes a whole file, creating the directories above it. Used to fill a floppy from the jar.
     * @date 2026-09-16 */
    bool write_file(const std::string &path, const std::string &bytes) {
        std::string name;
        node_t *parent = parent_of(path, name, true);
        if (!parent)
            return false;
        node_t file;
        file.dir = false;
        file.data = bytes;
        parent->children[name] = file;
        return true;
    }

    bool remove(const std::string &path) {
        std::string name;
        node_t *parent = parent_of(path, name, false);
        if (!parent)
            return false;
        return parent->children.erase(name) > 0;
    }

    bool rename(const std::string &from, const std::string &to) {
        node_t *src = find(from);
        if (!src)
            return false;
        node_t copy = *src;

        std::string name;
        node_t *parent = parent_of(to, name, true);
        if (!parent)
            return false;
        parent->children[name] = copy;
        return remove(from);
    }

    /*! How many bytes the files in this tree add up to. @date 2026-09-16 */
    uint64_t used() const { return used_of(root); }

    static uint64_t used_of(const node_t &n) {
        if (!n.dir)
            return (uint64_t)n.data.size();
        uint64_t total = 0;
        for (const auto &kv : n.children)
            total += used_of(kv.second);
        return total;
    }
};

} /* namespace oc_filesystem */

#endif /* OC_FILESYSTEM_H */
