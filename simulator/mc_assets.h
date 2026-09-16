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

#include <algorithm>
#include <cstdint>
#include <cctype>
#include <cstdlib>
#include <filesystem>
#include <map>
#include <unordered_set>
#include <utility>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

/* stb_image's implementation is emitted here. This is a header-only project with one translation
unit, so "exactly one .cpp defines it" and "this header defines it" are the same statement. */
#define STB_IMAGE_IMPLEMENTATION
#define STBI_NO_STDIO
#include "stb_image.h"

#include "class_reader.h"

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
/*! Reads `count` bytes of a file starting at `offset`, and no more.
 *
 * The whole point of the seeking zip reader below: the modpack's mods directory is four hundred
 * megabytes across two hundred and thirty-eight jars, and the pictures wanted out of it come to a
 * few megabytes. Reading each jar whole to find them made opening the simulator take an age.
 * @date 2026-09-17 */
inline std::vector<uint8_t> read_file_part(const std::string &path, uint64_t offset, size_t count) {
    std::vector<uint8_t> out;
    FILE *f = fopen(path.c_str(), "rb");
    if (!f)
        return out;

    if (fseek(f, (long)offset, SEEK_SET) == 0) {
        out.resize(count);
        size_t got = fread(out.data(), 1, count, f);
        out.resize(got);
    }
    fclose(f);
    return out;
}

/*! How big a file is, without reading any of it. @date 2026-09-17 */
inline uint64_t file_size_of(const std::string &path) {
    std::error_code ec;
    uintmax_t n = std::filesystem::file_size(path, ec);
    return ec ? 0 : (uint64_t)n;
}

/*! One entry of a zip, as the central directory describes it. @date 2026-09-17 */
struct zip_entry_t {
    std::string name;
    uint64_t local_offset = 0;      /*!< where the local header sits */
    uint32_t comp_size = 0;
    uint32_t raw_size = 0;
    uint16_t method = 0;            /*!< 0 stored, 8 deflate - the only two a jar uses */
};

/*! Lists a zip's entries by reading ONLY its central directory off disk.
 *
 * Core: a zip keeps its directory at the END, with a record pointing at it, so the whole archive
 * never has to be in memory to know what is in it. Two reads: the tail, to find the end-of-central
 * -directory record, and then the directory itself.
 *
 * @param path  the archive
 * @return every entry, or nothing when the file is not a zip
 * @date 2026-09-17 */
inline std::vector<zip_entry_t> zip_dir(const std::string &path) {
    std::vector<zip_entry_t> out;

    uint64_t size = file_size_of(path);
    if (size < 22)
        return out;

    /* The record is in the last 22 bytes plus however long the archive comment is, and a comment
    can be 65535 bytes. Reading that tail is enough to find it however long it is. */
    size_t tail_len = (size_t)std::min<uint64_t>(size, 22 + 65535);
    std::vector<uint8_t> tail = read_file_part(path, size - tail_len, tail_len);
    if (tail.size() < 22)
        return out;

    size_t eocd = 0;
    bool found = false;
    for (size_t i = tail.size() - 22 + 1; i-- > 0; ) {
        if (rd32(&tail[i]) == 0x06054b50) {
            eocd = i;
            found = true;
            break;
        }
    }
    if (!found)
        return out;

    uint32_t entries = rd16(&tail[eocd + 10]);
    uint32_t cd_size = rd32(&tail[eocd + 12]);
    uint32_t cd_off  = rd32(&tail[eocd + 16]);
    if (cd_off >= size || cd_size == 0)
        return out;

    std::vector<uint8_t> cd = read_file_part(path, cd_off, cd_size);
    size_t p = 0;
    for (uint32_t i = 0; i < entries; i++) {
        if (p + 46 > cd.size() || rd32(&cd[p]) != 0x02014b50)
            break;

        zip_entry_t e;
        e.method    = rd16(&cd[p + 10]);
        e.comp_size = rd32(&cd[p + 20]);
        e.raw_size  = rd32(&cd[p + 24]);
        uint16_t name_len  = rd16(&cd[p + 28]);
        uint16_t extra_len = rd16(&cd[p + 30]);
        uint16_t cmnt_len  = rd16(&cd[p + 32]);
        e.local_offset = rd32(&cd[p + 42]);
        if (p + 46 + name_len > cd.size())
            break;

        e.name.assign((const char *)&cd[p + 46], name_len);
        if (!e.name.empty() && e.name.back() != '/')
            out.push_back(std::move(e));

        p += 46u + name_len + extra_len + cmnt_len;
    }
    return out;
}

/*! Reads and inflates one entry, off disk, without touching the rest of the archive.
 *
 * The local header repeats the name and extra field with lengths of their own - they need not
 * match the central directory's - so it is read first to know where the data actually begins.
 * @date 2026-09-17 */
inline std::vector<uint8_t> zip_read(const std::string &path, const zip_entry_t &e) {
    std::vector<uint8_t> out;

    std::vector<uint8_t> head = read_file_part(path, e.local_offset, 30);
    if (head.size() < 30 || rd32(&head[0]) != 0x04034b50)
        return out;

    uint64_t data_at = e.local_offset + 30 + rd16(&head[26]) + rd16(&head[28]);
    std::vector<uint8_t> raw = read_file_part(path, data_at, e.comp_size);
    if (raw.size() < e.comp_size)
        return out;

    if (e.method == 0)
        return raw;
    if (e.method != 8)
        return out;

    out.resize(e.raw_size);
    int got = stbi_zlib_decode_noheader_buffer((char *)out.data(), (int)out.size(),
            (const char *)raw.data(), (int)raw.size());
    if (got < 0) {
        out.clear();
        return out;
    }
    out.resize((size_t)got);
    return out;
}

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

    /*! The Iron Tanks jar, which the liquid tank's shell is drawn from.
     *
     * The author asked for that mod's model on 2026-09-17. Its side texture is a metal frame with
     * one fully transparent palette entry in the middle - a window - which is why the fluid inside
     * can simply be drawn behind it rather than composited into the frame.
     * @date 2026-09-17 */
    std::vector<uint8_t> irontank;
    std::string irontank_path;

    /*! The GregTech jar, which every fluid's texture comes out of.
     * @date 2026-09-17 */
    std::vector<uint8_t> gregtech;
    std::string gregtech_path;

    /*! GregTech's generated name file, read from the instance root rather than from a jar.
     *
     * GregTech writes GregTech.lang beside the instance's config, not inside its archive, because
     * the names are generated from the material list at first run. It is a Forge config file, so a
     * fluid's line reads `    S:fluid.chlorine=Chlorine`. Kept as text and parsed on demand.
     * @date 2026-09-17 */
    std::string gt_lang;

    bool is_open() const { return !jar.empty(); }
    bool vanilla_open() const { return !vanilla.empty(); }
    bool irontank_open() const { return !irontank.empty(); }
    bool gregtech_open() const { return !gregtech.empty(); }

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

    /*! The Applied Energistics jar, which the import and export buses are drawn from.
     * @date 2026-09-17 */
    std::vector<uint8_t> ae2;
    std::string ae2_path;

    bool ae2_open() const { return !ae2.empty(); }

    /*! One AE2 block texture, such as "ItemPart.ImportBus". @date 2026-09-17 */
    bool ae2_tile(const char *name, tile_t &out) const {
        if (!ae2_open())
            return false;
        std::string entry = std::string("assets/appliedenergistics2/textures/blocks/")
                + name + ".png";
        return png_to_tile(zip_extract(ae2, entry), out);
    }

    /*! Opens the two extra archives the liquid tank needs, and GregTech's name file.
     *
     * Separate from open() because both are optional in a way the OpenComputers jar is not: a tank
     * with no art still works, it just draws a stand-in. Absent is not an error anywhere here.
     *
     * The version in each name changes between modpack releases, so a few known spellings are
     * tried, the same way open() does it.
     * @date 2026-09-17 */
    void open_extras(const std::string &instance_dir) {
        irontank.clear();
        gregtech.clear();
        ae2.clear();
        gt_lang.clear();
        if (instance_dir.empty())
            return;

        std::string base = instance_dir;
        if (base.size() > 4 && base.compare(base.size() - 4, 4, ".jar") == 0) {
            /* Given a jar rather than an instance there is no instance to look around in. */
            return;
        }
        if (base.back() != '/' && base.back() != '\\')
            base += "/";

        static const char *tank_names[] = {
            "mods/irontanks-1.7.10-1.2.6.jar",
            "mods/irontanks-1.7.10-1.2.5.jar",
            "mods/irontanks.jar",
        };
        for (const char *n : tank_names) {
            irontank = read_file(base + n);
            if (!irontank.empty()) {
                irontank_path = base + n;
                DBG("mc_assets: opened %s (%zu bytes)", irontank_path.c_str(), irontank.size());
                break;
            }
        }

        static const char *gt_names[] = {
            "mods/gregtech-5.09.41.317.jar",
            "mods/gregtech-5.09.41.316.jar",
            "mods/gregtech.jar",
        };
        for (const char *n : gt_names) {
            gregtech = read_file(base + n);
            if (!gregtech.empty()) {
                gregtech_path = base + n;
                DBG("mc_assets: opened %s (%zu bytes)", gregtech_path.c_str(), gregtech.size());
                break;
            }
        }

        static const char *ae2_names[] = {
            "mods/appliedenergistics2-rv3-beta-175-GTNH.jar",
            "mods/appliedenergistics2-rv3-beta-174-GTNH.jar",
            "mods/appliedenergistics2.jar",
        };
        for (const char *n : ae2_names) {
            ae2 = read_file(base + n);
            if (!ae2.empty()) {
                ae2_path = base + n;
                DBG("mc_assets: opened %s (%zu bytes)", ae2_path.c_str(), ae2.size());
                break;
            }
        }

        std::vector<uint8_t> lang = read_file(base + "GregTech.lang");
        gt_lang.assign(lang.begin(), lang.end());
        DBG("mc_assets: GregTech.lang %zu bytes", gt_lang.size());
    }

    /*! One Iron Tanks block texture, such as "side" or "topbottom", for a given tier.
     * @date 2026-09-17 */
    bool tank_tile(const char *tier, const char *which, tile_t &out) const {
        if (!irontank_open())
            return false;
        std::string entry = std::string("assets/irontank/textures/blocks/") + tier + "/"
                + which + ".png";
        return png_to_tile(zip_extract(irontank, entry), out);
    }

    /*! One GregTech fluid texture, by the fluid's own name - "chlorine", "lubricant".
     *
     * The file is `fluid.<name>.png`, which is the same `<name>` GregTech.lang keys its label
     * with, so a fluid's picture and its name are found by the one string.
     * @date 2026-09-17 */
    bool fluid_tile(const std::string &name, tile_t &out) const {
        if (!gregtech_open())
            return false;
        std::string entry = "assets/gregtech/textures/blocks/fluids/fluid." + name + ".png";
        return png_to_tile(zip_extract(gregtech, entry), out);
    }

    /*! Every fluid GregTech ships a texture for, by name, sorted.
     *
     * The catalogue is taken from the ARCHIVE rather than from a list written here, so it is
     * whatever the installed GregTech actually has - which is the whole point of reading the game
     * instead of describing it.
     * @date 2026-09-17 */
    std::vector<std::string> fluid_names() const {
        std::vector<std::string> out;
        if (!gregtech_open())
            return out;

        const std::string dir = "assets/gregtech/textures/blocks/fluids/";
        for (const std::string &entry : zip_list(gregtech, dir)) {
            std::string file = entry.substr(dir.size());
            if (file.size() < 11 || file.compare(0, 6, "fluid.") != 0)
                continue;
            if (file.compare(file.size() - 4, 4, ".png") != 0)
                continue;
            out.push_back(file.substr(6, file.size() - 10));
        }
        std::sort(out.begin(), out.end());
        return out;
    }

    /*! A fluid's name as the game shows it - "chlorine" answers "Chlorine".
     *
     * Reads GregTech's generated lang file, whose fluid lines are `S:fluid.<name>=<Label>`. Falls
     * back to the internal name, because a fluid with no line is still a fluid.
     * @date 2026-09-17 */
    std::string fluid_label(const std::string &name) const {
        if (gt_lang.empty())
            return name;

        std::string key = "S:fluid." + name + "=";
        size_t at = gt_lang.find(key);
        while (at != std::string::npos) {
            /* Anchored to the start of a line, so `S:fluid.iron=` cannot be found inside
            `S:fluid.molten.iron=`. */
            bool at_line_start = (at == 0 || gt_lang[at - 1] == '\n' || gt_lang[at - 1] == '\r'
                    || gt_lang[at - 1] == ' ' || gt_lang[at - 1] == '\t');
            if (at_line_start) {
                size_t from = at + key.size();
                size_t to = gt_lang.find_first_of("\r\n", from);
                std::string label = gt_lang.substr(from, (to == std::string::npos)
                        ? std::string::npos : to - from);
                while (!label.empty() && (label.back() == ' ' || label.back() == '\t'))
                    label.pop_back();
                if (!label.empty())
                    return label;
            }
            at = gt_lang.find(key, at + 1);
        }
        return name;
    }

    /*! Every item and block the modpack has registered, read out of a save's level.dat.
     *
     * Core: THE REAL REGISTRY, which is the list NEI shows. Forge writes it into every world it
     * saves so that item ids survive a mod list changing, and the names in it are the actual
     * registry names - `minecraft:golden_apple`, not the `apple_golden` its texture is called.
     * There is nothing else on disk that knows them: the jars hold textures and lang keys, and
     * neither is the registry name.
     *
     * HOW IT IS READ, and why not with a proper NBT walk. The file is gzipped NBT, and FML's
     * registry sits in it as a list of compounds whose `K` is the name. A walk over the whole tree
     * desynchronised part way through this particular file, so instead every NBT string in it is
     * picked out directly: a string is framed as a two byte length followed by that many bytes, so
     * a position whose length exactly spans something shaped like a registry name IS one. The
     * entries carry a leading 1 for a block and 2 for an item, which is how FML tells them apart,
     * and that byte is what distinguishes a real registry entry from any other text that happens
     * to have a colon in it.
     *
     * Absent is not an error: a person who has never made a world gets an empty list and the
     * catalogue falls back to texture names.
     *
     * @param instance_dir  the instance, the one holding saves/
     * @return the item names, sorted
     * @date 2026-09-17 */
    std::vector<std::string> registry_names(const std::string &instance_dir) const {
        std::vector<std::string> out;
        if (instance_dir.empty())
            return out;

        std::string base = instance_dir;
        if (base.back() != '/' && base.back() != '\\')
            base += "/";

        /* Whichever save is biggest: the registry grows with the mod list, so the largest
        level.dat is the most complete one. */
        std::string best;
        uintmax_t best_size = 0;
        std::error_code ec;
        for (auto &e : std::filesystem::directory_iterator(base + "saves", ec)) {
            std::filesystem::path lvl = e.path() / "level.dat";
            uintmax_t sz = std::filesystem::file_size(lvl, ec);
            if (!ec && sz > best_size) {
                best_size = sz;
                best = lvl.string();
            }
        }
        if (best.empty()) {
            DBG("mc_assets: no save under %ssaves - item names fall back to textures", base.c_str());
            return out;
        }

        std::vector<uint8_t> gz = read_file(best);
        if (gz.size() < 20 || gz[0] != 0x1f || gz[1] != 0x8b)
            return out;

        /* Past the gzip header to the raw deflate stream stb can inflate. Ten fixed bytes, then
        whatever the flag byte says is also there. */
        size_t at = 10;
        uint8_t flg = gz[3];
        if (flg & 0x04) {                                   /* FEXTRA */
            if (at + 2 > gz.size()) return out;
            at += 2 + (size_t)(gz[at] | (gz[at + 1] << 8));
        }
        if (flg & 0x08)                                     /* FNAME */
            while (at < gz.size() && gz[at++]) {}
        if (flg & 0x10)                                     /* FCOMMENT */
            while (at < gz.size() && gz[at++]) {}
        if (flg & 0x02)                                     /* FHCRC */
            at += 2;
        if (at >= gz.size())
            return out;

        int len = 0;
        char *raw = stbi_zlib_decode_noheader_malloc((const char *)gz.data() + at,
                (int)(gz.size() - at), &len);
        if (!raw || len <= 0) {
            if (raw) free(raw);
            return out;
        }

        const uint8_t *d = (const uint8_t *)raw;
        std::vector<std::string> found;
        for (int i = 0; i + 2 < len; i++) {
            int n = (d[i] << 8) | d[i + 1];
            if (n < 4 || n > 160 || i + 2 + n > len)
                continue;

            const uint8_t *str = d + i + 2;
            /* ONLY THE ITEM REGISTRY. FML marks a block entry with 1 and an item entry with 2, and
            a block that can be held registers in BOTH - every ItemBlock is in the item list. What
            is only in the block list is the technical sort a player never holds: flowing water,
            fire, a piston's moving head. None of those can be in a chest, so none of them belong
            in a list of things to put in one. */
            if (str[0] != 2)
                continue;

            bool ok = true, colon = false;
            for (int k = 1; k < n; k++) {
                uint8_t ch = str[k];
                if (ch == ':') {
                    if (colon || k == 1) { ok = false; break; }
                    colon = true;
                    continue;
                }
                bool word = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')
                        || (ch >= '0' && ch <= '9') || ch == '_' || ch == '.'
                        || ch == '-' || ch == '+' || ch == '/';
                if (!word) { ok = false; break; }
            }
            if (ok && colon)
                found.push_back(std::string((const char *)str + 1, (size_t)n - 1));
        }
        free(raw);

        std::sort(found.begin(), found.end());
        found.erase(std::unique(found.begin(), found.end()), found.end());
        DBG("mc_assets: %zu registry names from %s", found.size(), best.c_str());
        return found;
    }

    /*! One GregTech material, as its compiled code describes it. @date 2026-09-17 */
    struct gt_material_t {
        std::string name;       /*!< what the code calls it, such as "Naquadah" */
        std::string set;        /*!< the texture set that draws it, such as "METALLIC" */
        int r = 255, g = 255, b = 255;
    };

    /*! GregTech's material list, read out of its compiled code.
     *
     * Core: THIS IS NOT IN ANY FILE, and it has to be had from somewhere. Fourteen thousand of
     * GregTech's item names are templates: `S:gt.metaitem.01.2324.name=%material Dust`. The number
     * decomposes as a shape and a material (2324 is dust of material 324), and the material list
     * lives only in the static initialiser of `gregtech/api/enums/Materials`. The lang file has the
     * display names but keys them by material NAME, so without this map nothing joins the two and
     * searching for a naquadah dust finds nothing. The author asked for this on 2026-09-17, having
     * found exactly that.
     *
     * The colour and the texture set are here for the same reason: GregTech has no picture on disk
     * for most of its items. It draws them by tinting a greyscale image from a texture set with the
     * material's own colour, and both of those are arguments to the same constructor.
     *
     * HOW, and what it relies on. Every material is built the same way:
     *
     *      new Materials ; dup ; <sub-id> ; <texture set> ; <tool speed> ; ... ; <r> <g> <b> <a>
     *          ; <name> ; <local name> ; ... ; invokespecial ; putstatic <the field>
     *
     * Everything before the first String argument is a plain push, one per argument, so the pushes
     * line up with the constructor's descriptor one for one. The descriptor is read off the
     * invokespecial, the first String argument is found in it, and the four integers in front of
     * that one are the colour - which is how this stays right across the several constructors
     * GregTech uses, instead of counting arguments and hoping.
     *
     * WHAT IT DOES NOT COVER. Materials built by the copy constructor take a material rather than a
     * number and are skipped, as is anything another mod adds. That is why this answers around five
     * hundred of the twelve hundred names the lang file has. The ones it misses do not appear,
     * rather than appearing wrongly.
     *
     * Verified against values that are public knowledge: iron is 32, gold 86, copper 35.
     *
     * @return sub-id -> the material
     * @date 2026-09-17 */
    std::map<int, gt_material_t> gt_materials() const {
        std::map<int, gt_material_t> out;
        if (!gregtech_open())
            return out;

        namespace cr = class_reader;
        cr::class_file_t cf = cr::read_class(
                zip_extract(gregtech, "gregtech/api/enums/Materials.class"), "<clinit>");
        if (!cf.ok || !cf.code)
            return out;

        const std::string MAT = "gregtech/api/enums/Materials";
        const std::string MAT_DESC = "L" + MAT + ";";
        const uint8_t *code = cf.code;
        uint32_t len = cf.code_len;

        std::vector<gt_material_t> pending_mat;
        std::vector<int> pending_id;

        for (uint32_t i = 0; i + 3 < len; i++) {
            if (code[i] == 0xBB) {                                  /* new */
                uint32_t ref = (uint32_t)((code[i + 1] << 8) | code[i + 2]);
                if (cf.class_name(ref) != MAT || code[i + 3] != 0x59)   /* 0x59 = dup */
                    continue;

                /* Walk the arguments, which up to the first String are one push each. */
                std::vector<int32_t> ints;              /* by argument position, INT32_MIN if not */
                std::vector<std::string> objs;          /* the getstatic field names, likewise */
                uint32_t at = i + 4;
                bool hit_string = false;
                for (int guard = 0; guard < 64 && at < len && !hit_string; guard++) {
                    uint8_t op = code[at];
                    int32_t v = 0;
                    uint32_t size = 0;

                    if (cr::int_push(cf, code, len, at, v, size)) {
                        ints.push_back(v);
                        objs.push_back(std::string());
                        at += size;
                    }
                    else if (op == 0xB2) {              /* getstatic - a texture set, a dye */
                        std::string c, n, dsc;
                        cf.ref((uint32_t)((code[at + 1] << 8) | code[at + 2]), c, n, dsc);
                        ints.push_back(INT32_MIN);
                        objs.push_back(n);
                        at += 3;
                    }
                    else if (op == 0x12 || op == 0x13) {  /* ldc of a float or a string */
                        uint32_t idx = (op == 0x12) ? code[at + 1]
                                : (uint32_t)((code[at + 1] << 8) | code[at + 2]);
                        if (idx < cf.pool.size() && cf.pool[idx].tag == 8)
                            hit_string = true;
                        else {
                            ints.push_back(INT32_MIN);
                            objs.push_back(std::string());
                            at += (op == 0x12) ? 2 : 3;
                        }
                    }
                    else {
                        break;                          /* something this does not model */
                    }
                }

                gt_material_t m;
                if (ints.size() >= 2 && !objs[1].empty()) {
                    /* SET_METALLIC names the folder METALLIC. */
                    m.set = objs[1].compare(0, 4, "SET_") == 0 ? objs[1].substr(4) : objs[1];
                }
                /* The colour is the three integers before the alpha, which is the last argument
                before the name. Only trusted when all four really are integers. */
                size_t n = ints.size();
                if (hit_string && n >= 4 && ints[n - 1] != INT32_MIN && ints[n - 2] != INT32_MIN
                        && ints[n - 3] != INT32_MIN && ints[n - 4] != INT32_MIN) {
                    m.r = ints[n - 4];
                    m.g = ints[n - 3];
                    m.b = ints[n - 2];
                }

                pending_id.push_back(ints.empty() ? INT32_MIN : ints[0]);
                pending_mat.push_back(m);
            }
            else if (code[i] == 0xB3) {                             /* putstatic */
                uint32_t ref = (uint32_t)((code[i + 1] << 8) | code[i + 2]);
                std::string c, n, dsc;
                if (!cf.ref(ref, c, n, dsc) || c != MAT || dsc != MAT_DESC || pending_id.empty())
                    continue;

                int id = pending_id.front();
                gt_material_t m = pending_mat.front();
                pending_id.erase(pending_id.begin());
                pending_mat.erase(pending_mat.begin());

                if (id != INT32_MIN && id >= 0) {
                    m.name = n;
                    out.emplace(id, m);
                }
            }
        }

        DBG("mc_assets: %zu gregtech materials out of Materials.class", out.size());
        return out;
    }

    /*! The shape each thousand of a metaitem's damage value stands for.
     *
     * Core: a damage value is `shape * 1000 + material`, and the shapes are NOT the OrePrefixes
     * enum's own order - GregTech gives each metaitem class its own array of prefixes, built in
     * that class's constructor as `new OrePrefixes[32]` filled index by index. Index two of
     * metaitem 01 is `dust`, which is what makes 2324 a naquadah dust. Reading the enum's ordinals
     * instead gives `sapling`, and every icon would have been wrong in a way nothing would flag.
     *
     * The pattern is the one an array initialiser always compiles to:
     *
     *      dup ; <index> ; getstatic OrePrefixes.<name> ; aastore
     *
     * @param cls  the metaitem class, such as "gregtech/common/items/GT_MetaGenerated_Item_01"
     * @return the prefix name at each index, empty where there is none
     * @date 2026-09-17 */
    std::vector<std::string> gt_prefixes(const std::string &cls) const {
        std::vector<std::string> out;
        if (!gregtech_open())
            return out;

        namespace cr = class_reader;
        cr::class_file_t cf = cr::read_class(zip_extract(gregtech, cls + ".class"), "<init>");
        if (!cf.ok || !cf.code)
            return out;

        const uint8_t *code = cf.code;
        uint32_t len = cf.code_len;
        for (uint32_t i = 0; i + 1 < len; i++) {
            if (code[i] != 0x59)                        /* dup */
                continue;

            int32_t index = 0;
            uint32_t size = 0;
            if (!cr::int_push(cf, code, len, i + 1, index, size) || index < 0 || index > 4096)
                continue;

            uint32_t at = i + 1 + size;
            if (at + 3 >= len || code[at] != 0xB2 || code[at + 3] != 0x53)   /* getstatic, aastore */
                continue;

            std::string c, n, dsc;
            if (!cf.ref((uint32_t)((code[at + 1] << 8) | code[at + 2]), c, n, dsc))
                continue;
            if (c != "gregtech/api/enums/OrePrefixes")
                continue;

            if ((int)out.size() <= index)
                out.resize((size_t)index + 1);
            out[(size_t)index] = n;
        }
        return out;
    }

    /*! One shape of one texture set, decoded once and kept. @date 2026-09-17 */
    struct gt_shape_t {
        tile_t base;
        tile_t overlay;
        bool have = false;
        bool have_overlay = false;
    };
    using gt_shape_cache_t = std::map<std::string, gt_shape_t>;

    /*! The picture GregTech would draw for one of its generated items.
     *
     * Core: GREGTECH HAS NO PICTURE ON DISK FOR THESE. It ships one greyscale image per shape per
     * texture set - `materialicons/METALLIC/dust.png` - and colours it with the material's own
     * colour when it draws. An `_OVERLAY` beside it, where there is one, goes on top UNTINTED,
     * which is how a cell keeps its glass grey while what is inside it takes the colour.
     *
     * The multiply is the mod's own model: a greyscale base times the colour. Nothing here chooses
     * a colour; it comes from the material's constructor, read by gt_materials().
     *
     * @param mat     the material, for its texture set and colour
     * @param prefix  the shape, such as "dust" or "plate"
     * @param out     the picture, untouched when there is none
     * @return whether there was one
     * @date 2026-09-17 */
    bool gt_item_tile(const gt_material_t &mat, const std::string &prefix,
            gt_shape_cache_t &cache, tile_t &out) const {
        if (!gregtech_open() || mat.set.empty() || prefix.empty())
            return false;

        /* THE SHAPE IS LOOKED UP ONCE, NOT ONCE PER MATERIAL. There are fourteen thousand of these
        items and only a few hundred distinct shapes between them; decoding the shape afresh for
        every material meant scanning an eighteen megabyte archive twenty-nine thousand times, and
        put fifteen seconds on the time to open the simulator. What differs per material is the
        colour, and multiplying by it is nothing. */
        const std::string key = mat.set + "/" + prefix;
        auto it = cache.find(key);
        if (it == cache.end()) {
            const std::string dir = "assets/gregtech/textures/items/materialicons/"
                    + mat.set + "/";
            gt_shape_t shape;
            shape.have = png_to_tile(zip_extract(gregtech, dir + prefix + ".png"), shape.base);
            if (shape.have)
                shape.have_overlay = png_to_tile(zip_extract(gregtech,
                        dir + prefix + "_OVERLAY.png"), shape.overlay);
            it = cache.emplace(key, shape).first;
        }
        if (!it->second.have)
            return false;

        tile_t base = it->second.base;

        for (int y = 0; y < TILE_PX; y++)
            for (int x = 0; x < TILE_PX; x++) {
                uint8_t *px = base.at(x, y);
                if (!px[3])
                    continue;
                px[0] = (uint8_t)((px[0] * mat.r) / 255);
                px[1] = (uint8_t)((px[1] * mat.g) / 255);
                px[2] = (uint8_t)((px[2] * mat.b) / 255);
            }

        if (it->second.have_overlay)
            composite(base, it->second.overlay);

        base.from_mc = true;
        out = base;
        return true;
    }

    /*! One item a mod packs behind a shared registry name: its damage value and its name.
     * @date 2026-09-17 */
    struct meta_item_t {
        std::string id;         /*!< the registry name, "gregtech:gt.metaitem.01" */
        int damage = 0;
        std::string label;
        tile_t tile;            /*!< its picture, tinted the way the mod would draw it */
        bool has_tile = false;
    };

    /*! GregTech's metaitems, out of its generated lang file.
     *
     * Core: GREGTECH PACKS THOUSANDS OF ITEMS BEHIND THREE REGISTRY NAMES. Every dust, cell, plate
     * and pipe is `gt.metaitem.01`, `02` or `03` with a damage value after it, so the registry
     * alone lists three entries where the game has fifteen thousand. The names are in
     * GregTech.lang as `S:gt.metaitem.NN.DDDDD.name=...`.
     *
     * MOST OF THOSE LINES ARE TEMPLATES: `%material Dust`, filled in at runtime from the material
     * the damage value belongs to. The number decomposes as a shape and a material - 2324 is dust
     * of material 324 - and gt_material_ids() reads the material list out of GregTech's compiled
     * code, which is the only place it exists. The display name then comes from the lang file's
     * own `S:Material.<name>=` line, so nothing here is invented: the number, the template and
     * both names are all the mod's.
     *
     * A template whose material is not in that map is dropped rather than guessed at.
     *
     * @return every item the file names, templates resolved
     * @date 2026-09-17 */
    std::vector<meta_item_t> gt_meta_items() const {
        std::vector<meta_item_t> out;
        if (gt_lang.empty())
            return out;

        /* The shapes each metaitem class numbers its thousands by, and the materials. */
        std::map<std::string, std::vector<std::string>> prefixes;
        prefixes["01"] = gt_prefixes("gregtech/common/items/GT_MetaGenerated_Item_01");
        prefixes["02"] = gt_prefixes("gregtech/common/items/GT_MetaGenerated_Item_02");
        prefixes["03"] = gt_prefixes("gregtech/common/items/GT_MetaGenerated_Item_03");

        std::map<int, gt_material_t> mats = gt_materials();
        gt_shape_cache_t shapes;

        /* sub-id -> the material's name as the game shows it. The code spells it `Naquadah`; the
        lang file keys its display name by the lower-cased spelling, which is what joins them. */
        std::map<int, std::string> materials;
        for (const auto &kv : mats) {
            std::string key = kv.second.name;
            for (char &ch : key)
                ch = (char)tolower((unsigned char)ch);

            std::string shown = kv.second.name;
            size_t at = gt_lang.find("S:Material." + key + "=");
            if (at != std::string::npos) {
                size_t from = at + ("S:Material." + key + "=").size();
                size_t to = gt_lang.find_first_of("\r\n", from);
                std::string v = gt_lang.substr(from, (to == std::string::npos) ? to : to - from);
                while (!v.empty() && (v.back() == ' ' || v.back() == '\t'))
                    v.pop_back();
                if (!v.empty())
                    shown = v;
            }
            materials.emplace(kv.first, shown);
        }

        size_t at = 0;
        const std::string key = "S:gt.metaitem.";
        while ((at = gt_lang.find(key, at)) != std::string::npos) {
            size_t p = at + key.size();

            /* gt.metaitem.<NN>.<damage>.name=<value> */
            size_t nn0 = p;
            while (p < gt_lang.size() && isdigit((unsigned char)gt_lang[p])) p++;
            if (p == nn0 || p >= gt_lang.size() || gt_lang[p] != '.') { at += key.size(); continue; }
            std::string nn = gt_lang.substr(nn0, p - nn0);
            p++;

            size_t d0 = p;
            while (p < gt_lang.size() && isdigit((unsigned char)gt_lang[p])) p++;
            if (p == d0) { at += key.size(); continue; }
            int damage = atoi(gt_lang.substr(d0, p - d0).c_str());

            if (gt_lang.compare(p, 6, ".name=") != 0) { at += key.size(); continue; }
            p += 6;

            size_t end = gt_lang.find_first_of("\r\n", p);
            std::string label = gt_lang.substr(p, (end == std::string::npos) ? end : end - p);
            while (!label.empty() && (label.back() == ' ' || label.back() == '\t'))
                label.pop_back();

            at = (end == std::string::npos) ? gt_lang.size() : end;

            if (label.empty())
                continue;

            /* A template. The damage decomposes as shape * 1000 + material, so the material is
            what is left after the thousands - which is the number the map above is keyed by. */
            size_t ph = label.find("%material");
            if (ph != std::string::npos) {
                auto mat = materials.find(damage % 1000);
                if (mat == materials.end())
                    continue;
                label = label.substr(0, ph) + mat->second + label.substr(ph + 9);
            }
            /* Any other placeholder is one this does not know how to fill. */
            if (label.find('%') != std::string::npos)
                continue;

            meta_item_t mi;
            mi.id = "gregtech:gt.metaitem." + nn;
            mi.damage = damage;
            mi.label = label;

            /* And the picture the mod would draw: the shape this thousand stands for, in the
            material's texture set, tinted with the material's colour. */
            auto pit = prefixes.find(nn);
            auto mit = mats.find(damage % 1000);
            if (pit != prefixes.end() && mit != mats.end()) {
                size_t shape = (size_t)(damage / 1000);
                if (shape < pit->second.size())
                    mi.has_tile = gt_item_tile(mit->second, pit->second[shape], shapes, mi.tile);
            }

            out.push_back(std::move(mi));
        }

        size_t drawn = 0;
        for (const auto &mi : out)
            drawn += mi.has_tile ? 1 : 0;
        DBG("mc_assets: %zu gregtech metaitems, %zu of them drawn", out.size(), drawn);
        return out;
    }

    /*! The pictures for a set of registered items, gathered from EVERY jar under mods/.
     *
     * Core: art for the whole modpack, not just for vanilla. A mod puts its pictures at
     * `assets/<namespace>/textures/items/<name>.png` and registers its items as
     * `<namespace>:<name>`, so the two are joined by exactly that pair. Keys here are that pair,
     * folded to lower case, because a registry writes `Botania:manaSteel` while the asset folder
     * is spelled `botania`.
     *
     * ONE PASS PER JAR AND ONLY WHAT WAS ASKED FOR. There are two hundred and thirty-eight jars
     * and four hundred megabytes of them; each is read once, its directory listed, and a PNG is
     * decoded only when a registered item is waiting for it. Reading a jar per texture instead -
     * the obvious shape - would have read those four hundred megabytes thousands of times over.
     *
     * @param instance_dir  the instance, the one holding mods/
     * @param wanted        lower-cased `namespace:name` keys to look for
     * @return the ones that were found
     * @date 2026-09-17 */
    std::map<std::string, tile_t> mod_textures(const std::string &instance_dir,
            const std::unordered_set<std::string> &wanted) const {
        std::map<std::string, tile_t> out;
        if (instance_dir.empty() || wanted.empty())
            return out;

        std::string base = instance_dir;
        if (base.back() != '/' && base.back() != '\\')
            base += "/";

        int jars = 0;
        std::error_code ec;
        for (auto &e : std::filesystem::directory_iterator(base + "mods", ec)) {
            if (ec)
                break;
            std::string jar_path = e.path().string();
            if (jar_path.size() < 5 || jar_path.compare(jar_path.size() - 4, 4, ".jar") != 0)
                continue;

            /* Only the directory comes off disk here - a few hundred kilobytes of a jar that may
            be twenty megabytes. */
            std::vector<zip_entry_t> dir = zip_dir(jar_path);
            if (dir.empty())
                continue;
            jars++;

            for (const zip_entry_t &entry : dir) {
                const std::string &name = entry.name;
                if (name.size() < 12 || name.compare(0, 7, "assets/") != 0
                        || name.compare(name.size() - 4, 4, ".png") != 0)
                    continue;

                size_t ns1 = name.find('/', 7);
                if (ns1 == std::string::npos)
                    continue;

                std::string rest = name.substr(ns1 + 1);
                if (rest.compare(0, 15, "textures/items/") != 0
                        && rest.compare(0, 16, "textures/blocks/") != 0)
                    continue;

                std::string file = name.substr(name.rfind('/') + 1);
                std::string key = name.substr(7, ns1 - 7) + ":"
                        + file.substr(0, file.size() - 4);
                for (char &ch : key)
                    ch = (char)tolower((unsigned char)ch);

                if (!wanted.count(key) || out.count(key))
                    continue;

                /* Only now is anything actually read, and only this one entry. */
                tile_t t;
                if (png_to_tile(zip_read(jar_path, entry), t))
                    out.emplace(key, t);
            }
        }

        DBG("mc_assets: %zu pictures for %zu wanted items, across %d jars",
                out.size(), wanted.size(), jars);
        return out;
    }

    /*! Every item and block picture the vanilla jar ships, as paths under textures/.
     *
     * Entries read "items/apple" and "blocks/cobblestone" - the folder is kept because the two
     * namespaces overlap and because it is the only honest thing to call them. THESE ARE TEXTURE
     * NAMES, NOT ITEM NAMES: in 1.7.10 a golden apple's texture is apple_golden.png while the item
     * is minecraft:golden_apple, and only sixty-five of the five hundred and sixty-three textures
     * have a matching lang key at all. Whatever uses this must say so rather than passing a texture
     * name off as a registry name.
     * @date 2026-09-17 */
    std::vector<std::string> vanilla_texture_names() const {
        std::vector<std::string> out;
        if (!vanilla_open())
            return out;

        const std::string root = "assets/minecraft/textures/";
        for (const char *dir : {"items/", "blocks/"}) {
            std::string prefix = root + dir;
            for (const std::string &entry : zip_list(vanilla, prefix)) {
                std::string rel = entry.substr(root.size());
                if (rel.size() < 5 || rel.compare(rel.size() - 4, 4, ".png") != 0)
                    continue;
                /* Animated textures are tall strips and the .mcmeta beside them says so; the
                decoder below takes what it is given, so a strip would arrive squashed. They are
                kept anyway - a squashed picture of fire is still recognisably fire, and dropping
                them would lose water and lava, which are exactly what a person wants to put in a
                chest to test with. */
                out.push_back(rel.substr(0, rel.size() - 4));
            }
        }
        std::sort(out.begin(), out.end());
        return out;
    }

    /*! One of those pictures, by the path vanilla_texture_names gave. @date 2026-09-17 */
    bool vanilla_texture_tile(const std::string &rel, tile_t &out) const {
        if (!vanilla_open())
            return false;
        return png_to_tile(zip_extract(vanilla, "assets/minecraft/textures/" + rel + ".png"), out);
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
