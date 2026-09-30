#ifndef MCA_READER_H
#define MCA_READER_H

/*! mca_reader.h - reads a Minecraft 1.7.10 region file well enough to find the things in it.
 *
 * Core: THIS IS FOR LOOKING AT A REAL WORLD, not for running one. The simulator's own map is its
 * own format; this exists so a scenario can be pointed at a server's `r.X.Z.mca` and shown what is
 * actually built there - which is what turns "my ME network stops sometimes" from an argument into
 * a measurement.
 *
 * What it does: the region header, one chunk's zlib stream, and a real NBT walk to pull out the
 * TileEntities. What it deliberately does not do: blocks, entities, or anything needing the section
 * arrays. A tile entity is where the interesting state lives.
 *
 * Deliberately ignorant of Applied Energistics, the same way class_reader.h is ignorant of
 * GregTech: it hands back every tile entity with its compound flattened to the few fields anyone
 * has needed, and the caller decides what an "ae2 node" is.
 *
 * @date 2026-09-18 */

#include "virt_composer.h"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>

/*! The two inflate entries out of stb_image, declared rather than included.
 *
 * mc_assets.h already brings stb_image in WITH its implementation, and pulling the header a second
 * time in the same translation unit gives every function two bodies. Declaring the pair keeps this
 * header from caring about include order beyond "somebody defined them". @date 2026-09-18 */
extern char *stbi_zlib_decode_malloc(const char *buffer, int len, int *outlen);
extern char *stbi_zlib_decode_noheader_malloc(const char *buffer, int len, int *outlen);

namespace mca_reader {

namespace vc = virt_composer;

/*! One tile entity, reduced to what a debugging view asks of it.
 *
 * `grid` is Applied Energistics' grid storage id, taken from the `proxy/g` long that every AE2
 * node writes - see appeng/me/GridNode.saveToNBT, which stores `p` (the owning player), `k` (a
 * security key) and `g`. Minus one when the tile is not an AE2 node at all.
 * @date 2026-09-18 */
struct tile_t {
    int x = 0, y = 0, z = 0;
    std::string id;
    long long grid = -1;

    /*! Which face of a cable bus this came off, or -1 for a tile that is simply itself.
     *
     * Applied Energistics keeps a whole cable bus in ONE tile entity: `def:6` and `extra:6` are the
     * cable through the middle, `def:0` through `def:5` the parts on the six faces. So one block in
     * the world is up to seven things on the network, each with a grid of its own - which is why a
     * reader that returned one row per tile entity found no cables at all and drew a network as a
     * cloud of unconnected devices. @date 2026-09-18 */
    int slot = -1;

    /*! How many channels this carrier is actually using, straight out of the save, or -1.
     *
     * Worth more than any estimate: it is what the network decided, not what a path walk guessed.
     * @date 2026-09-18 */
    int chan = -1;

    /*! Which way the block points, as a Forge direction, or -1 when it does not say.
     *
     * AE2 writes `orientation_forward` as a name - "NORTH", "UP", "UNKNOWN" - on every block that
     * has a front. A drive drawn without it faces whichever way the simulator felt like, which is
     * worse than no facing at all: it states something untrue about a block somebody is about to go
     * and look at. @date 2026-09-18 */
    int facing = -1;

    /*! How many it COULD carry - eight for a plain cable, thirty-two for a dense one, nought for a
     * part that consumes one rather than carrying them, -1 where the question does not apply.
     * @date 2026-09-18 */
    int cap = -1;
};

/* --- NBT --------------------------------------------------------------------------------------
 * Big endian, tag-prefixed, no alignment. The walk has to be exact: a single mis-sized payload
 * desynchronises the rest of the file and what comes out afterwards is plausible nonsense rather
 * than an error, which is the same trap the class-file opcode table set. */

enum nbt_tag_e {
    NBT_END = 0, NBT_BYTE, NBT_SHORT, NBT_INT, NBT_LONG, NBT_FLOAT, NBT_DOUBLE,
    NBT_BARRAY, NBT_STRING, NBT_LIST, NBT_COMPOUND, NBT_IARRAY,
};

struct cursor_t {
    const uint8_t *p = nullptr;
    size_t n = 0, at = 0;
    bool bad = false;

    bool want(size_t k) {
        if (bad || at + k > n) {
            bad = true;
            return false;
        }
        return true;
    }
    uint8_t u8() { return want(1) ? p[at++] : 0; }
    int16_t i16() {
        if (!want(2)) return 0;
        int16_t v = (int16_t)((p[at] << 8) | p[at + 1]);
        at += 2;
        return v;
    }
    int32_t i32() {
        if (!want(4)) return 0;
        int32_t v = (int32_t)(((uint32_t)p[at] << 24) | ((uint32_t)p[at + 1] << 16)
                | ((uint32_t)p[at + 2] << 8) | (uint32_t)p[at + 3]);
        at += 4;
        return v;
    }
    long long i64() {
        if (!want(8)) return 0;
        unsigned long long v = 0;
        for (int i = 0; i < 8; i++)
            v = (v << 8) | p[at + i];
        at += 8;
        return (long long)v;
    }
    std::string str() {
        int len = (uint16_t)i16();
        if (!want((size_t)len))
            return std::string();
        std::string s((const char *)p + at, (size_t)len);
        at += (size_t)len;
        return s;
    }
};

/*! Steps over one payload without interpreting it. @date 2026-09-18 */
inline void nbt_skip(cursor_t &c, int tag);

/*! Walks a compound, calling `fn(name, tag, cursor)` for each member. The callback either consumes
 * the payload itself or leaves it, in which case this skips it. @date 2026-09-18 */
template <typename F>
inline void nbt_compound(cursor_t &c, F fn) {
    while (!c.bad) {
        int tag = c.u8();
        if (tag == NBT_END || c.bad)
            return;
        std::string name = c.str();
        size_t before = c.at;
        if (!fn(name, tag, c) && c.at == before)
            nbt_skip(c, tag);
    }
}

inline void nbt_skip(cursor_t &c, int tag) {
    switch (tag) {
        case NBT_BYTE:   c.u8(); break;
        case NBT_SHORT:  c.i16(); break;
        case NBT_INT:    c.i32(); break;
        case NBT_LONG:   c.i64(); break;
        case NBT_FLOAT:  c.i32(); break;
        case NBT_DOUBLE: c.i64(); break;
        case NBT_BARRAY: {
            int n = c.i32();
            if (n > 0 && c.want((size_t)n)) c.at += (size_t)n;
            break;
        }
        case NBT_STRING: c.str(); break;
        case NBT_LIST: {
            int et = c.u8();
            int n = c.i32();
            for (int i = 0; i < n && !c.bad; i++)
                nbt_skip(c, et);
            break;
        }
        case NBT_COMPOUND:
            nbt_compound(c, [](const std::string &, int, cursor_t &) { return false; });
            break;
        case NBT_IARRAY: {
            int n = c.i32();
            if (n > 0 && c.want((size_t)n * 4)) c.at += (size_t)n * 4;
            break;
        }
        default: c.bad = true; break;
    }
}

/* --- the region file --------------------------------------------------------------------------- */

/*! Reads a whole file. @date 2026-09-18 */
inline std::vector<uint8_t> slurp(const std::string &path) {
    std::vector<uint8_t> out;
    FILE *f = fopen(path.c_str(), "rb");
    if (!f)
        return out;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (n > 0) {
        out.resize((size_t)n);
        if (fread(out.data(), 1, (size_t)n, f) != (size_t)n)
            out.clear();
    }
    fclose(f);
    return out;
}

/*! Inflates one chunk out of a region file.
 *
 * The layout: 4 KiB of locations (a three byte sector offset and a sector count each), 4 KiB of
 * timestamps, then the chunks. A chunk begins with its length and a compression byte - 1 for gzip,
 * 2 for zlib, and zlib is what Minecraft actually writes.
 * @date 2026-09-18 */
inline std::vector<uint8_t> chunk_nbt(const std::vector<uint8_t> &reg, int cx, int cz) {
    std::vector<uint8_t> out;
    int idx = (cx & 31) + (cz & 31) * 32;
    if (reg.size() < 8192)
        return out;

    size_t e = (size_t)idx * 4;
    uint32_t off = ((uint32_t)reg[e] << 16) | ((uint32_t)reg[e + 1] << 8) | reg[e + 2];
    if (off == 0)
        return out;                                 /* never generated */

    size_t base = (size_t)off * 4096;
    if (base + 5 > reg.size())
        return out;
    uint32_t len = ((uint32_t)reg[base] << 24) | ((uint32_t)reg[base + 1] << 16)
            | ((uint32_t)reg[base + 2] << 8) | reg[base + 3];
    uint8_t comp = reg[base + 4];
    if (len < 1 || base + 4 + len > reg.size())
        return out;

    const char *src = (const char *)reg.data() + base + 5;
    int src_n = (int)len - 1;
    int got = 0;
    char *raw = nullptr;

    if (comp == 2) {
        raw = stbi_zlib_decode_malloc(src, src_n, &got);
    }
    else if (comp == 1) {
        /* gzip: ten fixed bytes then the deflate stream, the same skip mc_assets does for
        level.dat. Minecraft does not write these, but a hand-edited world can carry them. */
        if (src_n > 18)
            raw = stbi_zlib_decode_noheader_malloc(src + 10, src_n - 10, &got);
    }
    if (!raw || got <= 0) {
        if (raw) free(raw);
        return out;
    }
    out.assign((const uint8_t *)raw, (const uint8_t *)raw + got);
    free(raw);
    return out;
}

/*! What an Applied Energistics part is, from the damage value of its item.
 *
 * Core: AE2 KEEPS EVERY PART IN ONE ITEM and tells them apart by damage - twenty values per type,
 * one per colour, so the type is the damage rounded down to its block. The table is
 * appeng/items/parts/PartType's own, bases and all; the P2P tunnels sit one apart rather than
 * twenty because there are more of them than there are colours.
 *
 * It matters beyond labelling: a cable's type IS its channel capacity. Glass, covered and smart
 * carry eight, dense carries thirty-two, and a network drawn without that distinction cannot show
 * you which run is full.
 * @date 2026-09-18 */
inline const char *part_name(int damage, int *channels) {
    struct row_t { int base, span; const char *name; int chan; };
    static const row_t TABLE[] = {
        {  0, 20, "Glass Cable",        8},
        { 20, 20, "Covered Cable",      8},
        { 40, 20, "Smart Cable",        8},
        { 60, 20, "Dense Cable",       32},
        {520, 20, "Dense Covered",     32},
        {540, 20, "Ultra Dense Cov",   32},
        {560, 20, "Ultra Dense Smart", 32},
        { 80, 20, "Toggle Bus",         0},
        {100, 20, "Inv Toggle Bus",     0},
        {120, 20, "Cable Anchor",      -1},
        {140, 20, "Quartz Fiber",      -1},
        {160, 20, "Monitor",            0},
        {180, 20, "Semi Dark Monitor",  0},
        {200, 20, "Dark Monitor",       0},
        {220, 20, "Storage Bus",        0},
        {240, 20, "Import Bus",         0},
        {260, 20, "Export Bus",         0},
        {280, 20, "Level Emitter",      0},
        {300,  1, "Annihilation Plane", 0},
        {301, 19, "Id Annih Plane",     0},
        {320, 20, "Formation Plane",    0},
        {340, 20, "Pattern Terminal",   0},
        {360, 20, "Crafting Terminal",  0},
        {380, 20, "Terminal",           0},
        {400, 20, "Storage Monitor",    0},
        {420, 20, "Conversion Monitor", 0},
        {440, 20, "Interface",          0},
        {460, 12, "P2P Tunnel",         0},
        {480, 20, "Interface Terminal", 0},
        {500, 20, "Pattern Term Ex",    0},
    };
    const row_t *best = nullptr;
    for (const row_t &r : TABLE)
        if (damage >= r.base && damage < r.base + r.span)
            if (!best || r.base > best->base)
                best = &r;
    if (channels)
        *channels = best ? best->chan : 0;
    return best ? best->name : "part";
}

/*! Every tile entity in one chunk, with cable buses broken into their parts.
 *
 * Core: A BLOCK IS NOT A NODE. AE2 packs a cable and up to six parts into one tile entity, and
 * EnderIO packs several conduits of different kinds into one bundle - so the interesting things are
 * a level below where a naive walk stops. Both are unpacked here.
 *
 * What comes out, per row:
 *   - an ordinary device: its tile id, and the grid from `proxy/g`
 *   - a cable bus part:   "ae:cable" or a guess at the part, the grid from `extra:N/part/g`
 *   - an EnderIO bundle:  "eio:me" once, if any of its conduits is an ME one
 *
 * The part guess is by the fields the part saved rather than by its item damage, which is a number
 * only the modpack can interpret: a storage bus keeps a STORAGE_FILTER, an interface keeps
 * patterns. Anything else is just "ae:part", which still draws in the right place on the right
 * face.
 * @date 2026-09-18 */
inline void chunk_tiles(const std::vector<uint8_t> &nbt, std::vector<tile_t> &out) {
    if (nbt.empty())
        return;
    cursor_t c{nbt.data(), nbt.size(), 0, false};

    if (c.u8() != NBT_COMPOUND)
        return;
    c.str();                                        /* the root's name */

    nbt_compound(c, [&](const std::string &name, int tag, cursor_t &cc) {
        if (name != "Level" || tag != NBT_COMPOUND)
            return false;

        nbt_compound(cc, [&](const std::string &lname, int ltag, cursor_t &lc) {
            if (lname != "TileEntities" || ltag != NBT_LIST)
                return false;

            int et = lc.u8();
            int n = lc.i32();
            for (int i = 0; i < n && !lc.bad; i++) {
                if (et != NBT_COMPOUND) {
                    nbt_skip(lc, et);
                    continue;
                }

                tile_t base;
                std::vector<tile_t> parts;          /* a cable bus contributes several */
                int def_damage[7] = {-1, -1, -1, -1, -1, -1, -1};
                bool me_conduit = false, me_dense = false;

                nbt_compound(lc, [&](const std::string &f, int ft, cursor_t &fc) {
                    if (f == "x" && ft == NBT_INT) { base.x = fc.i32(); return true; }
                    if (f == "y" && ft == NBT_INT) { base.y = fc.i32(); return true; }
                    if (f == "z" && ft == NBT_INT) { base.z = fc.i32(); return true; }
                    if (f == "id" && ft == NBT_STRING) { base.id = fc.str(); return true; }

                    if (f == "orientation_forward" && ft == NBT_STRING) {
                        static const char *DIRS[6] = {"DOWN", "UP", "NORTH",
                                                      "SOUTH", "WEST", "EAST"};
                        std::string d = fc.str();
                        for (int k = 0; k < 6; k++)
                            if (d == DIRS[k])
                                base.facing = k;
                        return true;
                    }

                    if (f == "proxy" && ft == NBT_COMPOUND) {
                        nbt_compound(fc, [&](const std::string &pn, int pt, cursor_t &pc) {
                            if (pn == "g" && pt == NBT_LONG) { base.grid = pc.i64(); return true; }
                            return false;
                        });
                        return true;
                    }

                    /* def:<slot> is the part's ITEM - what it is - and extra:<slot> its state. */
                    if (ft == NBT_COMPOUND && f.rfind("def:", 0) == 0) {
                        int slot = atoi(f.c_str() + 4);
                        nbt_compound(fc, [&](const std::string &dn, int dt, cursor_t &dc) {
                            if (dn == "Damage" && dt == NBT_SHORT && slot >= 0 && slot < 7) {
                                def_damage[slot] = (uint16_t)dc.i16();
                                return true;
                            }
                            return false;
                        });
                        return true;
                    }

                    /* A cable bus part: extra:<slot> carries the grid and the channel count. */
                    if (ft == NBT_COMPOUND && f.rfind("extra:", 0) == 0) {
                        tile_t part;
                        part.slot = atoi(f.c_str() + 6);
                        part.id = (part.slot == 6) ? "ae:cable" : "ae:part";
                        nbt_compound(fc, [&](const std::string &pn, int pt, cursor_t &pc) {
                            if (pn == "part" && pt == NBT_COMPOUND) {
                                nbt_compound(pc, [&](const std::string &q, int qt, cursor_t &qc) {
                                    if (q == "g" && qt == NBT_LONG) {
                                        part.grid = qc.i64();
                                        return true;
                                    }
                                    return false;
                                });
                                return true;
                            }
                            /* A byte in practice, an int in principle: AE2 writes whichever the
                            value fits in, and reading only one of the two silently returns nothing
                            for every cable in the world. */
                            if (pn == "usedChannels") {
                                if (pt == NBT_BYTE) { part.chan = pc.u8(); return true; }
                                if (pt == NBT_SHORT) { part.chan = pc.i16(); return true; }
                                if (pt == NBT_INT) { part.chan = pc.i32(); return true; }
                            }
                            /* What the part saved says what it is, where its item id cannot. */
                            if (pn == "STORAGE_FILTER") { part.id = "ae:storagebus"; }
                            if (pn == "patterns")       { part.id = "ae:interface"; }
                            return false;
                        });
                        parts.push_back(part);
                        return true;
                    }

                    /* An EnderIO bundle: one row if any conduit in it carries the ME network. */
                    if (f == "conduits" && ft == NBT_LIST) {
                        int cet = fc.u8();
                        int cn = fc.i32();
                        for (int k = 0; k < cn && !fc.bad; k++) {
                            if (cet != NBT_COMPOUND) {
                                nbt_skip(fc, cet);
                                continue;
                            }
                            bool this_is_me = false;
                            nbt_compound(fc, [&](const std::string &q, int qt, cursor_t &qc) {
                                if (q == "conduitType" && qt == NBT_STRING) {
                                    std::string t = qc.str();
                                    if (t.size() >= 9
                                            && t.compare(t.size() - 9, 9, "MEConduit") == 0) {
                                        me_conduit = true;
                                        this_is_me = true;
                                    }
                                    return true;
                                }
                                /* The dense flag lives inside the conduit's own compound. */
                                if (q == "conduit" && qt == NBT_COMPOUND) {
                                    nbt_compound(qc, [&](const std::string &e, int etg,
                                            cursor_t &ec) {
                                        if (e == "isDense" && this_is_me) {
                                            if (etg == NBT_BYTE) {
                                                me_dense = ec.u8() != 0;
                                                return true;
                                            }
                                        }
                                        return false;
                                    });
                                    return true;
                                }
                                return false;
                            });
                        }
                        return true;
                    }
                    return false;
                });

                if (me_conduit) {
                    /*! AN ENDERIO CONDUIT IS NOT AN AE2 CABLE, and the two must never be reported
                     * as one thing. The author, 2026-09-18: "be sure to not confuse the glass cable
                     * with the Dense ME Conduit from Ender IO".
                     *
                     * They look alike on a network and are utterly different objects: an AE2 cable
                     * is a PART inside a cable bus, saved with the channels it is carrying; an
                     * EnderIO conduit is one of several conduits sharing a bundle, carries no grid
                     * id of its own, and never writes down its channel use. So it is named for what
                     * it is, and its load reads as unknown rather than as nought.
                     *
                     * Its capacity is real though: MEConduitGrid.getFlags hands AE2
                     * GridFlags.DENSE_CAPACITY when the conduit is dense, so AE2 treats it as
                     * thirty-two channel cable and eight when it is not. */
                    tile_t t = base;
                    t.id = me_dense ? "EIO Dense ME" : "EIO ME Conduit";
                    t.cap = me_dense ? 32 : 8;
                    out.push_back(t);
                }
                else if (!parts.empty()) {
                    for (tile_t &part : parts) {
                        part.x = base.x; part.y = base.y; part.z = base.z;
                        /* The item says what it is far better than the state does: a storage bus
                        guessed from its filter is a storage bus, but a glass cable and a dense one
                        are indistinguishable by state and differ by twenty-four channels. */
                        if (part.slot >= 0 && part.slot < 7 && def_damage[part.slot] >= 0) {
                            int cap = 0;
                            part.id = part_name(def_damage[part.slot], &cap);
                            part.cap = cap;
                        }
                        out.push_back(part);
                    }
                }
                else {
                    out.push_back(base);
                }
            }
            return true;
        });
        return true;
    });
}

/*! Every tile entity across a rectangle of chunks of one region file.
 *
 * Chunk coordinates are absolute, the way a player reads them off F3; the region is whichever one
 * the path names, and chunks outside it simply come back empty.
 * @date 2026-09-18 */
inline std::vector<tile_t> region_tiles(const std::string &path,
        int cx0, int cz0, int cx1, int cz1)
{
    std::vector<tile_t> out;
    std::vector<uint8_t> reg = slurp(path);
    if (reg.empty()) {
        DBG("mca: cannot read %s", path.c_str());
        return out;
    }
    for (int cx = cx0; cx <= cx1; cx++)
        for (int cz = cz0; cz <= cz1; cz++)
            chunk_tiles(chunk_nbt(reg, cx, cz), out);

    DBG("mca: %zu tile entities from %s, chunks %d,%d..%d,%d",
            out.size(), path.c_str(), cx0, cz0, cx1, cz1);
    return out;
}

} /* namespace mca_reader */

#endif /* MCA_READER_H */
