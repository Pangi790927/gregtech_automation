#ifndef RENDER_COMPOSER_H
#define RENDER_COMPOSER_H

/*! render_composer.h - the 3D view: a camera Lua steers, a texture atlas built from the Minecraft
 * instance or from hand-drawn stand-ins, and the mesh the world is drawn as.
 *
 * Core: Lua never sees a texture. It says where the camera is and asks for the world to be drawn;
 * which pixels a face gets is decided here, from the cell's kind, state and facing. That split is
 * the author's, 2026-09-16: "lua doesn't know much about textures". What Lua does own is the
 * Minecraft path, which arrives as a string from its settings file and is all this layer needs to
 * go looking.
 *
 * The camera's convention lives here too, in cam_forward() and cam_right(), rather than being
 * rebuilt in Lua from yaw and pitch. Lua needs those vectors to walk and to cast a ray, and the
 * renderer needs them to build a view matrix; if the two ever disagreed, the crosshair would stop
 * pointing at what the ray hits. One definition removes the possibility.
 *
 * Face culling is deliberately left off. The cubes are closed solids drawn with a depth test, so
 * culling would only save fill rate at this scale, while a quad wound the wrong way would punch a
 * hole in a block. Correctness is worth more here than the triangles it saves.
 *
 * @date 2026-09-16 */

#include "virt_composer.h"
#include "gl_util.h"
#include "mc_assets.h"
#include "world_composer.h"

#include <cmath>
#include <string>
#include <tuple>
#include <vector>

namespace render_composer {

namespace vc = virt_composer;
namespace glu = gl_util;
namespace mca = mc_assets;
namespace worldc = world_composer;
namespace renderc = render_composer;

/*! How bright each face direction is drawn, indexed by world_composer::face_e.
 *
 * A fixed brightness per direction rather than a light source: it is what Minecraft does, it needs
 * no normals in the shader, and it is what makes an untextured grey cube still read as a cube.
 * @date 2026-09-16 */
constexpr float FACE_SHADE[worldc::FACE_COUNT] = {
    0.62f, 0.62f,   /* -X, +X */
    0.50f, 1.00f,   /* -Y, +Y */
    0.80f, 0.80f,   /* -Z, +Z */
};

/*! Which of a cell's textures a face wants. A cell has four distinct surfaces at most - the face it
 * points with, the one opposite, its top and bottom, and everything else - so the atlas is indexed
 * by this rather than by all six faces. @date 2026-09-16 */
enum tex_role_e : int {
    ROLE_FRONT = 0, ROLE_BACK = 1, ROLE_TOP = 2, ROLE_SIDE = 3, ROLE_COUNT = 4,
};

/*! How many cell kinds the tile table has room for. Room to spare on purpose - see tile_cell.
 * @date 2026-09-17 */
constexpr int KIND_MAX = 32;

/*! The corners of each face, as offsets inside the unit cube, in the order bottom-left,
 * bottom-right, top-right, top-left as seen from outside the cube.
 *
 * Written out rather than derived so the texture orientation is visible: the first two corners are
 * the bottom edge of the image and the last two are its top, which is what keeps a case's front
 * panel the right way up on every side of the block.
 * @date 2026-09-16 */
constexpr float FACE_CORNERS[worldc::FACE_COUNT][4][3] = {
    /* -X */ {{0, 0, 0}, {0, 0, 1}, {0, 1, 1}, {0, 1, 0}},
    /* +X */ {{1, 0, 1}, {1, 0, 0}, {1, 1, 0}, {1, 1, 1}},
    /* -Y */ {{0, 0, 0}, {1, 0, 0}, {1, 0, 1}, {0, 0, 1}},
    /* +Y */ {{0, 1, 1}, {1, 1, 1}, {1, 1, 0}, {0, 1, 0}},
    /* -Z */ {{1, 0, 0}, {0, 0, 0}, {0, 1, 0}, {1, 1, 0}},
    /* +Z */ {{0, 0, 1}, {1, 0, 1}, {1, 1, 1}, {0, 1, 1}},
};

/*! The atlas coordinate of each corner, matching FACE_CORNERS. The v axis runs down the image, the
 * way a decoded PNG is stored, so the top of a face takes v = 0. @date 2026-09-16 */
constexpr float FACE_UV[4][2] = {{0, 1}, {1, 1}, {1, 0}, {0, 0}};

/*! Vertex source for the world pass. GLSL 130, because imgui_helpers.h asks GLFW for a 3.0 context
 * - see gl_util.h. Attribute locations come from glGetAttribLocation for the same reason.
 * @date 2026-09-16 */
inline const char *WORLD_VERT_SRC = R"(#version 130
uniform mat4 u_mvp;
in vec3 a_pos;
in vec2 a_uv;
in float a_shade;
out vec2 v_uv;
out float v_shade;
void main() {
    v_uv = a_uv;
    v_shade = a_shade;
    gl_Position = u_mvp * vec4(a_pos, 1.0);
}
)";

/*! Fragment source for the world pass: the atlas sample, darkened by the baked face brightness.
 * A fully transparent texel is discarded so the selection frame can be a mostly empty tile.
 * @date 2026-09-16 */
inline const char *WORLD_FRAG_SRC = R"(#version 130
uniform sampler2D u_atlas;
in vec2 v_uv;
in float v_shade;
out vec4 o_color;
void main() {
    vec4 t = texture(u_atlas, v_uv);
    if (t.a < 0.02)
        discard;
    o_color = vec4(t.rgb * v_shade, t.a);
}
)";

/*! Everything the 3D view needs, held for the life of the process.
 *
 * A single instance rather than an object Lua creates: there is one window, one GL context and one
 * camera, and handing Lua a renderer to construct would only invite a second one that cannot work.
 * The world, by contrast, is a real object Lua makes and could make several of.
 *
 * @date 2026-09-16 */
struct renderer_t {
    glu::shader_t shader;
    glu::texture_t atlas;
    glu::mesh_t world_mesh;
    glu::mesh_t ground_mesh;
    glu::mesh_t highlight_mesh;
    glu::mesh_t marker_mesh;

    int loc_mvp = -1;
    int loc_atlas = -1;
    int attr_pos = -1;
    int attr_uv = -1;
    int attr_shade = -1;

    /* The atlas is a single row of TILE_PX squares. `tile_count` is how many are in use. */
    int tile_count = 0;
    int atlas_w = 0;
    int tile_ground = 0;
    int tile_highlight = 0;
    int tile_marker = 0;
    int tile_wire[4] = {};   /* one per cell state - the wire's colour when lit */
    /* Indexed [kind][state][role]; only CELL_KIND_CASE is filled today. */
    /*! Indexed [kind][state][role]; the cube kinds fill it, the flat ones do not.
     *
     * KIND_MAX is deliberately well above the kinds that exist. It was exactly the number of kinds
     * once, and adding one more wrote a row past the end of the array and straight over the
     * members below it - which surfaced as `bad allocation` from an unrelated string, a long way
     * from the cause. Every index into this table is bounds-checked against KIND_MAX. */
    int tile_cell[KIND_MAX][4][ROLE_COUNT] = {};
    int tile_keyboard = 0;
    int tile_cable = 0;
    int tile_cable_cap = 0;

    bool mc_loaded = false;
    bool vanilla_loaded = false;
    std::string mc_path;
    std::string vanilla_path;

    /* The world version the mesh was built from; a mismatch is what triggers a rebuild. */
    uint64_t mesh_version = 0;
    const worldc::world_t *mesh_world = nullptr;

    float cam_x = 32.0f, cam_y = 6.0f, cam_z = 40.0f;
    float cam_yaw = 0.0f, cam_pitch = -0.25f;
    float cam_fov = 1.22f;              /* about 70 degrees, Minecraft's default */

    bool have_highlight = false;
    int hl_x = 0, hl_y = 0, hl_z = 0;

    bool have_marker = false;
    float mk_x = 0, mk_y = 0, mk_z = 0;
    float mk_radius = 0.18f;
};

/*! The one renderer. @date 2026-09-16 */
inline renderer_t g_rend;

/* --- the atlas ----------------------------------------------------------------------------- */

/*! Builds the texture atlas from whatever source is available and uploads it.
 *
 * Core: every tile the simulator can draw is collected into one row of 16x16 squares, so the whole
 * world is one draw call against one texture. For each of a cell's four surfaces and each of its
 * four states, the OpenComputers texture is tried first and a hand-drawn stand-in is used when it
 * is missing - per tile, not per atlas, so a mod jar that has moved on and renamed one file still
 * yields a world where everything else is real.
 *
 * How a lit variant is applied is decided by looking at it. OpenComputers ships both kinds: some
 * "On" textures are complete replacements and some are small decals meant to sit on top of the
 * plain face. A variant that is mostly transparent is composited over the base; one that is mostly
 * opaque replaces it. That reads the intent out of the pixels instead of hard-coding which file is
 * which, which would be a guess that quietly rots when the mod updates.
 *
 * @date 2026-09-16 */
inline void build_atlas(renderer_t &r) {
    mca::mc_source_t src;
    r.mc_loaded = src.open(r.mc_path);
    r.vanilla_loaded = src.open_vanilla(r.vanilla_path);

    std::vector<mca::tile_t> tiles;

    auto push = [&](const mca::tile_t &t) {
        tiles.push_back(t);
        return (int)tiles.size() - 1;
    };

    /*! Loads a Minecraft texture by name, or draws the given stand-in when it is not there. */
    auto load_or = [&](const char *mc_name, const mca::tile_t &fallback) {
        mca::tile_t t;
        if (src.block_tile(mc_name, t))
            return t;
        return fallback;
    };

    /*! Loads a vanilla Minecraft texture, or draws the given stand-in when it is not there. */
    auto load_vanilla_or = [&](const char *name, const mca::tile_t &fallback) {
        mca::tile_t t;
        if (src.vanilla_tile(name, t))
            return t;
        return fallback;
    };

    /*! Applies a lit variant to a base face, choosing overlay or replacement by its opacity. */
    auto apply_variant = [&](mca::tile_t base, const char *variant_name) {
        mca::tile_t v;
        if (!src.block_tile(variant_name, v))
            return base;

        int opaque = 0;
        for (int y = 0; y < mca::TILE_PX; y++)
            for (int x = 0; x < mca::TILE_PX; x++)
                if (v.at(x, y)[3] > 128)
                    opaque++;

        if (opaque * 2 >= mca::TILE_PX * mca::TILE_PX)
            return v;
        mca::composite(base, v);
        return base;
    };

    r.tile_ground = push(mca::fallback_ground());

    /* The selection frame: a dark border with a hollow middle, drawn over the targeted cell. It has
    no Minecraft counterpart, so it is always hand-made. */
    {
        mca::tile_t hl;
        for (int y = 0; y < mca::TILE_PX; y++)
            for (int x = 0; x < mca::TILE_PX; x++) {
                bool edge = (x < 1 || y < 1 || x >= mca::TILE_PX - 1 || y >= mca::TILE_PX - 1);
                hl.set(x, y, 20, 20, 24, edge ? 235 : 0);
            }
        r.tile_highlight = push(hl);
    }

    /* The marker sphere's one colour. The whole ball samples the middle of this tile, so only that
    texel is ever read - the rest is filled to the same value so a wrong sample would not be
    invisible. A warm orange, chosen to sit against every other colour in the scene: the blue sky,
    the grey floor and the grey case. */
    {
        mca::tile_t mk;
        mk.fill(255, 150, 40, 255);
        r.tile_marker = push(mk);
    }

    /* The wire, one tile per state. OpenComputers ships no redstone-dust texture - its "Redstone"
    files are the faces of the Redstone I/O block, not a wire - so these are drawn here. Dark and
    dull when off, bright when carrying a signal, which is the whole of what a wire has to say at a
    glance. */
    {
        static const int wire_rgb[4][3] = {
            {112,  22,  22},    /* off */
            {236,  58,  48},    /* on */
            {255, 120,  40},    /* error */
            {200,  92,  40},    /* busy */
        };
        for (int st = 0; st < 4; st++) {
            mca::tile_t w;
            for (int y = 0; y < mca::TILE_PX; y++)
                for (int x = 0; x < mca::TILE_PX; x++) {
                    int n = mca::speckle(x, y, 17 + st) / 2;
                    w.set(x, y, mca::clamp8(wire_rgb[st][0] + n),
                            mca::clamp8(wire_rgb[st][1] + n), mca::clamp8(wire_rgb[st][2] + n));
                }
            r.tile_wire[st] = push(w);
        }
    }

    /* The computer case, four states deep. The plain faces are loaded once and each state layers
    its own variant on top of a copy. */
    mca::tile_t base_front = load_or("CaseFront", mca::fallback_case_front(70, 74, 80));
    mca::tile_t base_back  = load_or("CaseBack",  mca::fallback_panel(112, 114, 118, 21));
    mca::tile_t base_top   = load_or("CaseTop",   mca::fallback_panel(132, 134, 138, 5));
    mca::tile_t base_side  = load_or("CaseSide",  mca::fallback_panel(120, 122, 126, 13));

    struct state_spec_t {
        int state;
        const char *front_variant;      /* nullptr leaves the plain face */
        const char *lit_variant;        /* applied to back and side, nullptr leaves them plain */
        int led_r, led_g, led_b;        /* the hand-drawn stand-in's status light */
    };
    static const state_spec_t specs[] = {
        {worldc::CELL_STATE_OFF,   nullptr,             nullptr,       70,  74,  80},
        {worldc::CELL_STATE_ON,    "CaseFrontOn",       "CaseSideOn",  90, 230, 110},
        {worldc::CELL_STATE_ERROR, "CaseFrontError",    "CaseSideOn", 235,  70,  60},
        {worldc::CELL_STATE_BUSY,  "CaseFrontActivity", "CaseSideOn", 245, 200,  70},
    };

    for (const state_spec_t &sp : specs) {
        mca::tile_t front = base_front;
        mca::tile_t back  = base_back;
        mca::tile_t side  = base_side;

        if (!front.from_mc) {
            /* Nothing real to layer onto - draw the stand-in with this state's light instead. */
            front = mca::fallback_case_front(sp.led_r, sp.led_g, sp.led_b);
        }
        else if (sp.front_variant) {
            front = apply_variant(front, sp.front_variant);
        }

        if (sp.lit_variant && back.from_mc)
            back = apply_variant(back, "CaseBackOn");
        if (sp.lit_variant && side.from_mc)
            side = apply_variant(side, sp.lit_variant);

        r.tile_cell[worldc::CELL_KIND_CASE][sp.state][ROLE_FRONT] = push(front);
        r.tile_cell[worldc::CELL_KIND_CASE][sp.state][ROLE_BACK]  = push(back);
        r.tile_cell[worldc::CELL_KIND_CASE][sp.state][ROLE_TOP]   = push(base_top);
        r.tile_cell[worldc::CELL_KIND_CASE][sp.state][ROLE_SIDE]  = push(side);
    }

    /* The screen. OpenComputers ships no screen texture - the mod draws that face itself - so the
    display is hand-made here and the casing borrows the generic machine sides the real block uses.
    That the front is procedural is convenient rather than a compromise: it is the surface the
    console's text will eventually be rendered into. */
    {
        mca::tile_t scr_side = load_or("GenericSide", mca::fallback_panel(108, 110, 114, 31));
        mca::tile_t scr_top  = load_or("GenericTop",  mca::fallback_panel(124, 126, 130, 37));

        for (int st = 0; st < 4; st++) {
            mca::tile_t face;
            /* A dark glass panel inside the casing's bezel, lit faintly when the screen is on. */
            int glow = (st == worldc::CELL_STATE_OFF) ? 0 : 26;
            for (int y = 0; y < mca::TILE_PX; y++)
                for (int x = 0; x < mca::TILE_PX; x++) {
                    bool bezel = (x < 1 || y < 1 || x >= mca::TILE_PX - 1 || y >= mca::TILE_PX - 1);
                    int n = mca::speckle(x, y, 41) / 2;
                    if (bezel)
                        face.set(x, y, mca::clamp8(96 + n), mca::clamp8(98 + n),
                                mca::clamp8(102 + n));
                    else
                        face.set(x, y, mca::clamp8(12 + glow / 3), mca::clamp8(16 + glow),
                                mca::clamp8(20 + glow / 2));
                }

            r.tile_cell[worldc::CELL_KIND_SCREEN][st][ROLE_FRONT] = push(face);
            r.tile_cell[worldc::CELL_KIND_SCREEN][st][ROLE_BACK]  = push(scr_side);
            r.tile_cell[worldc::CELL_KIND_SCREEN][st][ROLE_TOP]   = push(scr_top);
            r.tile_cell[worldc::CELL_KIND_SCREEN][st][ROLE_SIDE]  = push(scr_side);
        }
    }

    /* The keyboard, which the mod does ship a texture for. It is flat and has one face worth
    looking at, so it takes a single tile rather than a set. */
    r.tile_keyboard = push(load_or("Keyboard", mca::fallback_panel(86, 84, 80, 53)));

    /* The redstone lamp, which is a vanilla block rather than an OpenComputers one, so its art
    comes out of the other jar. Every face is the same, lit or unlit. */
    {
        mca::tile_t off = load_vanilla_or("redstone_lamp_off",
                mca::fallback_panel(92, 58, 34, 61));
        mca::tile_t on  = load_vanilla_or("redstone_lamp_on",
                mca::fallback_panel(228, 176, 96, 67));
        for (int st = 0; st < 4; st++) {
            const mca::tile_t &t = (st == worldc::CELL_STATE_OFF) ? off : on;
            for (int role = 0; role < ROLE_COUNT; role++)
                r.tile_cell[worldc::CELL_KIND_LAMP][st][role] = push(t);
        }
    }

    /* The disk drive. Its front carries the slot and the activity light. */
    {
        mca::tile_t side = load_or("DiskDriveSide", mca::fallback_panel(104, 106, 110, 71));
        mca::tile_t top  = load_or("GenericTop",    mca::fallback_panel(124, 126, 130, 37));
        mca::tile_t base_front = load_or("DiskDriveFront", mca::fallback_panel(96, 98, 102, 73));

        for (int st = 0; st < 4; st++) {
            mca::tile_t front = base_front;
            if (st != worldc::CELL_STATE_OFF && front.from_mc)
                front = apply_variant(front, "DiskDriveFrontActivity");

            r.tile_cell[worldc::CELL_KIND_DRIVE][st][ROLE_FRONT] = push(front);
            r.tile_cell[worldc::CELL_KIND_DRIVE][st][ROLE_BACK]  = push(side);
            r.tile_cell[worldc::CELL_KIND_DRIVE][st][ROLE_TOP]   = push(top);
            r.tile_cell[worldc::CELL_KIND_DRIVE][st][ROLE_SIDE]  = push(side);
        }
    }

    /* The cable, which the mod ships art for: a length and an end cap. */
    r.tile_cable     = push(load_or("CablePart", mca::fallback_panel(118, 118, 122, 83)));
    r.tile_cable_cap = push(load_or("CableCap",  mca::fallback_panel(96, 96, 100, 89)));

    /* The chest. Vanilla draws one as a model with its own texture sheet rather than as six block
    faces, so the planks are borrowed and the front is drawn here - a band and a latch, which is
    what makes a chest recognisable at a glance. */
    {
        mca::tile_t planks = load_vanilla_or("planks_oak", mca::fallback_panel(150, 120, 70, 97));
        mca::tile_t top    = load_vanilla_or("log_oak_top", planks);

        mca::tile_t front = planks;
        for (int y = 6; y <= 9; y++)
            for (int x = 0; x < mca::TILE_PX; x++) {
                int n = mca::speckle(x, y, 101) / 2;
                front.set(x, y, mca::clamp8(74 + n), mca::clamp8(58 + n), mca::clamp8(34 + n));
            }
        for (int y = 6; y <= 10; y++)
            for (int x = 7; x <= 8; x++)
                front.set(x, y, 214, 196, 128);

        for (int st = 0; st < 4; st++) {
            r.tile_cell[worldc::CELL_KIND_CHEST][st][ROLE_FRONT] = push(front);
            r.tile_cell[worldc::CELL_KIND_CHEST][st][ROLE_BACK]  = push(planks);
            r.tile_cell[worldc::CELL_KIND_CHEST][st][ROLE_TOP]   = push(top);
            r.tile_cell[worldc::CELL_KIND_CHEST][st][ROLE_SIDE]  = push(planks);
        }
    }

    /* The transposer, which the mod ships art for, with a lit top while it is working. */
    {
        mca::tile_t side = load_or("TransposerSide", mca::fallback_panel(112, 114, 118, 103));
        mca::tile_t top  = load_or("TransposerTop",  mca::fallback_panel(126, 128, 132, 107));
        for (int st = 0; st < 4; st++) {
            mca::tile_t lit = side;
            if (st != worldc::CELL_STATE_OFF && lit.from_mc)
                lit = apply_variant(lit, "TransposerOn");
            r.tile_cell[worldc::CELL_KIND_TRANSPOSER][st][ROLE_FRONT] = push(lit);
            r.tile_cell[worldc::CELL_KIND_TRANSPOSER][st][ROLE_BACK]  = push(lit);
            r.tile_cell[worldc::CELL_KIND_TRANSPOSER][st][ROLE_TOP]   = push(top);
            r.tile_cell[worldc::CELL_KIND_TRANSPOSER][st][ROLE_SIDE]  = push(lit);
        }
    }

    /* The redstone I/O block. OpenComputers gives it a different face per side; the simulator has
    no notion of which way round it was placed beyond `facing`, so the four it can tell apart are
    used and the rest share. */
    {
        mca::tile_t front = load_or("RedstoneNorth", mca::fallback_panel(132, 70, 60, 109));
        mca::tile_t back  = load_or("RedstoneSouth", front);
        mca::tile_t side  = load_or("RedstoneEast",  front);
        mca::tile_t top   = load_or("RedstoneTop",   mca::fallback_panel(140, 76, 64, 113));
        for (int st = 0; st < 4; st++) {
            r.tile_cell[worldc::CELL_KIND_REDSTONE][st][ROLE_FRONT] = push(front);
            r.tile_cell[worldc::CELL_KIND_REDSTONE][st][ROLE_BACK]  = push(back);
            r.tile_cell[worldc::CELL_KIND_REDSTONE][st][ROLE_TOP]   = push(top);
            r.tile_cell[worldc::CELL_KIND_REDSTONE][st][ROLE_SIDE]  = push(side);
        }
    }

    /* One row, so a tile's atlas coordinate is its index and nothing has to divide. */
    r.tile_count = (int)tiles.size();
    r.atlas_w = r.tile_count * mca::TILE_PX;

    std::vector<uint8_t> pixels((size_t)r.atlas_w * mca::TILE_PX * 4, 0);
    for (int i = 0; i < r.tile_count; i++)
        for (int y = 0; y < mca::TILE_PX; y++)
            for (int x = 0; x < mca::TILE_PX; x++) {
                const uint8_t *s = tiles[i].at(x, y);
                uint8_t *d = &pixels[((size_t)y * r.atlas_w + i * mca::TILE_PX + x) * 4];
                d[0] = s[0]; d[1] = s[1]; d[2] = s[2]; d[3] = s[3];
            }

    r.atlas.upload(r.atlas_w, mca::TILE_PX, pixels.data());
    DBG("render: atlas %dx%d, %d tiles, minecraft textures %s",
            r.atlas_w, mca::TILE_PX, r.tile_count, r.mc_loaded ? "loaded" : "not found");
}

/* --- meshing ------------------------------------------------------------------------------- */

/*! Appends one textured quad of a unit cube at a cell coordinate. @date 2026-09-16 */
inline void emit_face(std::vector<glu::vertex_t> &verts, std::vector<uint32_t> &indices,
        int cx, int cy, int cz, int face, int tile, int tile_count, float shade, float grow)
{
    uint32_t base = (uint32_t)verts.size();
    float u0 = (float)tile / (float)tile_count;
    float du = 1.0f / (float)tile_count;

    for (int i = 0; i < 4; i++) {
        glu::vertex_t v;
        /* `grow` pushes the quad out from the cube's centre, which is how the selection frame is
        kept from fighting the block's own surface for the same depth. */
        v.x = cx + 0.5f + (FACE_CORNERS[face][i][0] - 0.5f) * (1.0f + grow);
        v.y = cy + 0.5f + (FACE_CORNERS[face][i][1] - 0.5f) * (1.0f + grow);
        v.z = cz + 0.5f + (FACE_CORNERS[face][i][2] - 0.5f) * (1.0f + grow);
        v.u = u0 + FACE_UV[i][0] * du;
        v.v = FACE_UV[i][1];
        v.shade = shade;
        verts.push_back(v);
    }

    indices.push_back(base + 0); indices.push_back(base + 1); indices.push_back(base + 2);
    indices.push_back(base + 0); indices.push_back(base + 2); indices.push_back(base + 3);
}

/*! Appends an axis-aligned box, six quads, each shaded by the direction it faces.
 *
 * The wires are built out of these. A box takes one tile rather than the cell tile table, because a
 * wire is the same colour on every side and has no notion of a front.
 * @date 2026-09-16 */
inline void emit_box(std::vector<glu::vertex_t> &verts, std::vector<uint32_t> &indices,
        const float lo[3], const float hi[3], int tile, int tile_count)
{
    float u0 = (float)tile / (float)tile_count;
    float du = 1.0f / (float)tile_count;

    for (int f = 0; f < worldc::FACE_COUNT; f++) {
        uint32_t base = (uint32_t)verts.size();
        for (int i = 0; i < 4; i++) {
            glu::vertex_t v;
            /* FACE_CORNERS gives a corner of the unit cube; the box is that cube stretched into the
            lo-to-hi range, which keeps the winding and the texture orientation of a block face. */
            v.x = lo[0] + FACE_CORNERS[f][i][0] * (hi[0] - lo[0]);
            v.y = lo[1] + FACE_CORNERS[f][i][1] * (hi[1] - lo[1]);
            v.z = lo[2] + FACE_CORNERS[f][i][2] * (hi[2] - lo[2]);
            v.u = u0 + FACE_UV[i][0] * du;
            v.v = FACE_UV[i][1];
            v.shade = FACE_SHADE[f];
            verts.push_back(v);
        }
        indices.push_back(base + 0); indices.push_back(base + 1); indices.push_back(base + 2);
        indices.push_back(base + 0); indices.push_back(base + 2); indices.push_back(base + 3);
    }
}

/*! How far a wire stands off its surface, how thick it is, and how wide its arms are, in cells.
 *
 * A sixteenth for both, which is one Minecraft pixel, and that is what makes a wire read as
 * something laid onto a surface rather than painted on it. The lift keeps the underside out of a
 * depth fight with the face it rests on.
 * @date 2026-09-16 */
constexpr float WIRE_LIFT = 0.004f;
constexpr float WIRE_THICK = 0.0625f;
constexpr float WIRE_HALF_W = 0.0625f;

/*! Appends one wire's geometry onto the face it clings to.
 *
 * Core: a wire is drawn as arms running from the middle of its face out to the edges, one for each
 * direction it connects in. With nothing to connect to it becomes a cross instead - two bars
 * spanning the whole face and meeting in the middle. The author's rule, 2026-09-16: "if not
 * connected on any side a wire across a tile will be made as a + ... else draw rectangular pieces
 * from the center of the face to the bordering region".
 *
 * The face's two in-plane axes are worked out exactly as world_t::face_links does - the two axes
 * that are not the face's own, in that order - so bit n of the link mask and the arm drawn for it
 * always point the same way. That shared rule is the only thing keeping the picture and the
 * connection logic in agreement, and neither derives it from the other.
 *
 * Params: `links` the four-bit mask from world_t::face_links, `tile` the wire colour for its state.
 * @date 2026-09-16 */
inline void emit_wire(std::vector<glu::vertex_t> &verts, std::vector<uint32_t> &indices,
        int cx, int cy, int cz, int face, int links, int tile, int tile_count)
{
    int axis = face / 2;
    const int axes[2] = {(axis + 1) % 3, (axis + 2) % 3};

    /* The plane the wire lies in, and the slab of thickness standing out of it. */
    int cell[3] = {cx, cy, cz};
    bool positive = worldc::FACE_DIR[face][axis] > 0;
    float plane = (float)cell[axis] + (positive ? 1.0f : 0.0f);
    float w_lo = positive ? plane + WIRE_LIFT : plane - (WIRE_LIFT + WIRE_THICK);
    float w_hi = positive ? plane + (WIRE_LIFT + WIRE_THICK) : plane - WIRE_LIFT;

    float centre[3] = {(float)cx + 0.5f, (float)cy + 0.5f, (float)cz + 0.5f};

    /* One arm or bar, given a span on each of the two in-plane axes. */
    auto piece = [&](float a0, float a1, float b0, float b1) {
        float lo[3], hi[3];
        lo[axis] = w_lo;
        hi[axis] = w_hi;
        lo[axes[0]] = centre[axes[0]] + a0;
        hi[axes[0]] = centre[axes[0]] + a1;
        lo[axes[1]] = centre[axes[1]] + b0;
        hi[axes[1]] = centre[axes[1]] + b1;
        emit_box(verts, indices, lo, hi, tile, tile_count);
    };

    if (links == 0) {
        /* Nothing to join: a cross, both bars spanning the whole face. */
        piece(-0.5f, 0.5f, -WIRE_HALF_W, WIRE_HALF_W);
        piece(-WIRE_HALF_W, WIRE_HALF_W, -0.5f, 0.5f);
        return;
    }

    /* A stub in the middle, so two arms meeting at a corner join cleanly and a lone arm still has a
    centre to grow out of. */
    piece(-WIRE_HALF_W, WIRE_HALF_W, -WIRE_HALF_W, WIRE_HALF_W);

    if (links & (1 << 0)) piece(0.0f, 0.5f, -WIRE_HALF_W, WIRE_HALF_W);
    if (links & (1 << 1)) piece(-0.5f, 0.0f, -WIRE_HALF_W, WIRE_HALF_W);
    if (links & (1 << 2)) piece(-WIRE_HALF_W, WIRE_HALF_W, 0.0f, 0.5f);
    if (links & (1 << 3)) piece(-WIRE_HALF_W, WIRE_HALF_W, -0.5f, 0.0f);
}

/*! Appends a keyboard: a flat slab lying on the face it clings to.
 *
 * Thicker and wider than a wire, and inset from the face's edges so the block underneath still
 * shows a rim - which is what makes it read as something bolted on rather than a painted square.
 * @date 2026-09-16 */
inline void emit_keyboard(std::vector<glu::vertex_t> &verts, std::vector<uint32_t> &indices,
        int cx, int cy, int cz, int face, int tile, int tile_count)
{
    const float inset = 0.10f;
    const float thick = 0.055f;

    int axis = face / 2;
    const int axes[2] = {(axis + 1) % 3, (axis + 2) % 3};

    int cell[3] = {cx, cy, cz};
    bool positive = worldc::FACE_DIR[face][axis] > 0;
    float plane = (float)cell[axis] + (positive ? 1.0f : 0.0f);

    float lo[3], hi[3];
    lo[axis] = positive ? plane + WIRE_LIFT : plane - (WIRE_LIFT + thick);
    hi[axis] = positive ? plane + (WIRE_LIFT + thick) : plane - WIRE_LIFT;
    for (int i = 0; i < 2; i++) {
        lo[axes[i]] = (float)cell[axes[i]] + inset;
        hi[axes[i]] = (float)cell[axes[i]] + 1.0f - inset;
    }

    emit_box(verts, indices, lo, hi, tile, tile_count);
}

/*! How thick a cable is, as a fraction of the cell it runs through. @date 2026-09-17 */
constexpr float CABLE_HALF = 0.1875f;

/*! Appends a cable: a core in the middle of its cell, with an arm reaching out to each side that
 * joins onto something.
 *
 * Core: the shape IS the wiring. An arm is drawn only where the network actually continues, so a
 * cable that looks joined is joined, and a run that stops short looks like it stops short. A cable
 * with nothing around it is just its core - a stub, which is exactly what it is.
 *
 * Params: `links` the six bit mask from world_t::cable_links.
 * @date 2026-09-17 */
inline void emit_cable(std::vector<glu::vertex_t> &verts, std::vector<uint32_t> &indices,
        int cx, int cy, int cz, int links, int tile, int cap_tile, int tile_count)
{
    const float lo = 0.5f - CABLE_HALF;
    const float hi = 0.5f + CABLE_HALF;

    float base[3] = {(float)cx, (float)cy, (float)cz};

    /* The core, always. */
    {
        float a[3] = {base[0] + lo, base[1] + lo, base[2] + lo};
        float b[3] = {base[0] + hi, base[1] + hi, base[2] + hi};
        emit_box(verts, indices, a, b, links == 0 ? cap_tile : tile, tile_count);
    }

    for (int f = 0; f < worldc::FACE_COUNT; f++) {
        if (!(links & (1 << f)))
            continue;

        int axis = f / 2;
        bool positive = worldc::FACE_DIR[f][axis] > 0;

        float a[3], b[3];
        for (int i = 0; i < 3; i++) {
            a[i] = base[i] + lo;
            b[i] = base[i] + hi;
        }
        /* The arm runs from the core out to the cell boundary on its own axis. */
        if (positive) {
            a[axis] = base[axis] + hi;
            b[axis] = base[axis] + 1.0f;
        }
        else {
            a[axis] = base[axis];
            b[axis] = base[axis] + lo;
        }
        emit_box(verts, indices, a, b, tile, tile_count);
    }
}

/*! Which of a cell's four surfaces a given face shows.
 *
 * The cell's `facing` names the face its front is on; the face opposite that one is its back, top
 * and bottom share the top texture - OpenComputers ships no separate bottom - and the two remaining
 * sides get the side texture.
 * @date 2026-09-16 */
inline int face_role(int facing, int face) {
    if (face == facing)
        return ROLE_FRONT;
    if (face == (facing ^ 1))
        return ROLE_BACK;
    if (face == worldc::FACE_YPOS || face == worldc::FACE_YNEG)
        return ROLE_TOP;
    return ROLE_SIDE;
}

/*! Rebuilds the mesh of every placed cell, emitting only the faces that something can see.
 *
 * A face is emitted when the neighbour in that direction is empty, which for a lone block means all
 * six and for a wall means only its outside. The bottom face of a cell resting on the floor is the
 * one exception: it is dropped because it is coplanar with the ground quad underneath and the two
 * would otherwise fight over the same depth.
 * @date 2026-09-16 */
inline void rebuild_world_mesh(renderer_t &r, const worldc::world_t &w) {
    std::vector<glu::vertex_t> verts;
    std::vector<uint32_t> indices;

    for (const worldc::cell_p &c : w.cells) {
        if (!c)
            continue;

        int kind = c->kind;
        int state = c->state;
        if (kind < 0 || kind >= KIND_MAX) kind = worldc::CELL_KIND_CASE;
        if (state < 0 || state > 3) state = worldc::CELL_STATE_OFF;

        /* A cable is not a cube: its shape follows what it joins onto, so it is built whole and
        the per-face walk below is skipped entirely. */
        if (kind == worldc::CELL_KIND_CABLE) {
            emit_cable(verts, indices, c->x, c->y, c->z,
                    w.cable_links(c->x, c->y, c->z), r.tile_cable, r.tile_cable_cap, r.tile_count);
            continue;
        }

        for (int f = 0; f < worldc::FACE_COUNT; f++) {
            int nx = c->x + worldc::FACE_DIR[f][0];
            int ny = c->y + worldc::FACE_DIR[f][1];
            int nz = c->z + worldc::FACE_DIR[f][2];

            /* A face is only hidden by something that genuinely fills the cell beyond it. A
            cable is a thin run through the middle of its own cell, so the face it shares with a
            block is still mostly open air - skipping it punched a hole through whatever the cable
            was plugged into. */
            worldc::cell_p neighbour = w.get(nx, ny, nz);
            if (neighbour && worldc::kind_is_full_cube(neighbour->kind))
                continue;
            if (f == worldc::FACE_YNEG && c->y == 0)
                continue;

            int tile = r.tile_cell[kind][state][face_role(c->facing, f)];
            emit_face(verts, indices, c->x, c->y, c->z, f, tile, r.tile_count, FACE_SHADE[f], 0.0f);
        }
    }

    /* The wires, which live on faces rather than in slots and so are walked separately. Their
    shape depends on what they connect to, which is why the link mask is asked for here and not
    stored on the wire: a wire's picture changes when its NEIGHBOUR changes, and a field would have
    to be invalidated across the whole neighbourhood on every edit. */
    for (const auto &kv : w.faces) {
        const worldc::cell_p &wire = kv.second;
        if (!wire)
            continue;

        int state = wire->state;
        if (state < 0 || state > 3)
            state = worldc::CELL_STATE_OFF;

        auto [wx, wy, wz, wface] = w.face_unkey((double)kv.first);
        if (wire->kind == worldc::CELL_KIND_KEYBOARD)
            emit_keyboard(verts, indices, wx, wy, wz, wface, r.tile_keyboard, r.tile_count);
        else
            emit_wire(verts, indices, wx, wy, wz, wface,
                    w.face_links(wx, wy, wz, wface), r.tile_wire[state], r.tile_count);
    }

    r.world_mesh.upload(verts, indices);
    r.mesh_version = w.version;
    r.mesh_world = &w;
}

/*! Builds the floor: one upward quad per column of the map, at y = 0.
 *
 * Built once and kept, because it never changes - it is the reference surface the world is laid out
 * on, not part of the world. Sixty-four by sixty-four quads is small enough that drawing the whole
 * thing costs less than any scheme for drawing part of it.
 * @date 2026-09-16 */
inline void build_ground_mesh(renderer_t &r) {
    std::vector<glu::vertex_t> verts;
    std::vector<uint32_t> indices;

    for (int z = 0; z < worldc::WORLD_Z; z++)
        for (int x = 0; x < worldc::WORLD_X; x++)
            emit_face(verts, indices, x, -1, z, worldc::FACE_YPOS, r.tile_ground, r.tile_count,
                    FACE_SHADE[worldc::FACE_YPOS], 0.0f);

    r.ground_mesh.upload(verts, indices);
}

/*! Builds the marker sphere: a unit-radius ball centred on the origin, built once.
 *
 * Core: it is built at the origin and moved into place by a model matrix at draw time, rather than
 * being rebuilt wherever it needs to go. The marker follows the crosshair, so it moves every frame
 * the view moves - re-meshing and re-uploading a few hundred vertices that often would be work done
 * for nothing when a matrix multiply says the same thing.
 *
 * A latitude and longitude sphere, which is the simplest kind to write and has the pole pinching an
 * icosphere avoids. At this size - a ball a fifth of a block across - the pinch is a few pixels and
 * nobody will see it.
 *
 * Every vertex samples the middle of the marker tile, so the ball is one flat colour and the shape
 * reads entirely from the shading, which is taken from how far up each vertex's normal points. On a
 * sphere the position is the normal, which is what makes that a single line here.
 * @date 2026-09-16 */
inline void build_marker_mesh(renderer_t &r) {
    const int rings = 12;       /* bands from pole to pole */
    const int segments = 18;    /* divisions around the equator */
    const float pi = 3.14159265358979f;

    std::vector<glu::vertex_t> verts;
    std::vector<uint32_t> indices;

    float u_mid = ((float)r.tile_marker + 0.5f) / (float)r.tile_count;

    for (int ring = 0; ring <= rings; ring++) {
        float phi = pi * (float)ring / (float)rings;          /* 0 at the top pole */
        float y = std::cos(phi);
        float ring_r = std::sin(phi);

        for (int seg = 0; seg <= segments; seg++) {
            float theta = 2.0f * pi * (float)seg / (float)segments;

            glu::vertex_t v;
            v.x = ring_r * std::cos(theta);
            v.y = y;
            v.z = ring_r * std::sin(theta);
            v.u = u_mid;
            v.v = 0.5f;
            /* Lit from above: the top of the ball is full brightness, the underside about half. */
            v.shade = 0.55f + 0.45f * (v.y * 0.5f + 0.5f);
            verts.push_back(v);
        }
    }

    const int stride = segments + 1;
    for (int ring = 0; ring < rings; ring++)
        for (int seg = 0; seg < segments; seg++) {
            uint32_t a = (uint32_t)(ring * stride + seg);
            uint32_t b = (uint32_t)(a + stride);

            indices.push_back(a);     indices.push_back(b);     indices.push_back(a + 1);
            indices.push_back(a + 1); indices.push_back(b);     indices.push_back(b + 1);
        }

    r.marker_mesh.upload(verts, indices);
}

/*! Rebuilds the six-quad frame drawn around whichever cell the crosshair is on.
 * @date 2026-09-16 */
inline void rebuild_highlight_mesh(renderer_t &r) {
    std::vector<glu::vertex_t> verts;
    std::vector<uint32_t> indices;

    if (r.have_highlight)
        for (int f = 0; f < worldc::FACE_COUNT; f++)
            emit_face(verts, indices, r.hl_x, r.hl_y, r.hl_z, f, r.tile_highlight, r.tile_count,
                    1.0f, 0.02f);

    r.highlight_mesh.upload(verts, indices);
}

/* --- the Lua boundary ---------------------------------------------------------------------- */

/*! Compiles the shader, builds the atlas and the floor. Must run after imgui_init(), because every
 * GL entry point it touches is loaded by ImGui's backend - see gl_util.h.
 *
 * Params: `mc_path` the Minecraft instance directory from Lua's settings file; an empty string is
 * the ordinary "not configured" case and leaves every tile hand-drawn.
 * Returns true when the OpenComputers jar was found and read.
 * @date 2026-09-16 */
inline bool render_init(const char *mc_path, const char *vanilla_path) {
    renderer_t &r = renderc::g_rend;
    r.mc_path = mc_path ? mc_path : "";
    r.vanilla_path = vanilla_path ? vanilla_path : "";

    if (!r.shader.compile(WORLD_VERT_SRC, WORLD_FRAG_SRC)) {
        DBG("render_init: the world shader would not build");
        return false;
    }
    r.loc_mvp    = r.shader.uniform("u_mvp");
    r.loc_atlas  = r.shader.uniform("u_atlas");
    r.attr_pos   = r.shader.attribute("a_pos");
    r.attr_uv    = r.shader.attribute("a_uv");
    r.attr_shade = r.shader.attribute("a_shade");

    renderc::build_atlas(r);
    renderc::build_ground_mesh(r);
    renderc::build_marker_mesh(r);
    return r.mc_loaded;
}

/*! Points the asset loader at a different Minecraft instance and rebuilds every tile.
 *
 * The world mesh is invalidated rather than rebuilt here: tile indices do not move, but the pixels
 * behind them do, and forcing the rebuild keeps one path responsible for meshing.
 * Returns true when the new path yielded a jar.
 * @date 2026-09-16 */
inline bool render_set_mc_path(const char *mc_path, const char *vanilla_path) {
    renderer_t &r = renderc::g_rend;
    r.mc_path = mc_path ? mc_path : "";
    r.vanilla_path = vanilla_path ? vanilla_path : "";
    renderc::build_atlas(r);
    renderc::build_ground_mesh(r);
    renderc::build_marker_mesh(r);
    r.mesh_version = 0;
    renderc::rebuild_highlight_mesh(r);
    return r.mc_loaded;
}

/*! The atlas texture, as the plain integer ImGui uses for a texture id.
 *
 * Handed to Lua so the interface can draw the real block faces in two dimensions - the selector at
 * the bottom of the screen builds little angled cubes out of ImGui image quads. ImTextureID is a
 * 64-bit integer and the OpenGL backend stores the GL texture name straight in it, so nothing has
 * to be converted on the way across.
 *
 * This is the one place the 3D layer's texture escapes into the 2D one, and it escapes read-only:
 * Lua gets a number it can hand back to an ImGui draw call and nothing else.
 * @date 2026-09-16 */
inline double render_atlas_id() {
    return (double)renderc::g_rend.atlas.tex;
}

/*! Where a cell's face sits in the atlas, as `{u0, v0, u1, v1}`.
 *
 * Lua needs this to texture the little models in the selector, and it must not compute the
 * coordinates itself: which tile a kind, state and face resolve to is exactly the decision this
 * file exists to own. A kind with no tiles - a wire, a keyboard - answers its flat texture instead,
 * so a caller can ask about anything placeable and get something to draw.
 * @date 2026-09-16 */
inline std::tuple<double, double, double, double> render_tile_uv(int kind, int state, int role) {
    const renderer_t &r = renderc::g_rend;
    if (r.tile_count <= 0)
        return {0.0, 0.0, 1.0, 1.0};

    if (state < 0 || state > 3)
        state = 0;
    if (role < 0 || role >= ROLE_COUNT)
        role = ROLE_SIDE;

    int tile;
    if (kind == worldc::CELL_KIND_WIRE)
        tile = r.tile_wire[state];
    else if (kind == worldc::CELL_KIND_KEYBOARD)
        tile = r.tile_keyboard;
    else if (kind >= 0 && kind < KIND_MAX)
        tile = r.tile_cell[kind][state][role];
    else
        tile = r.tile_ground;

    double du = 1.0 / (double)r.tile_count;
    double u0 = (double)tile * du;
    /* A sliver is trimmed off each edge. The selector draws these magnified and skewed, and ImGui
    samples them with bilinear filtering rather than the nearest sampling the world uses, so a
    coordinate exactly on the boundary bleeds in the neighbouring tile's first column. */
    double bleed = du * 0.02;
    return {u0 + bleed, 0.02, u0 + du - bleed, 0.98};
}

/*! Were the real OpenComputers textures found, or is the view hand-drawn? @date 2026-09-16 */
inline bool render_mc_ok() { return renderc::g_rend.mc_loaded; }

/*! Which jar the textures came from, or an empty string when none did. @date 2026-09-16 */
inline std::string render_mc_source() {
    return renderc::g_rend.mc_loaded ? renderc::g_rend.mc_path : std::string();
}

/*! Moves the camera. Angles are radians: `yaw` turns about the vertical axis and is zero when
 * looking along -Z, `pitch` tilts up positive and is clamped just short of straight up or down, so
 * the view matrix never loses its roll reference. @date 2026-09-16 */
inline void cam_set(double x, double y, double z, double yaw, double pitch) {
    renderer_t &r = renderc::g_rend;
    r.cam_x = (float)x; r.cam_y = (float)y; r.cam_z = (float)z;
    r.cam_yaw = (float)yaw;

    const float limit = 1.5533f;        /* 89 degrees */
    r.cam_pitch = (float)pitch;
    if (r.cam_pitch >  limit) r.cam_pitch =  limit;
    if (r.cam_pitch < -limit) r.cam_pitch = -limit;
}

/*! Where the camera is and where it looks, as a five element table. @date 2026-09-16 */
inline std::tuple<double, double, double, double, double> cam_get() {
    const renderer_t &r = renderc::g_rend;
    return {r.cam_x, r.cam_y, r.cam_z, r.cam_yaw, r.cam_pitch};
}

/*! The unit vector the camera looks along. The single definition of the yaw and pitch convention -
 * Lua walks along this and casts its ray along it, and the view matrix is built from it.
 * @date 2026-09-16 */
inline std::tuple<double, double, double> cam_forward() {
    const renderer_t &r = renderc::g_rend;
    float cp = std::cos(r.cam_pitch);
    return {-std::sin(r.cam_yaw) * cp, std::sin(r.cam_pitch), -std::cos(r.cam_yaw) * cp};
}

/*! The unit vector to the camera's right, level with the horizon so that strafing does not drift up
 * or down when the view is tilted. @date 2026-09-16 */
inline std::tuple<double, double, double> cam_right() {
    const renderer_t &r = renderc::g_rend;
    return {std::cos(r.cam_yaw), 0.0, -std::sin(r.cam_yaw)};
}

/*! Sets the field of view, in degrees. @date 2026-09-16 */
inline void cam_set_fov(double degrees) {
    if (degrees < 20) degrees = 20;
    if (degrees > 140) degrees = 140;
    renderc::g_rend.cam_fov = (float)(degrees * 3.14159265358979 / 180.0);
}

/*! Frames the cell the crosshair is on. Passing a coordinate outside the map clears the frame,
 * which is what a ray that hit nothing should do. @date 2026-09-16 */
inline void render_highlight(int x, int y, int z) {
    renderer_t &r = renderc::g_rend;
    bool want = worldc::world_t::in_bounds(x, y, z);

    if (want == r.have_highlight && x == r.hl_x && y == r.hl_y && z == r.hl_z)
        return;

    r.have_highlight = want;
    r.hl_x = x; r.hl_y = y; r.hl_z = z;
    renderc::rebuild_highlight_mesh(r);
}

/*! Clears the selection frame. @date 2026-09-16 */
inline void render_highlight_off() {
    renderer_t &r = renderc::g_rend;
    if (!r.have_highlight)
        return;
    r.have_highlight = false;
    renderc::rebuild_highlight_mesh(r);
}

/*! Puts the marker sphere at a point in world units, with a radius in the same units.
 *
 * Core: this is the "where would it go" indicator. Lua places it at the centre of the cell a click
 * would fill, so the ball sits in the empty space the new block would occupy rather than on the
 * surface the ray struck - which is the question a person actually has while aiming.
 *
 * Only the position is kept; the sphere itself was built once at unit size and is moved into place
 * by a matrix when it is drawn.
 * @date 2026-09-16 */
inline void render_marker(double x, double y, double z, double radius) {
    renderer_t &r = renderc::g_rend;
    r.have_marker = true;
    r.mk_x = (float)x;
    r.mk_y = (float)y;
    r.mk_z = (float)z;
    r.mk_radius = radius > 0 ? (float)radius : 0.18f;
}

/*! Hides the marker sphere - what a ray that met nothing should leave behind. @date 2026-09-16 */
inline void render_marker_off() {
    renderc::g_rend.have_marker = false;
}

/*! Draws the floor, the world and the selection frame into the current framebuffer.
 *
 * Called from Lua once per frame, before ImGui's own draw data goes out - main.cpp clears the
 * buffers first and renders ImGui after, so the 2D interface lands on top of the 3D view.
 *
 * The mesh is rebuilt here when the world's version has moved since the last build, or when a
 * different world arrived. That check is the whole reason cell_t's setters bump the version: a Lua
 * script writing `cell.state = 1` gets a redrawn block on the next frame without telling anyone.
 *
 * Params: `w` the world to draw, `width` and `height` the framebuffer size in pixels.
 * @date 2026-09-16 */
inline void render_world(vc::ref_t<worldc::world_t> w, int width, int height) {
    renderer_t &r = renderc::g_rend;
    if (!w || !r.shader.prog || width <= 0 || height <= 0)
        return;

    if (r.mesh_world != w.get() || r.mesh_version != w->version)
        renderc::rebuild_world_mesh(r, *w);

    float eye[3] = {r.cam_x, r.cam_y, r.cam_z};
    auto [fx, fy, fz] = renderc::cam_forward();
    float fwd[3] = {(float)fx, (float)fy, (float)fz};
    float up[3] = {0, 1, 0};

    glu::mat4_t proj = glu::mat4_t::perspective(r.cam_fov, (float)width / (float)height,
            0.05f, 512.0f);
    glu::mat4_t view = glu::mat4_t::look_dir(eye, fwd, up);
    glu::mat4_t mvp = glu::mat4_t::mul(proj, view);

    glEnable(GL_DEPTH_TEST);
    glEnable(GL_BLEND);
    /* glBlendFunc is not among the entry points ImGui's loader carries; the separate form is, and
    asks for the same thing. */
    glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_ONE, GL_ONE_MINUS_SRC_ALPHA);

    r.shader.use();
    glUniformMatrix4fv(r.loc_mvp, 1, GL_FALSE, mvp.m);
    r.atlas.bind(0);
    if (r.loc_atlas >= 0)
        glUniform1i(r.loc_atlas, 0);

    r.ground_mesh.draw(r.attr_pos, r.attr_uv, r.attr_shade);
    r.world_mesh.draw(r.attr_pos, r.attr_uv, r.attr_shade);
    r.highlight_mesh.draw(r.attr_pos, r.attr_uv, r.attr_shade);

    /* The marker goes last and with its own matrix: the sphere is a unit ball at the origin, so the
    model transform is what puts it where the crosshair is pointing. Still depth tested, so a ball
    behind a block is hidden by it - which is correct, since a block cannot be placed there either
    without the ray having stopped short of it. */
    if (r.have_marker) {
        glu::mat4_t model = glu::mat4_t::translate_scale(r.mk_x, r.mk_y, r.mk_z, r.mk_radius);
        glu::mat4_t marker_mvp = glu::mat4_t::mul(mvp, model);
        glUniformMatrix4fv(r.loc_mvp, 1, GL_FALSE, marker_mvp.m);
        r.marker_mesh.draw(r.attr_pos, r.attr_uv, r.attr_shade);
    }

    /* ImGui draws next and assumes the depth test is off, the way its backend left it. */
    glDisable(GL_DEPTH_TEST);
    glUseProgram(0);
}

/*! Puts the camera and the 3D pass on the vc table. @date 2026-09-16 */
inline int register_meta(vc::virt_state_t *vs) {
    DBG_SCOPE();

    std::vector<luaL_Reg> render_tab_funcs = {
        {"render_init", vc::luaw_function_wrapper<
               /* FN:    */ renderc::render_init,
               /* PARAMS:*/ const char *, const char *
        >},
        {"render_atlas_id", vc::luaw_function_wrapper<
               /* FN:    */ renderc::render_atlas_id
        >},
        {"render_tile_uv", vc::luaw_function_wrapper<
               /* FN:    */ renderc::render_tile_uv,
               /* PARAMS:*/ int, int, int
        >},
        {"render_set_mc_path", vc::luaw_function_wrapper<
               /* FN:    */ renderc::render_set_mc_path,
               /* PARAMS:*/ const char *, const char *
        >},
        {"render_mc_ok", vc::luaw_function_wrapper<
               /* FN:    */ renderc::render_mc_ok
        >},
        {"render_mc_source", vc::luaw_function_wrapper<
               /* FN:    */ renderc::render_mc_source
        >},
        {"render_world", vc::luaw_function_wrapper<
               /* FN:    */ renderc::render_world,
               /* PARAMS:*/ vc::ref_t<worldc::world_t>, int, int
        >},
        {"render_highlight", vc::luaw_function_wrapper<
               /* FN:    */ renderc::render_highlight,
               /* PARAMS:*/ int, int, int
        >},
        {"render_highlight_off", vc::luaw_function_wrapper<
               /* FN:    */ renderc::render_highlight_off
        >},
        {"render_marker", vc::luaw_function_wrapper<
               /* FN:    */ renderc::render_marker,
               /* PARAMS:*/ double, double, double, double
        >},
        {"render_marker_off", vc::luaw_function_wrapper<
               /* FN:    */ renderc::render_marker_off
        >},
        {"cam_set", vc::luaw_function_wrapper<
               /* FN:    */ renderc::cam_set,
               /* PARAMS:*/ double, double, double, double, double
        >},
        {"cam_get", vc::luaw_function_wrapper<
               /* FN:    */ renderc::cam_get
        >},
        {"cam_forward", vc::luaw_function_wrapper<
               /* FN:    */ renderc::cam_forward
        >},
        {"cam_right", vc::luaw_function_wrapper<
               /* FN:    */ renderc::cam_right
        >},
        {"cam_set_fov", vc::luaw_function_wrapper<
               /* FN:    */ renderc::cam_set_fov,
               /* PARAMS:*/ double
        >},
    };

    ASSERT_FN(add_lua_tab_funcs(vs, render_tab_funcs));

    return vc::VC_ERROR_OK;
}

} /* namespace render_composer */

#endif /* RENDER_COMPOSER_H */
