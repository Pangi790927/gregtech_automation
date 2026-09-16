#ifndef MC_ASSETS_H
#define MC_ASSETS_H

/*! mc_assets.h - where a cell's faces get their pixels: read out of the Minecraft instance when one
 * is configured, and drawn by hand when it is not. Plain C++, no Lua anywhere in this file.
 *
 * Core: the simulator must look right with or without a copy of GregTech: New Horizons on the
 * machine. So every tile has two sources - the real OpenComputers texture inside the mod jar, and a
 * procedural stand-in generated here - and a caller asks for a tile rather than for a file. Which
 * of the two answered is reported, so the interface can say so, but nothing above this layer has to
 * branch on it.
 *
 * Reading the jar needs a zip reader and a PNG decoder, and the project turns out to own both
 * already: ../../utils/vulkan/stb_image.h decodes the PNG, and the raw-deflate entry point it
 * exposes for its own PNG work (stbi_zlib_decode_noheader_buffer) is exactly what a zip entry
 * stores. So the whole path costs a central-directory walk and nothing else - no new dependency.
 *
 * What is deliberately not handled: zip64 (a jar big enough to need it is not a mod), encrypted
 * entries, and multi-disk archives. Each answers empty rather than guessing.
 *
 * @date 2026-09-16 */

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

/* stb_image's implementation is emitted here. This is a header-only project with one translation
unit, so "exactly one .cpp defines it" and "this header defines it" are the same statement. */
#define STB_IMAGE_IMPLEMENTATION
#define STBI_NO_STDIO
#include "stb_image.h"

#include "debug.h"

namespace mc_assets {

/*! Every tile is square and this is its side in pixels. Minecraft block textures are 16x16, and a
 * source image of any other size is resampled to this when it is loaded, so the atlas has one cell
 * size and the fallback generators have one canvas to draw on. @date 2026-09-16 */
constexpr int TILE_PX = 16;
constexpr int TILE_BYTES = TILE_PX * TILE_PX * 4;

/*! One square of RGBA pixels, row-major from the top left, four bytes per pixel.
 *
 * `from_mc` records whether these pixels came out of a Minecraft jar or were drawn by the fallback
 * generators below. It exists so the interface can tell the user which world they are looking at;
 * nothing about drawing depends on it.
 *
 * @date 2026-09-16 */
struct tile_t {
    uint8_t px[TILE_BYTES] = {};
    bool from_mc = false;

    uint8_t *at(int x, int y) { return px + (y * TILE_PX + x) * 4; }
    const uint8_t *at(int x, int y) const { return px + (y * TILE_PX + x) * 4; }

    void set(int x, int y, uint8_t r, uint8_t g, uint8_t b, uint8_t a = 255) {
        if (x < 0 || y < 0 || x >= TILE_PX || y >= TILE_PX)
            return;
        uint8_t *p = at(x, y);
        p[0] = r; p[1] = g; p[2] = b; p[3] = a;
    }

    void fill(uint8_t r, uint8_t g, uint8_t b, uint8_t a = 255) {
        for (int y = 0; y < TILE_PX; y++)
            for (int x = 0; x < TILE_PX; x++)
                set(x, y, r, g, b, a);
    }
};

/* --- reading a jar ------------------------------------------------------------------------- */

/*! Reads a whole file into memory, answering an empty vector when it cannot be opened.
 *
 * A missing file is not an error here. The Minecraft path is configuration a user may simply not
 * have set, and the caller's answer to "no bytes" is to draw the fallback, not to fail.
 * @date 2026-09-16 */
inline std::vector<uint8_t> read_file(const std::string &path) {
    std::vector<uint8_t> out;
    FILE *f = fopen(path.c_str(), "rb");
    if (!f)
        return out;

    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (len > 0) {
        out.resize((size_t)len);
        if (fread(out.data(), 1, out.size(), f) != out.size())
            out.clear();
    }
    fclose(f);
    return out;
}

/*! Little-endian scalar reads, the only byte order the zip format uses. @date 2026-09-16 */
inline uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
inline uint32_t rd32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

/*! Pulls one entry out of a zip archive already held in memory, by its exact path inside it.
 *
 * Core: finds the end-of-central-directory record, walks the directory for `entry`, then reads the
 * local header to learn where the data actually starts - the local header's own name and extra
 * lengths are authoritative and routinely differ from the directory's, which is why the offset
 * cannot be computed from the directory alone.
 *
 * Only the two storage methods a jar ever uses are handled: stored (0) and deflate (8). The deflate
 * case goes through stb_image's raw inflate, which is what a zip entry holds - a bare deflate
 * stream with no zlib header - and the uncompressed size from the directory sizes the output
 * exactly, so nothing has to grow a buffer by guessing.
 *
 * Params: `zip` the whole archive, `entry` a full path inside it such as
 * "assets/opencomputers/textures/blocks/CaseSide.png".
 * Returns the decompressed bytes, or an empty vector when the archive is malformed, the entry is
 * absent, or its storage method is one of the exotic ones.
 * @date 2026-09-16 */
inline std::vector<uint8_t> zip_extract(const std::vector<uint8_t> &zip, const std::string &entry) {
    std::vector<uint8_t> out;
    if (zip.size() < 22)
        return out;

    /* The end-of-central-directory record sits at the very end, unless the archive carries a
    trailing comment - so it is searched backwards over the largest comment the format allows. */
    size_t eocd = 0;
    bool found_eocd = false;
    size_t scan_from = zip.size() >= 22 + 65535 ? zip.size() - (22 + 65535) : 0;
    for (size_t i = zip.size() - 22 + 1; i-- > scan_from; ) {
        if (rd32(&zip[i]) == 0x06054b50) {
            eocd = i;
            found_eocd = true;
            break;
        }
    }
    if (!found_eocd)
        return out;

    uint32_t entries = rd16(&zip[eocd + 10]);
    uint32_t cd_off = rd32(&zip[eocd + 16]);
    if (cd_off >= zip.size())
        return out;

    size_t p = cd_off;
    for (uint32_t i = 0; i < entries; i++) {
        if (p + 46 > zip.size() || rd32(&zip[p]) != 0x02014b50)
            return out;

        uint16_t method    = rd16(&zip[p + 10]);
        uint32_t comp_sz   = rd32(&zip[p + 20]);
        uint32_t uncomp_sz = rd32(&zip[p + 24]);
        uint16_t name_len  = rd16(&zip[p + 28]);
        uint16_t extra_len = rd16(&zip[p + 30]);
        uint16_t cmnt_len  = rd16(&zip[p + 32]);
        uint32_t local_off = rd32(&zip[p + 42]);

        if (p + 46 + name_len > zip.size())
            return out;

        std::string name((const char *)&zip[p + 46], name_len);
        if (name == entry) {
            if (local_off + 30 > zip.size() || rd32(&zip[local_off]) != 0x04034b50)
                return out;

            /* The local header repeats the name and extra lengths, and they are the ones that
            describe this copy of the header - the directory's values may differ. */
            uint16_t l_name  = rd16(&zip[local_off + 26]);
            uint16_t l_extra = rd16(&zip[local_off + 28]);
            size_t data = (size_t)local_off + 30 + l_name + l_extra;
            if (data + comp_sz > zip.size())
                return out;

            if (method == 0) {
                out.assign(zip.begin() + data, zip.begin() + data + comp_sz);
                return out;
            }
            if (method == 8) {
                out.resize(uncomp_sz);
                int got = stbi_zlib_decode_noheader_buffer((char *)out.data(), (int)out.size(),
                        (const char *)&zip[data], (int)comp_sz);
                if (got < 0) {
                    DBG("zip_extract: inflate failed for %s", entry.c_str());
                    out.clear();
                }
                return out;
            }

            DBG("zip_extract: %s uses unsupported method %d", entry.c_str(), (int)method);
            return out;
        }

        p += 46u + name_len + extra_len + cmnt_len;
    }
    return out;
}

/*! Every entry in a zip archive whose path starts with `prefix`, as full paths.
 *
 * Core: the central directory is walked once and the names collected, so a caller can find out what
 * is in a folder inside a jar without knowing the list in advance. Reading OpenOS off the mod's
 * floppy image needs exactly this - a hundred and thirty-odd files nobody wants to enumerate by
 * hand, and which change between mod versions.
 *
 * Directory entries, which zip stores as names ending in a slash, are skipped: the caller wants
 * files, and the folders are implied by the paths of the files inside them.
 * @date 2026-09-16 */
inline std::vector<std::string> zip_list(const std::vector<uint8_t> &zip,
        const std::string &prefix) {
    std::vector<std::string> out;
    if (zip.size() < 22)
        return out;

    size_t eocd = 0;
    bool found = false;
    size_t scan_from = zip.size() >= 22 + 65535 ? zip.size() - (22 + 65535) : 0;
    for (size_t i = zip.size() - 22 + 1; i-- > scan_from; ) {
        if (rd32(&zip[i]) == 0x06054b50) {
            eocd = i;
            found = true;
            break;
        }
    }
    if (!found)
        return out;

    uint32_t entries = rd16(&zip[eocd + 10]);
    uint32_t cd_off = rd32(&zip[eocd + 16]);
    if (cd_off >= zip.size())
        return out;

    size_t p = cd_off;
    for (uint32_t i = 0; i < entries; i++) {
        if (p + 46 > zip.size() || rd32(&zip[p]) != 0x02014b50)
            break;

        uint16_t name_len  = rd16(&zip[p + 28]);
        uint16_t extra_len = rd16(&zip[p + 30]);
        uint16_t cmnt_len  = rd16(&zip[p + 32]);
        if (p + 46 + name_len > zip.size())
            break;

        std::string name((const char *)&zip[p + 46], name_len);
        if (!name.empty() && name.back() != '/' && name.compare(0, prefix.size(), prefix) == 0)
            out.push_back(name);

        p += 46u + name_len + extra_len + cmnt_len;
    }
    return out;
}

/* --- turning bytes into tiles -------------------------------------------------------------- */

/*! Decodes a PNG held in memory into a tile, resampling to TILE_PX when it is another size.
 *
 * The resample is nearest-neighbour on purpose. A resource pack at 32x32 or 64x64 should come out
 * looking like the blocky thing it is meant to be, and averaging would only blur it before the
 * nearest-filtered texture blew it back up.
 *
 * Returns true when the image decoded; `out` is untouched on failure.
 * @date 2026-09-16 */
inline bool png_to_tile(const std::vector<uint8_t> &png, tile_t &out) {
    if (png.empty())
        return false;

    int w = 0, h = 0, chans = 0;
    stbi_uc *pix = stbi_load_from_memory(png.data(), (int)png.size(), &w, &h, &chans, 4);
    if (!pix || w <= 0 || h <= 0) {
        if (pix)
            stbi_image_free(pix);
        return false;
    }

    /* An animated Minecraft texture is a vertical strip of square frames with a .mcmeta beside it.
    Only the first frame is wanted, so the source is treated as square from the top. */
    int src_side = w;
    if (h < src_side)
        src_side = h;

    for (int y = 0; y < TILE_PX; y++) {
        for (int x = 0; x < TILE_PX; x++) {
            int sx = x * src_side / TILE_PX;
            int sy = y * src_side / TILE_PX;
            const stbi_uc *s = pix + ((size_t)sy * w + sx) * 4;
            out.set(x, y, s[0], s[1], s[2], s[3]);
        }
    }
    out.from_mc = true;
    stbi_image_free(pix);
    return true;
}

/*! Alpha-blends `over` onto `base`, in place on `base`.
 *
 * This is how the case's lit states are built. CaseFrontOn and its siblings are small, mostly
 * transparent decals meant to sit on top of CaseFront rather than replace it - which is exactly
 * what their file sizes say, a couple of hundred bytes against the base texture's six hundred.
 * @date 2026-09-16 */
inline void composite(tile_t &base, const tile_t &over) {
    for (int y = 0; y < TILE_PX; y++)
        for (int x = 0; x < TILE_PX; x++) {
            const uint8_t *o = over.at(x, y);
            if (!o[3])
                continue;
            uint8_t *b = base.at(x, y);
            int a = o[3];
            for (int c = 0; c < 3; c++)
                b[c] = (uint8_t)((o[c] * a + b[c] * (255 - a)) / 255);
            b[3] = 255;
        }
}

/*! The value-noise-free speckle the fallback tiles use to look like a surface rather than a swatch.
 *
 * A hash of the coordinates rather than a random number generator, so a tile is identical on every
 * run and two tiles drawn with the same seed look the same.
 * @date 2026-09-16 */
inline int speckle(int x, int y, int seed) {
    uint32_t h = (uint32_t)(x * 374761393 + y * 668265263 + seed * 2246822519u);
    h = (h ^ (h >> 13)) * 1274126177u;
    return (int)((h ^ (h >> 16)) & 0xf) - 8;
}

/*! Clamps an integer into a byte, for the fallback generators' arithmetic. @date 2026-09-16 */
inline uint8_t clamp8(int v) { return (uint8_t)(v < 0 ? 0 : (v > 255 ? 255 : v)); }

/*! Draws a plain metal panel: a speckled body inside a darker one-pixel rim.
 *
 * This is the base every hand-drawn case face starts from, and on its own it is the side, back and
 * top of a case when no Minecraft textures were found.
 * @date 2026-09-16 */
inline tile_t fallback_panel(int base_r, int base_g, int base_b, int seed) {
    tile_t t;
    for (int y = 0; y < TILE_PX; y++)
        for (int x = 0; x < TILE_PX; x++) {
            int n = speckle(x, y, seed);
            bool rim = (x == 0 || y == 0 || x == TILE_PX - 1 || y == TILE_PX - 1);
            int dark = rim ? -40 : 0;
            t.set(x, y, clamp8(base_r + n + dark), clamp8(base_g + n + dark),
                    clamp8(base_b + n + dark));
        }
    return t;
}

/*! Draws the hand-made front of a computer case: a panel, a dark screen recess, and a status light.
 *
 * `led_r/g/b` is the light's colour, which is what carries the cell's state when there are no
 * Minecraft textures - dim grey when off, green when running, red on an error. It is the one part
 * of the fallback that has to read at a glance from across the map.
 * @date 2026-09-16 */
inline tile_t fallback_case_front(int led_r, int led_g, int led_b) {
    tile_t t = fallback_panel(120, 122, 126, 7);

    /* The recessed screen: a darker rectangle with a lighter top edge, so it reads as sunken. */
    for (int y = 3; y <= 9; y++)
        for (int x = 3; x <= 12; x++) {
            int n = speckle(x, y, 11);
            int shade = (y == 3) ? 30 : 0;
            t.set(x, y, clamp8(44 + n + shade), clamp8(48 + n + shade), clamp8(54 + n + shade));
        }

    /* Two vents along the bottom, which give the face a direction the eye can pick up. */
    for (int x = 3; x <= 12; x++) {
        t.set(x, 12, 92, 94, 98);
        t.set(x, 13, 92, 94, 98);
    }

    /* The status light, with a one-pixel darker socket around it. */
    for (int y = 11; y <= 12; y++)
        for (int x = 13; x <= 14; x++)
            t.set(x, y, clamp8(led_r), clamp8(led_g), clamp8(led_b));
    t.set(12, 11, 70, 72, 76);
    t.set(12, 12, 70, 72, 76);

    return t;
}

/*! Draws the ground plane's tile: a flat slab with a darker border, so the grid of cells is
 * readable and a placed block has something to sit against.
 * @date 2026-09-16 */
inline tile_t fallback_ground() {
    tile_t t;
    for (int y = 0; y < TILE_PX; y++)
        for (int x = 0; x < TILE_PX; x++) {
            int n = speckle(x, y, 3) / 2;
            bool edge = (x == 0 || y == 0);
            if (edge)
                t.set(x, y, clamp8(96 + n), clamp8(100 + n), clamp8(104 + n));
            else
                t.set(x, y, clamp8(126 + n), clamp8(131 + n), clamp8(136 + n));
        }
    return t;
}

/* --- the instance ------------------------------------------------------------------------- */

/*! A located Minecraft instance, and the jar bytes read out of it.
 *
 * Core: open() is given the instance directory - the one holding `mods/` - finds the
 * OpenComputers jar inside it by trying the names that ship with GregTech: New Horizons, and keeps
 * the whole jar in memory. It is a few megabytes and every tile after the first is then a directory
 * walk rather than another read of the disk.
 *
 * A path that does not exist, or a directory with no OpenComputers jar in it, leaves the source
 * closed and every tile request answering false. That is the ordinary case for anyone without the
 * modpack installed, not a fault.
 *
 * @date 2026-09-16 */
struct mc_source_t {
    std::vector<uint8_t> jar;
    std::string jar_path;

    /*! The vanilla Minecraft jar, opened separately.
     *
     * Some of what the simulator draws is not OpenComputers at all - a redstone lamp is a vanilla
     * block - so its art lives in a different archive under a different asset prefix. Kept as a
     * second source rather than merged, because the two are found by different means and either may
     * be absent while the other is present.
     * @date 2026-09-16 */
    std::vector<uint8_t> vanilla;
    std::string vanilla_path;

    bool is_open() const { return !jar.empty(); }
    bool vanilla_open() const { return !vanilla.empty(); }

    /*! Looks for an OpenComputers jar under `instance_dir` and reads it.
     *
     * `instance_dir` may also be the jar itself, which is what a user with a non-standard layout
     * can fall back on. Returns true when a jar was read.
     * @date 2026-09-16 */
    bool open(const std::string &instance_dir) {
        jar.clear();
        jar_path.clear();
        if (instance_dir.empty())
            return false;

        /* Given the jar directly, take it. Recognised by extension rather than by probing, so a
        wrong path fails here instead of being read as a directory. */
        if (instance_dir.size() > 4 &&
                instance_dir.compare(instance_dir.size() - 4, 4, ".jar") == 0) {
            jar = read_file(instance_dir);
            if (!jar.empty())
                jar_path = instance_dir;
            return is_open();
        }

        std::string base = instance_dir;
        if (!base.empty() && base.back() != '/' && base.back() != '\\')
            base += "/";

        /* The version in the name changes between modpack releases, so a handful of known spellings
        are tried. Nothing here globs - the C++ standard library's directory iterator would do it,
        but a fixed list keeps the lookup honest about which versions have actually been seen. */
        static const char *candidates[] = {
            "mods/OpenComputers-1.8.0.13-GTNH.jar",
            "mods/OpenComputers-1.8.0.12-GTNH.jar",
            "mods/OpenComputers-1.8.0.11-GTNH.jar",
            "mods/OpenComputers.jar",
        };
        for (const char *c : candidates) {
            jar = read_file(base + c);
            if (!jar.empty()) {
                jar_path = base + c;
                DBG("mc_assets: opened %s (%zu bytes)", jar_path.c_str(), jar.size());
                return true;
            }
        }

        DBG("mc_assets: no OpenComputers jar under %s", instance_dir.c_str());
        return false;
    }

    /*! Reads the vanilla Minecraft jar, for the blocks that are not OpenComputers'.
     *
     * Given a path to a jar it takes it; given a directory it looks for the launcher's usual
     * layout underneath. Absent is not an error - the fallback tiles cover it.
     * @date 2026-09-16 */
    bool open_vanilla(const std::string &path) {
        vanilla.clear();
        vanilla_path.clear();
        if (path.empty())
            return false;

        if (path.size() > 4 && path.compare(path.size() - 4, 4, ".jar") == 0) {
            vanilla = read_file(path);
            if (!vanilla.empty())
                vanilla_path = path;
        }
        else {
            std::string base = path;
            if (base.back() != '/' && base.back() != '\\')
                base += "/";
            static const char *names[] = {
                "versions/1.7.10/1.7.10.jar",
                "versions/1.12.2/1.12.2.jar",
            };
            for (const char *n : names) {
                vanilla = read_file(base + n);
                if (!vanilla.empty()) {
                    vanilla_path = base + n;
                    break;
                }
            }
        }

        if (vanilla_open())
            DBG("mc_assets: opened vanilla %s (%zu bytes)", vanilla_path.c_str(), vanilla.size());
        return vanilla_open();
    }

    /*! Loads a vanilla block texture by its bare name, such as "redstone_lamp_on".
     * @date 2026-09-16 */
    bool vanilla_tile(const char *name, tile_t &out) const {
        if (!vanilla_open())
            return false;
        std::string entry = std::string("assets/minecraft/textures/blocks/") + name + ".png";
        return png_to_tile(zip_extract(vanilla, entry), out);
    }

    /*! Loads one block texture by its bare name, such as "CaseSide", from the open jar.
     *
     * Returns false when nothing is open, the entry is absent, or the PNG will not decode - in all
     * three cases the caller's answer is the same, which is to draw the fallback.
     * @date 2026-09-16 */
    bool block_tile(const char *name, tile_t &out) const {
        if (!is_open())
            return false;
        std::string entry = std::string("assets/opencomputers/textures/blocks/") + name + ".png";
        return png_to_tile(zip_extract(jar, entry), out);
    }
};

} /* namespace mc_assets */

#endif /* MC_ASSETS_H */
