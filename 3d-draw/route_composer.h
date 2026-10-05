#ifndef ROUTE_COMPOSER_H
#define ROUTE_COMPOSER_H
/*! route_composer.h - the pathfinder (3d-draw/redesign/09-paths.md): a byte a cell over a box of
 * chunks, read straight from the chunk files, and A* over it in server ticks.
 *
 *     vc.route_load(dir, cx0, cx1, cz0, cz1, ax, ay, az, layers)   cells known, or -1
 *         the chunk files c<cx>_<cz>.txt of that rectangle, in world coordinates; ax ay az the
 *         start block (robot 0 0 0); layers: files laid over them, "\n" between (built, fixed)
 *     vc.route_get(x, y, z)          0 never scanned, 1 air, 2 a block, 3 a liquid; -1 outside
 *     vc.route_set(x, y, z, state)   a cell changed: placed, dug, scanned
 *     vc.route_find(x, y, z, facing, tx, ty, tz, limit)   the way in the program's notation,
 *         "" when none within `limit` cells looked at; facing 0 n, 1 e, 2 s, 3 w
 *     vc.route_snapshot() / vc.route_restore()   the grid kept aside and put back: a simulated
 *         build places and digs in the grid, and the real map must come back as it was
 *
 * Robot coordinates throughout, as every plan and program. Only air is walked: a block is never
 * dug on the way (03-exec.md), water is the PC's to keep out of, an unscanned cell is no one's to
 * guess. Above the highest cell scanned in a chunk counts as air - the sky.
 *
 * Costs, from docs/speed.md (OpenComputers 1.9.14, the server at 13 TPS): a step 13 ticks, up or
 * down 12, a quarter turn 11 more (a step needs the robot to face its way; up and down do not).
 *
 * @date 2026-10-05 */

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <queue>
#include <sstream>
#include <string>
#include <unordered_map>
#include <vector>

#include "virt_composer.h"
#include "debug.h"

namespace route_composer {

namespace vc = virt_composer;

enum : uint8_t { UNKNOWN = 0, AIR = 1, BLOCK = 2, LIQUID = 3 };

struct grid_t {
    int x0 = 0, y0 = 0, z0 = 0, sx = 0, sy = 0, sz = 0;    /* robot coordinates */
    std::vector<uint8_t> c;
    bool in(int x, int y, int z) const {
        return x >= x0 && y >= y0 && z >= z0 && x < x0 + sx && y < y0 + sy && z < z0 + sz;
    }
    size_t at(int x, int y, int z) const {
        return ((size_t)(z - z0) * sy + (size_t)(y - y0)) * sx + (size_t)(x - x0);
    }
};

inline grid_t g_grid;
inline std::vector<uint8_t> g_saved;           /* route_snapshot's copy of the cells */

inline bool is_liquid(const std::string &name) {
    return name.find("water") != std::string::npos || name.find("lava") != std::string::npos;
}

/*! One chunk file into the grid. Its own palette numbers its blocks; 0 is air, a negative a cell
 * never scanned. Above its box's top, the sky. @date 2026-10-05 */
inline int load_chunk(const std::string &path, int ax, int ay, int az) {
    std::ifstream f(path);
    if (!f)
        return 0;
    std::string line;
    std::unordered_map<int, uint8_t> pal;
    std::vector<std::string> layers;
    int bx0 = 0, by1 = 0, bz0 = 0, bx1 = 0, by0 = 0, bz1 = 0;
    bool have_box = false;
    while (std::getline(f, line)) {
        if (line.rfind("box ", 0) == 0) {
            have_box = sscanf(line.c_str(), "box x %d %d y %d %d z %d %d", &bx0, &bx1, &by0, &by1,
                              &bz0, &bz1) == 6;
        }
        else if (line.rfind("palette ", 0) == 0) {
            int id = 0, meta = 0;
            char name[256] = {};
            if (sscanf(line.c_str(), "palette %d %255s %d", &id, name, &meta) >= 2)
                pal[id] = is_liquid(name) ? LIQUID : BLOCK;
        }
        else if (line.rfind("layer ", 0) == 0) {
            layers.push_back(line);
        }
    }
    if (!have_box)
        return 0;
    grid_t &g = g_grid;
    int n = 0;
    for (const std::string &l : layers) {
        int y = 0;
        size_t sp = l.find(' ', 6);
        if (sp == std::string::npos)
            continue;
        y = atoi(l.c_str() + 6);
        int ry = y - ay;
        size_t i = sp + 1;
        int zi = 0, xi = 0;
        while (i <= l.size()) {
            size_t j = i;
            while (j < l.size() && l[j] != ',' && l[j] != ';')
                j++;
            if (j > i) {
                int v = atoi(l.c_str() + i);
                int rx = bx0 + xi - ax, rz = bz0 + zi - az;
                if (v >= 0 && g.in(rx, ry, rz)) {
                    uint8_t s = v == 0 ? AIR : (pal.count(v) ? pal[v] : BLOCK);
                    g.c[g.at(rx, ry, rz)] = s;
                    n++;
                }
            }
            if (j >= l.size())
                break;
            if (l[j] == ';') {
                zi++;
                xi = 0;
            }
            else {
                xi++;
            }
            i = j + 1;
        }
    }
    /* the sky over the chunk: above all it scanned */
    for (int wx = bx0; wx <= bx1; wx++)
        for (int wz = bz0; wz <= bz1; wz++)
            for (int ry = by1 + 1 - ay; ry < g.y0 + g.sy; ry++) {
                int rx = wx - ax, rz = wz - az;
                if (g.in(rx, ry, rz) && g.c[g.at(rx, ry, rz)] == UNKNOWN)
                    g.c[g.at(rx, ry, rz)] = AIR;
            }
    return n;
}

/*! A layer file (built.txt, fixed.txt): `x y z name ...` a line, world coordinates, over all.
 * @date 2026-10-05 */
inline void load_layer(const std::string &path, int ax, int ay, int az) {
    std::ifstream f(path);
    std::string line;
    while (std::getline(f, line)) {
        int x = 0, y = 0, z = 0;
        char name[256] = {};
        if (sscanf(line.c_str(), "%d %d %d %255s", &x, &y, &z, name) != 4)
            continue;
        int rx = x - ax, ry = y - ay, rz = z - az;
        if (!g_grid.in(rx, ry, rz))
            continue;
        std::string nm = name;
        g_grid.c[g_grid.at(rx, ry, rz)] = nm == "minecraft:air" ? AIR
                : is_liquid(nm) ? LIQUID : BLOCK;
    }
}

inline double route_load(std::string dir, int64_t cx0, int64_t cx1, int64_t cz0, int64_t cz1,
                         int64_t ax, int64_t ay, int64_t az, std::string layers) {
    grid_t &g = g_grid;
    g.x0 = (int)(cx0 * 16 - ax);
    g.z0 = (int)(cz0 * 16 - az);
    g.y0 = (int)(0 - ay);
    g.sx = (int)((cx1 - cx0 + 1) * 16);
    g.sz = (int)((cz1 - cz0 + 1) * 16);
    g.sy = 256;
    if (g.sx <= 0 || g.sz <= 0 || (size_t)g.sx * g.sz * g.sy > (size_t)64 << 20)
        return -1;
    g.c.assign((size_t)g.sx * g.sy * g.sz, UNKNOWN);
    int n = 0;
    for (int64_t i = cx0; i <= cx1; i++)
        for (int64_t j = cz0; j <= cz1; j++)
            n += load_chunk(dir + "/c" + std::to_string(i) + "_" + std::to_string(j) + ".txt",
                            (int)ax, (int)ay, (int)az);
    std::stringstream ls(layers);
    std::string path;
    while (std::getline(ls, path))
        if (!path.empty())
            load_layer(path, (int)ax, (int)ay, (int)az);
    return (double)n;
}

inline int route_snapshot() {
    g_saved = g_grid.c;
    return (int)g_saved.size();
}

inline int route_restore() {
    if (g_saved.size() != g_grid.c.size())
        return 0;
    g_grid.c = g_saved;
    return 1;
}

inline int route_get(int64_t x, int64_t y, int64_t z) {
    if (!g_grid.in((int)x, (int)y, (int)z))
        return -1;
    return g_grid.c[g_grid.at((int)x, (int)y, (int)z)];
}

inline int route_set(int64_t x, int64_t y, int64_t z, int64_t state) {
    if (!g_grid.in((int)x, (int)y, (int)z))
        return 0;
    g_grid.c[g_grid.at((int)x, (int)y, (int)z)] = (uint8_t)state;
    return 1;
}

/* n e s w, then up, down: the steps, their characters, and the facing a step leaves */
static const int DX[6] = {0, 1, 0, -1, 0, 0}, DY[6] = {0, 0, 0, 0, 1, -1},
                 DZ[6] = {-1, 0, 1, 0, 0, 0};
static const char CH[6] = {'^', '>', 'v', '<', '+', '-'};

/*! The cheapest way through air, A* on (cell, facing). @date 2026-10-05 */
inline std::string route_find(int64_t x, int64_t y, int64_t z, int64_t facing, int64_t tx,
                              int64_t ty, int64_t tz, int64_t limit) {
    grid_t &g = g_grid;
    if (!g.in((int)x, (int)y, (int)z) || !g.in((int)tx, (int)ty, (int)tz))
        return std::string();
    if (x == tx && y == ty && z == tz)
        return std::string(".");
    if (g.c[g.at((int)tx, (int)ty, (int)tz)] != AIR)
        return std::string();
    /* only the states looked at, not the whole grid: a route is short beside the map */
    struct node_t { uint32_t cost = UINT32_MAX; uint32_t from = UINT32_MAX; int8_t how = -1; };
    std::unordered_map<uint32_t, node_t> seen;
    seen.reserve(4096);
    auto heur = [&](int ax, int ay, int az) {
        return (uint32_t)(12 * (std::abs(ax - (int)tx) + std::abs(ay - (int)ty)
                                + std::abs(az - (int)tz)));
    };
    using item = std::pair<uint32_t, uint32_t>;          /* f, state */
    std::priority_queue<item, std::vector<item>, std::greater<item>> open;
    uint32_t s0 = (uint32_t)(g.at((int)x, (int)y, (int)z) * 4 + (size_t)(facing & 3));
    seen[s0].cost = 0;
    open.push({heur((int)x, (int)y, (int)z), s0});
    int64_t looked = 0;
    uint32_t goal = UINT32_MAX;
    while (!open.empty() && looked < limit) {
        auto [f, st] = open.top();
        open.pop();
        size_t ci = st / 4;
        int fc = (int)(st % 4);
        int cz = (int)(ci / ((size_t)g.sy * g.sx)) + g.z0;
        int cy = (int)((ci / (size_t)g.sx) % (size_t)g.sy) + g.y0;
        int cx = (int)(ci % (size_t)g.sx) + g.x0;
        uint32_t here = seen[st].cost;
        if (f > here + heur(cx, cy, cz))
            continue;                                        /* a stale entry */
        looked++;
        if (cx == tx && cy == ty && cz == tz) {
            goal = st;
            break;
        }
        for (int d = 0; d < 6; d++) {
            int nx = cx + DX[d], ny = cy + DY[d], nz = cz + DZ[d];
            if (!g.in(nx, ny, nz) || g.c[g.at(nx, ny, nz)] != AIR)
                continue;
            uint32_t step;
            int nf = fc;
            if (d < 4) {
                int turns = (d - fc + 4) % 4;
                turns = turns == 3 ? 1 : turns;
                step = 13 + 11 * (uint32_t)turns;
                nf = d;
            }
            else {
                step = 12;
            }
            uint32_t ns = (uint32_t)(g.at(nx, ny, nz) * 4 + (size_t)nf);
            uint32_t nc = here + step;
            node_t &n = seen[ns];
            if (nc < n.cost) {
                n.cost = nc;
                n.from = st;
                n.how = (int8_t)d;
                open.push({nc + heur(nx, ny, nz), ns});
            }
        }
    }
    if (goal == UINT32_MAX)
        return std::string();
    std::vector<int> dirs;
    for (uint32_t st = goal; st != s0; st = seen[st].from)
        dirs.push_back(seen[st].how);
    std::string out;
    for (size_t i = dirs.size(); i-- > 0;) {
        int d = dirs[i];
        size_t run = 1;
        while (i > 0 && dirs[i - 1] == d) {
            run++;
            i--;
        }
        out += CH[d];
        if (run > 1)
            out += std::to_string(run);
    }
    return out;
}

inline int register_meta(vc::virt_state_t *vs) {
    DBG_SCOPE();
    std::vector<luaL_Reg> funcs = {
        {"route_load", vc::luaw_function_wrapper<route_load, std::string, int64_t, int64_t,
                int64_t, int64_t, int64_t, int64_t, int64_t, std::string>},
        {"route_get",  vc::luaw_function_wrapper<route_get, int64_t, int64_t, int64_t>},
        {"route_snapshot", vc::luaw_function_wrapper<route_snapshot>},
        {"route_restore",  vc::luaw_function_wrapper<route_restore>},
        {"route_set",  vc::luaw_function_wrapper<route_set, int64_t, int64_t, int64_t, int64_t>},
        {"route_find", vc::luaw_function_wrapper<route_find, int64_t, int64_t, int64_t, int64_t,
                int64_t, int64_t, int64_t, int64_t>},
    };
    ASSERT_FN(vc::add_lua_tab_funcs(vs, funcs));
    return 0;
}

}; /* namespace route_composer */

#endif /* ROUTE_COMPOSER_H */
