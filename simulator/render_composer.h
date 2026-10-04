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
#include <map>
#include <string>
#include <tuple>
#include <unordered_set>
#include <array>
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
in vec3 a_tint;
out vec2 v_uv;
out vec3 v_tint;
void main() {
    v_uv = a_uv;
    v_tint = a_tint;
    gl_Position = u_mvp * vec4(a_pos, 1.0);
}
)";

/*! Fragment source for the world pass: the atlas sample, darkened by the baked face brightness, at
 * u_alpha_pct of its opacity (100 but in the see-through pass, 2026-10-05: an int, since the
 * stripped loader carries glUniform1i and not glUniform1f).
 * A fully transparent texel is discarded so the selection frame can be a mostly empty tile.
 * @date 2026-09-16 */
inline const char *WORLD_FRAG_SRC = R"(#version 130
uniform sampler2D u_atlas;
uniform int u_alpha_pct;
in vec2 v_uv;
in vec3 v_tint;
out vec4 o_color;
void main() {
    vec4 t = texture(u_atlas, v_uv);
    if (t.a < 0.02)
        discard;
    o_color = vec4(t.rgb * v_tint, t.a * float(u_alpha_pct) / 100.0);
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
    /* One mesh per 16-cube section of the map (world_t::dirty_sections), rebuilt only where the
    world says something changed. @date 2026-10-05 */
    std::array<glu::mesh_t, 64> world_meshes;
    /* The see-through blocks of each section (a Minecraft block with ghost 2), drawn after the
    rest at ghost_alpha. @date 2026-10-05 */
    std::array<glu::mesh_t, 64> ghost_meshes;
    glu::mesh_t ground_mesh;
    glu::mesh_t highlight_mesh;
    glu::mesh_t marker_mesh;

    int loc_mvp = -1;
    int loc_atlas = -1;
    int loc_alpha = -1;
    /* How opaque the see-through blocks are, in percent (render_ghost_alpha). @date 2026-10-05 */
    int ghost_alpha = 30;
    int attr_pos = -1;
    int attr_uv = -1;
    int attr_tint = -1;

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

    /*! The three ME carriers, each with its own art so they are never mistaken for one another.
     *
     * The author, 2026-09-18: "be sure to not confuse the glass cable with the Dense ME Conduit
     * from Ender IO". They carry the same network and are different objects with different
     * capacities, and the picture has to say which is which. @date 2026-09-18 */
    int tile_ae_cable = 0;
    int tile_ae_dense = 0;
    int tile_eio_me = 0, tile_eio_me_core = 0;
    int tile_eio_dense = 0, tile_eio_dense_core = 0;

    /*! A flat white square, which exists only to be tinted. Everything else in the atlas is a
     * picture; this is the one tile whose whole purpose is to carry a colour. @date 2026-09-18 */
    int tile_solid = 0;

    /*! Every tile in the atlas, kept after the upload so a scene can add more later without
     * opening the jars for the whole atlas again (render_block_tiles). @date 2026-10-04 */
    std::vector<mca::tile_t> tiles;

    /*! The block textures render_block_tiles has looked for, by key, and the tile each one got:
     * -1 for one that was looked for and not found, so it is not looked for again. @date 2026-10-04
     */
    std::map<std::string, int> block_tiles;

    /*! The fluids GregTech ships, in the order they are offered, and where each one's picture
     * landed in the atlas.
     *
     * A CATALOGUE READ OUT OF THE GAME, not a list written here: build_atlas asks the archive which
     * fluids it has textures for, so the simulator offers whatever the installed GregTech actually
     * contains. The labels come from GregTech's own generated lang file, so a tank says "Sulfuric
     * Acid" rather than "sulfuricacid".
     * @date 2026-09-17 */
    std::vector<std::string> fluid_names;
    std::vector<std::string> fluid_labels;
    std::map<std::string, int> fluid_tile;

    /*! The three greyscale pictures GregTech draws a fluid with when it has no picture of its own,
     * and the colour each material tints them by.
     *
     * Core: MOST FLUIDS HAVE NO TEXTURE. GregTech ships `fluid.autogenerated`,
     * `fluid.plasma.autogenerated` and `fluid.molten.autogenerated` and colours them per material
     * at draw time - the same trick it uses for items. Twenty-nine of the thirty-nine fluids the
     * fusion scenario moves are drawn this way, so without it a row of bank tanks looks empty.
     * @date 2026-09-17 */
    int tile_fluid_plain = -1;
    int tile_fluid_plasma = -1;
    int tile_fluid_molten = -1;
    std::map<std::string, uint32_t> material_colour;    /*!< lower-case name -> 0x00RRGGBB */

    /*! The items a chest can be stocked with, and a texture of their own to draw them from.
     *
     * A SECOND ATLAS, and a grid rather than a row. The world atlas is one tile tall so that a
     * tile's index is its u coordinate and nothing has to divide; five hundred odd items would
     * make it nine thousand pixels wide, which is past what a GL 3.0 implementation is obliged to
     * accept. This one is only ever sampled by the interface, so it can be shaped for size.
     * @date 2026-09-17 */
    glu::texture_t item_atlas;
    int item_cols = 0;
    int item_rows = 0;
    std::vector<std::string> item_ids;
    std::vector<std::string> item_labels;
    /*! The variant of each id, which for a mod packing thousands of items behind one registry name
     * is the only thing telling them apart. Zero for an item that has no variants.
     * @date 2026-09-17 */
    std::vector<int> item_damage;
    std::map<std::string, int> item_index;
    /*! Whether the names above are the modpack's real registry names, or the texture names the
     * catalogue falls back to when there is no save to read a registry out of. The panel says
     * which, because the two are not the same kind of thing. @date 2026-09-17 */
    bool items_from_registry = false;

    bool mc_loaded = false;
    bool vanilla_loaded = false;
    bool irontank_loaded = false;
    bool gregtech_loaded = false;
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
/*! Builds the list of items a chest can be stocked with, and the pictures for the ones that have
 * one.
 *
 * Core: THE NAMES COME FROM THE MODPACK'S OWN REGISTRY, read out of a save's level.dat - the same
 * list NEI shows, ten thousand items and three thousand blocks on the author's install. That is
 * the only place on disk the real registry names live; a texture is called `apple_golden.png`
 * while the item is `minecraft:golden_apple`, and a lang key is neither.
 *
 * THE PICTURES COME FROM EVERY JAR, not just vanilla's. A mod's art lives at
 * `assets/<namespace>/textures/items/<name>.png` and its items register as `<namespace>:<name>`,
 * so the two are joined on exactly that pair. Vanilla is looked up by bare file name as well,
 * since its jar is not under mods/ and its registry names mostly match its texture names.
 *
 * GregTech's own generated items are the exception, and they are drawn the way GregTech draws
 * them: it has no picture on disk for a naquadah dust, only a greyscale shape and a material
 * colour, so mc_assets.h reads its material list out of the compiled code and tints the shape.
 * What still has no picture lists with an empty square, because its NAME is what a program
 * compares and is worth offering either way.
 *
 * When there is no save to read, the list falls back to the textures themselves, named the way
 * they used to be. It is worse - those are texture names, not registry names - but it is better
 * than an empty picker on a machine that has the jars and no world.
 *
 * @date 2026-09-17 */
inline void build_item_atlas(renderer_t &r, const mca::mc_source_t &src) {
    r.item_ids.clear();
    r.item_labels.clear();
    r.item_damage.clear();
    r.item_index.clear();

    /* What the registry says exists. That is the list; the pictures come after. */
    std::vector<std::string> ids = src.registry_names(r.mc_path);
    bool from_registry = !ids.empty();
    r.items_from_registry = from_registry;

    /* Vanilla's own pictures, which are the fallback catalogue when there is no save to read and
    also the art for `minecraft:` ids, whose jar is not under mods/. */
    std::map<std::string, mca::tile_t> vanilla_pics;
    for (const std::string &rel : src.vanilla_texture_names()) {
        mca::tile_t t;
        if (src.vanilla_texture_tile(rel, t))
            vanilla_pics.emplace(rel.substr(rel.find('/') + 1), t);
    }

    if (!from_registry) {
        for (const auto &kv : vanilla_pics)
            ids.push_back("minecraft:" + kv.first);
        std::sort(ids.begin(), ids.end());
    }

    /* Ask the mods for a picture for every id at once. Keys are lower cased because a registry
    spells a namespace `Botania` while the asset folder spells it `botania`. */
    std::unordered_set<std::string> wanted;
    for (const std::string &id : ids) {
        std::string key = id;
        for (char &ch : key)
            ch = (char)tolower((unsigned char)ch);
        wanted.insert(key);
    }
    std::map<std::string, mca::tile_t> mod_pics = src.mod_textures(r.mc_path, wanted);

    std::vector<mca::tile_t> tiles;
    for (const std::string &id : ids) {
        if (r.item_index.count(id + "#0"))
            continue;

        size_t colon = id.find(':');
        std::string bare = id.substr(colon + 1);
        std::string label = bare;
        for (char &ch : label)
            if (ch == '_')
                ch = ' ';

        std::string key = id;
        for (char &ch : key)
            ch = (char)tolower((unsigned char)ch);

        const mca::tile_t *pic = nullptr;
        auto m = mod_pics.find(key);
        if (m != mod_pics.end()) {
            pic = &m->second;
        }
        else {
            auto v = vanilla_pics.find(bare);
            if (v != vanilla_pics.end())
                pic = &v->second;
        }

        /* NOTHING WITHOUT A PICTURE IS OFFERED. The author, 2026-09-17: "filter out the
        non-items, I don't think you render them correctly anyway" - and that was right, a listing
        of seven thousand blank squares is a listing of nothing. What has no picture here is
        mostly what cannot have one: GregTech and its kin draw thousands of items off a single
        sheet indexed by damage value, which a registry name cannot index into.

        The names are not lost - the panel's text box takes any id typed into it, so an item with
        no picture can still be put in a chest by name. */
        if (!pic)
            continue;

        r.item_index[id + "#0"] = (int)tiles.size();
        tiles.push_back(*pic);

        r.item_ids.push_back(id);
        r.item_labels.push_back(label);
        r.item_damage.push_back(0);
    }

    /* And the items a mod packs behind one registry name, which the registry cannot list: every
    GregTech dust, cell and pipe is one of three names with a damage value after it. These have no
    picture - GregTech builds theirs at runtime by tinting a greyscale texture set with the
    material's colour, which no file holds - so they list with a blank square and their real name.
    Leaving them out is what made searching for a naquadah dust find nothing. */
    for (const auto &mi : src.gt_meta_items()) {
        std::string key = mi.id + "#" + std::to_string(mi.damage);
        if (r.item_index.count(key))
            continue;

        if (mi.has_tile) {
            r.item_index[key] = (int)tiles.size();
            tiles.push_back(mi.tile);
        }
        r.item_ids.push_back(mi.id);
        r.item_labels.push_back(mi.label);
        r.item_damage.push_back(mi.damage);
    }

    if (tiles.empty()) {
        r.item_cols = r.item_rows = 0;
        DBG("render: %zu items, no pictures - is the vanilla jar set?", r.item_ids.size());
        return;
    }

    r.item_cols = 32;
    r.item_rows = ((int)tiles.size() + r.item_cols - 1) / r.item_cols;

    int w = r.item_cols * mca::TILE_PX;
    int h = r.item_rows * mca::TILE_PX;
    std::vector<uint8_t> pixels((size_t)w * h * 4, 0);
    for (int i = 0; i < (int)tiles.size(); i++) {
        int col = i % r.item_cols;
        int row = i / r.item_cols;
        for (int y = 0; y < mca::TILE_PX; y++)
            for (int x = 0; x < mca::TILE_PX; x++) {
                const uint8_t *sp = tiles[(size_t)i].at(x, y);
                uint8_t *dp = &pixels[(((size_t)row * mca::TILE_PX + y) * w
                        + col * mca::TILE_PX + x) * 4];
                dp[0] = sp[0]; dp[1] = sp[1]; dp[2] = sp[2]; dp[3] = sp[3];
            }
    }

    r.item_atlas.upload(w, h, pixels.data());
    DBG("render: %zu items offered (%s), atlas %dx%d",
            r.item_ids.size(), from_registry ? "from the save's registry" : "from texture names",
            w, h);
}

/*! Uploads r.tiles as the atlas texture: one row, so a tile's atlas coordinate is its index and
 * nothing has to divide. Every mesh built before has its coordinates for the old row length, so
 * whoever adds tiles after the first upload rebuilds them (render_block_tiles does).
 * @date 2026-10-04, out of build_atlas */
inline void upload_atlas(renderer_t &r) {
    r.tile_count = (int)r.tiles.size();
    r.atlas_w = r.tile_count * mca::TILE_PX;

    std::vector<uint8_t> pixels((size_t)r.atlas_w * mca::TILE_PX * 4, 0);
    for (int i = 0; i < r.tile_count; i++)
        for (int y = 0; y < mca::TILE_PX; y++)
            for (int x = 0; x < mca::TILE_PX; x++) {
                const uint8_t *s = r.tiles[i].at(x, y);
                uint8_t *d = &pixels[((size_t)y * r.atlas_w + i * mca::TILE_PX + x) * 4];
                d[0] = s[0]; d[1] = s[1]; d[2] = s[2]; d[3] = s[3];
            }

    r.atlas.upload(r.atlas_w, mca::TILE_PX, pixels.data());
}

inline void build_atlas(renderer_t &r) {
    mca::mc_source_t src;
    r.mc_loaded = src.open(r.mc_path);
    r.vanilla_loaded = src.open_vanilla(r.vanilla_path);
    src.open_extras(r.mc_path);
    r.irontank_loaded = src.irontank_open();
    r.gregtech_loaded = src.gregtech_open();

    r.fluid_names.clear();
    r.fluid_labels.clear();
    r.fluid_tile.clear();
    r.block_tiles.clear();

    std::vector<mca::tile_t> &tiles = r.tiles;
    tiles.clear();

    auto push = [&](const mca::tile_t &t) {
        tiles.push_back(t);
        return (int)tiles.size() - 1;
    };

    /*! The same for one of GregTech's own block textures. @date 2026-09-17 */
    auto load_gt_or = [&](const char *name, const mca::tile_t &fallback) {
        mca::tile_t t;
        if (src.gt_block_tile(name, t))
            return t;
        return fallback;
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

    /* A sign: vanilla's own planks, which is what one is made of. The text is not drawn here -
    it is not a texture but a string, and the interface puts it on the screen over the block. */
    {
        mca::tile_t planks = load_vanilla_or("planks_oak", mca::fallback_panel(150, 120, 70, 171));
        mca::tile_t face = planks;
        for (int y = 3; y <= 12; y++)
            for (int x = 2; x <= 13; x++) {
                int n = mca::speckle(x, y, 173) / 3;
                face.set(x, y, mca::clamp8(196 + n), mca::clamp8(170 + n), mca::clamp8(120 + n));
            }
        for (int st = 0; st < 4; st++) {
            r.tile_cell[worldc::CELL_KIND_SIGN][st][ROLE_FRONT] = push(face);
            r.tile_cell[worldc::CELL_KIND_SIGN][st][ROLE_BACK]  = push(planks);
            r.tile_cell[worldc::CELL_KIND_SIGN][st][ROLE_TOP]   = push(planks);
            r.tile_cell[worldc::CELL_KIND_SIGN][st][ROLE_SIDE]  = push(planks);
        }
    }

    /* The quantum tank: THE SAME MODEL AS THE IRON TANK, in a different metal.
    
    The author asked on 2026-09-17 not to change the tank's model - "I liked that one" - so this is
    not GregTech's own quantum tank, which is an opaque machine casing you cannot see into. It is
    Iron Tanks' tungstensteel tier: the same frame around the same window, dark enough to tell the
    two apart down a row, and still showing what is inside. The difference that matters is not what
    it looks like but what it holds, which is sixteen times the other. */
    {
        mca::tile_t side, top;
        if (!src.tank_tile("tungstensteelTank", "side", side))
            side = mca::fallback_panel(92, 100, 116, 161);
        if (!src.tank_tile("tungstensteelTank", "topbottom", top))
            top = mca::fallback_panel(78, 86, 100, 163);

        for (int st = 0; st < 4; st++) {
            r.tile_cell[worldc::CELL_KIND_QTANK][st][ROLE_FRONT] = push(side);
            r.tile_cell[worldc::CELL_KIND_QTANK][st][ROLE_BACK]  = push(side);
            r.tile_cell[worldc::CELL_KIND_QTANK][st][ROLE_TOP]   = push(top);
            r.tile_cell[worldc::CELL_KIND_QTANK][st][ROLE_SIDE]  = push(side);
        }
    }

    /* The liquid tank. The author asked on 2026-09-17 for Iron Tanks' model, and that mod draws a
    tank as a metal frame with a hole in the middle - its side.png has one fully transparent palette
    entry - so the fluid inside is simply drawn as a smaller box behind it rather than being
    composited into the frame. The iron tier is the one used; the others are the same shape. */
    {
        mca::tile_t side, top;
        if (!src.tank_tile("ironTank", "side", side))
            side = mca::fallback_panel(150, 152, 156, 131);
        if (!src.tank_tile("ironTank", "topbottom", top))
            top = mca::fallback_panel(130, 132, 136, 137);

        for (int st = 0; st < 4; st++) {
            r.tile_cell[worldc::CELL_KIND_TANK][st][ROLE_FRONT] = push(side);
            r.tile_cell[worldc::CELL_KIND_TANK][st][ROLE_BACK]  = push(side);
            r.tile_cell[worldc::CELL_KIND_TANK][st][ROLE_TOP]   = push(top);
            r.tile_cell[worldc::CELL_KIND_TANK][st][ROLE_SIDE]  = push(side);
        }
    }

    /* The ME import and export buses. Scenery - the author asked on 2026-09-17 for the blocks and
    not the behaviour - so there is one look per kind and no lit variant. Applied Energistics draws
    these as cable parts rather than as blocks, so what it ships is the part's item picture.

    IT GOES ON EVERY FACE BUT THE FRONT. The front is the one pointing at the machine the bus was
    stuck to, which means it is flush against a solid block and culled - putting the picture there
    would hide the only thing that tells an import bus from an export bus. So the front is plain
    casing and the picture is on the faces somebody can actually see. */
    {
        mca::tile_t casing = load_or("MEChest", mca::fallback_panel(86, 92, 104, 151));
        mca::tile_t imp, exp;
        if (!src.ae2_tile("ItemPart.ImportBus", imp))
            imp = mca::fallback_panel(80, 130, 90, 153);
        if (!src.ae2_tile("ItemPart.ExportBus", exp))
            exp = mca::fallback_panel(150, 110, 70, 155);

        for (int st = 0; st < 4; st++) {
            r.tile_cell[worldc::CELL_KIND_IMPORT_BUS][st][ROLE_FRONT] = push(casing);
            r.tile_cell[worldc::CELL_KIND_IMPORT_BUS][st][ROLE_BACK]  = push(imp);
            r.tile_cell[worldc::CELL_KIND_IMPORT_BUS][st][ROLE_TOP]   = push(imp);
            r.tile_cell[worldc::CELL_KIND_IMPORT_BUS][st][ROLE_SIDE]  = push(imp);

            r.tile_cell[worldc::CELL_KIND_EXPORT_BUS][st][ROLE_FRONT] = push(casing);
            r.tile_cell[worldc::CELL_KIND_EXPORT_BUS][st][ROLE_BACK]  = push(exp);
            r.tile_cell[worldc::CELL_KIND_EXPORT_BUS][st][ROLE_TOP]   = push(exp);
            r.tile_cell[worldc::CELL_KIND_EXPORT_BUS][st][ROLE_SIDE]  = push(exp);
        }
    }

    /* The ME carriers. AE2 keeps its cable art beside its block art, as ItemPart.Cable*. */
    {
        mca::tile_t t;
        r.tile_ae_cable = src.ae2_tile("ItemPart.CableGlass", t)
                ? push(t) : push(mca::fallback_panel(150, 190, 220, 41));
        r.tile_ae_dense = src.ae2_tile("ItemPart.CableDense", t)
                ? push(t) : push(mca::fallback_panel(90, 120, 200, 43));
        /* EnderIO's own, out of EnderIO's jar. A conduit's LENGTH and its CORE are separate
        pictures there, which is exactly the pair the cable renderer wants. */
        r.tile_eio_me = src.eio_tile("meConduit", t)
                ? push(t) : push(mca::fallback_panel(200, 140, 60, 47));
        r.tile_eio_me_core = src.eio_tile("meConduitCore", t)
                ? push(t) : r.tile_eio_me;
        r.tile_eio_dense = src.eio_tile("meConduitDense", t)
                ? push(t) : push(mca::fallback_panel(220, 110, 40, 49));
        r.tile_eio_dense_core = src.eio_tile("meConduitCoreDense", t)
                ? push(t) : r.tile_eio_dense;
    }

    DBG("render: carriers oc=%d/%d ae=%d dense=%d eio=%d/%d eiodense=%d/%d",
            r.tile_cable, r.tile_cable_cap, r.tile_ae_cable, r.tile_ae_dense,
            r.tile_eio_me, r.tile_eio_me_core, r.tile_eio_dense, r.tile_eio_dense_core);

    /*! APPLIED ENERGISTICS' OWN ART, for the network debugger.
     *
     * Every one of these is a real texture out of the AE2 jar, so a controller looks like a
     * controller and a quantum link chamber is unmistakable at a glance. That is the entire point:
     * the first version of the debugger drew every node as a coloured tank, and a wall of tanks
     * tells you where the devices are but never what any of them IS.
     *
     * A fallback panel per kind for when the jar is absent, in the colours AE2 uses itself, so the
     * view still reads when somebody has no modpack installed. */
    {
        struct ae_kind_t {
            int kind;
            const char *face;           /* the distinctive face */
            const char *side;           /* everything else */
            int r, g, b;                /* the stand-in, when there is no jar */
        };
        static const ae_kind_t AE[] = {
            {worldc::CELL_KIND_AE_CONTROLLER, "BlockControllerPowered", "BlockController",
                    70, 130, 180},
            {worldc::CELL_KIND_AE_DRIVE,      "BlockDriveFront",  "BlockDriveSide",  90, 96, 104},
            {worldc::CELL_KIND_AE_INTERFACE,  "BlockInterface",   "BlockInterface", 120, 126, 134},
            {worldc::CELL_KIND_AE_FLUID_IF,   "BlockInterfaceAlternate",
                    "BlockInterfaceAlternate", 100, 150, 190},
            {worldc::CELL_KIND_AE_QUANTUM,    "BlockQuantumLinkChamber",
                    "BlockQuantumLinkChamber", 150, 110, 200},
            {worldc::CELL_KIND_AE_WIRELESS,   "BlockWirelessOn",  "BlockWireless",  190, 170, 90},
            {worldc::CELL_KIND_AE_ENERGY,     "BlockEnergyCell",  "BlockEnergyCell", 60, 170, 120},
            {worldc::CELL_KIND_AE_DEVICE,     "BlockChestSide",   "BlockChestSide", 140, 140, 145},
            /* A GregTech machine that speaks ME - a stocking bus, an output hatch - is not an AE2
            block and should not wear AE2's paint. The author, 2026-09-18: "stocking input bus is an
            me-capable item from gregtech and it's wrongly textured". GregTech's own casing is what
            it actually looks like. */
            {worldc::CELL_KIND_GT_ME,         nullptr,            nullptr,          120, 120, 125},
        };

        for (const ae_kind_t &k : AE) {
            mca::tile_t face, side;
            if (!k.face || !src.ae2_tile(k.face, face)) {
                /* GregTech's machine casing where there is one, and a plain panel otherwise. */
                if (!k.face && src.gt_block_tile("MACHINE_CASINGS/LV/1", face)) {
                    /* taken */
                }
                else {
                    face = mca::fallback_panel(k.r, k.g, k.b, 60 + k.kind);
                }
            }
            if (!k.side || !src.ae2_tile(k.side, side))
                side = face;

            for (int st = 0; st < 4; st++) {
                r.tile_cell[k.kind][st][ROLE_FRONT] = push(face);
                r.tile_cell[k.kind][st][ROLE_BACK]  = push(side);
                r.tile_cell[k.kind][st][ROLE_TOP]   = push(side);
                r.tile_cell[k.kind][st][ROLE_SIDE]  = push(side);
            }
        }
    }

    /* The three stand-ins, and every material's colour, for the fluids that have no picture of
    their own - which is most of them. */
    {
        mca::tile_t t;
        if (src.fluid_tile("autogenerated", t))
            r.tile_fluid_plain = push(t);
        if (src.fluid_tile("plasma.autogenerated", t))
            r.tile_fluid_plasma = push(t);
        if (src.fluid_tile("molten.autogenerated", t))
            r.tile_fluid_molten = push(t);

        for (const auto &kv : src.gt_materials()) {
            std::string key = kv.second.name;
            for (char &ch : key)
                ch = (char)tolower((unsigned char)ch);
            uint32_t rgb = ((uint32_t)(kv.second.r & 0xff) << 16)
                    | ((uint32_t)(kv.second.g & 0xff) << 8) | (uint32_t)(kv.second.b & 0xff);
            r.material_colour.emplace(key, rgb);
        }
    }

    /* Every fluid GregTech has a picture for, so a tank can show what is in it and the panel that
    configures one can show what it is offering. Reading the archive rather than naming fluids here
    is what keeps this honest when the modpack changes underneath it. */
    for (const std::string &name : src.fluid_names()) {
        mca::tile_t t;
        if (!src.fluid_tile(name, t))
            continue;
        r.fluid_tile[name] = push(t);
        r.fluid_names.push_back(name);
        r.fluid_labels.push_back(src.fluid_label(name));
    }
    DBG("render: %zu fluids from gregtech", r.fluid_names.size());

    /* A plain white square for anything drawn as a colour rather than as a picture. */
    {
        mca::tile_t solid;
        for (int y = 0; y < mca::TILE_PX; y++)
            for (int x = 0; x < mca::TILE_PX; x++)
                solid.set(x, y, 255, 255, 255);
        r.tile_solid = push(solid);
    }

    upload_atlas(r);

    build_item_atlas(r, src);
    DBG("render: atlas %dx%d, %d tiles, minecraft textures %s",
            r.atlas_w, mca::TILE_PX, r.tile_count, r.mc_loaded ? "loaded" : "not found");
}

/*! Which atlas tile draws a fluid, falling back to the greyscale stand-in for its kind.
 *
 * GregTech keeps a picture for only a fraction of its fluids and draws the rest as one of three
 * greyscale images coloured per material. Both this and fluid_tint_of are used by the mesh and by
 * the interface, so they sit here rather than beside the functions Lua calls.
 * @date 2026-09-17 */
inline int fluid_tile_of(const renderer_t &r, const std::string &name) {
    auto it = r.fluid_tile.find(name);
    if (it != r.fluid_tile.end())
        return it->second;
    if (name.compare(0, 7, "plasma.") == 0)
        return r.tile_fluid_plasma;
    if (name.compare(0, 7, "molten.") == 0)
        return r.tile_fluid_molten;
    return r.tile_fluid_plain;
}

/*! The colour that stand-in is multiplied by: the material's own, or white when it is not known -
 * and white for a fluid that has a picture already, since that picture is the right colour.
 * @date 2026-09-17 */
inline uint32_t fluid_tint_of(const renderer_t &r, const std::string &name) {
    if (r.fluid_tile.count(name))
        return 0xffffff;

    std::string n = name;
    if (n.compare(0, 7, "plasma.") == 0)
        n = n.substr(7);
    else if (n.compare(0, 7, "molten.") == 0)
        n = n.substr(7);
    for (char &ch : n)
        ch = (ch == '-') ? '_' : (char)tolower((unsigned char)ch);

    auto it = r.material_colour.find(n);
    return (it == r.material_colour.end()) ? 0xffffffu : it->second;
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
        v.tr = shade; v.tg = shade; v.tb = shade;
        verts.push_back(v);
    }

    indices.push_back(base + 0); indices.push_back(base + 1); indices.push_back(base + 2);
    indices.push_back(base + 0); indices.push_back(base + 2); indices.push_back(base + 3);
}

/*! The same as emit_face, with the texel also multiplied by a colour: a Minecraft block's own
 * tint, such as grass green on the game's grey grass picture. @date 2026-10-04 */
inline void emit_face_tinted(std::vector<glu::vertex_t> &verts, std::vector<uint32_t> &indices,
        int cx, int cy, int cz, int face, int tile, int tile_count, float shade,
        float tr, float tg, float tb)
{
    size_t first = verts.size();
    emit_face(verts, indices, cx, cy, cz, face, tile, tile_count, shade, 0.0f);
    for (size_t i = first; i < verts.size(); i++) {
        verts[i].tr *= tr; verts[i].tg *= tg; verts[i].tb *= tb;
    }
}

/*! Appends a cross: two quads through the cell's diagonals, upright, carrying the whole tile -
 * how Minecraft draws a flower, tall grass or a torch. Nothing culls faces here, so each quad is
 * seen from both sides. @date 2026-10-04 */
inline void emit_cross_tinted(std::vector<glu::vertex_t> &verts, std::vector<uint32_t> &indices,
        int cx, int cy, int cz, int tile, int tile_count, float tr, float tg, float tb)
{
    static const float QUADS[2][4][3] = {
        {{0, 0, 0}, {1, 0, 1}, {1, 1, 1}, {0, 1, 0}},
        {{1, 0, 0}, {0, 0, 1}, {0, 1, 1}, {1, 1, 0}},
    };
    float u0 = (float)tile / (float)tile_count;
    float du = 1.0f / (float)tile_count;
    for (int q = 0; q < 2; q++) {
        uint32_t base = (uint32_t)verts.size();
        for (int i = 0; i < 4; i++) {
            glu::vertex_t v;
            v.x = cx + QUADS[q][i][0];
            v.y = cy + QUADS[q][i][1];
            v.z = cz + QUADS[q][i][2];
            v.u = u0 + FACE_UV[i][0] * du;
            v.v = FACE_UV[i][1];
            v.tr = tr; v.tg = tg; v.tb = tb;
            verts.push_back(v);
        }
        indices.push_back(base + 0); indices.push_back(base + 1); indices.push_back(base + 2);
        indices.push_back(base + 0); indices.push_back(base + 2); indices.push_back(base + 3);
    }
}

inline void emit_box_tinted(std::vector<glu::vertex_t> &verts, std::vector<uint32_t> &indices,
        const float lo[3], const float hi[3], int tile, int tile_count,
        float tr, float tg, float tb);

/*! The building blocks that are not whole cubes, as boxes inside the cell - slabs, stairs, fences,
 * panes, gates, trapdoors and doors (cell_t::shape 3..12). The tile is stretched over each box's
 * faces rather than cut to it, which is close enough to read what the block is.
 *
 * Fences and panes look at their four neighbours and reach toward a fence, a gate or a pane like
 * themselves, or a whole cube, as the game joins them. @date 2026-10-04 */
inline void emit_part_shape(std::vector<glu::vertex_t> &verts, std::vector<uint32_t> &indices,
        const worldc::world_t &w, const worldc::cell_t &c, int tile, int tile_count,
        float tr, float tg, float tb)
{
    const float X = (float)c.x, Y = (float)c.y, Z = (float)c.z;
    auto box = [&](float x0, float y0, float z0, float x1, float y1, float z1) {
        float lo[3] = {X + x0, Y + y0, Z + z0};
        float hi[3] = {X + x1, Y + y1, Z + z1};
        emit_box_tinted(verts, indices, lo, hi, tile, tile_count, tr, tg, tb);
    };
    /* The horizontal facings as a step: -x, +x, -z, +z. */
    int dx = c.facing == worldc::FACE_XNEG ? -1 : c.facing == worldc::FACE_XPOS ? 1 : 0;
    int dz = c.facing == worldc::FACE_ZNEG ? -1 : c.facing == worldc::FACE_ZPOS ? 1 : 0;

    switch (c.shape) {
    case 3: box(0, 0, 0, 1, 0.5f, 1); break;
    case 4: box(0, 0.5f, 0, 1, 1, 1); break;
    case 5: case 6: {
        bool down = c.shape == 6;
        box(0, down ? 0.5f : 0, 0, 1, down ? 1 : 0.5f, 1);
        float x0 = dx > 0 ? 0.5f : 0, x1 = dx < 0 ? 0.5f : 1;
        float z0 = dz > 0 ? 0.5f : 0, z1 = dz < 0 ? 0.5f : 1;
        box(x0, down ? 0 : 0.5f, z0, x1, down ? 0.5f : 1, z1);
        break;
    }
    case 7: case 8: {
        bool pane = c.shape == 8;
        float t0 = pane ? 0.4375f : 0.375f, t1 = pane ? 0.5625f : 0.625f;
        auto joins = [&](int ox, int oz) {
            worldc::cell_p n = w.get(c.x + ox, c.y, c.z + oz);
            if (!n) return false;
            if (n->kind != worldc::CELL_KIND_MC_BLOCK) return worldc::kind_is_full_cube(n->kind);
            if (n->ghost) return false;
            return n->shape == 0 || n->shape == c.shape || (!pane && n->shape == 9);
        };
        bool e = joins(1, 0), wst = joins(-1, 0), s = joins(0, 1), nth = joins(0, -1);
        if (pane && !e && !wst && !s && !nth) e = wst = s = nth = true;
        box(t0, 0, t0, t1, 1, t1);                              /* the post, or the pane's middle */
        const float r0[2] = {pane ? 0.0f : 0.375f, pane ? 0.0f : 0.75f};
        const float r1[2] = {pane ? 1.0f : 0.5625f, pane ? 1.0f : 0.9375f};
        int rails = pane ? 1 : 2;
        for (int k = 0; k < rails; k++) {
            float a = r0[k], b = r1[k];
            float u0 = pane ? t0 : 0.4375f, u1 = pane ? t1 : 0.5625f;
            if (e)   box(t1, a, u0, 1, b, u1);
            if (wst) box(0, a, u0, t0, b, u1);
            if (s)   box(u0, a, t1, u1, b, 1);
            if (nth) box(u0, a, 0, u1, b, t0);
        }
        break;
    }
    case 9: {
        bool across_x = dz != 0;                    /* a gate facing north or south spans x */
        auto span = [&](float a0, float b0, float a1, float b1, float y0, float y1) {
            if (across_x) box(a0, y0, b0, a1, y1, b1); else box(b0, y0, a0, b1, y1, a1);
        };
        span(0, 0.4375f, 0.125f, 0.5625f, 0.3125f, 1);          /* the posts */
        span(0.875f, 0.4375f, 1, 0.5625f, 0.3125f, 1);
        span(0.125f, 0.4375f, 0.875f, 0.5625f, 0.375f, 0.5625f);  /* the rails */
        span(0.125f, 0.4375f, 0.875f, 0.5625f, 0.75f, 0.9375f);
        break;
    }
    case 10: box(0, 0, 0, 1, 0.1875f, 1); break;
    case 11: box(0, 0.8125f, 0, 1, 1, 1); break;
    case 12: {
        if (dx > 0)      box(0.8125f, 0, 0, 1, 1, 1);
        else if (dx < 0) box(0, 0, 0, 0.1875f, 1, 1);
        else if (dz < 0) box(0, 0, 0, 1, 1, 0.1875f);
        else             box(0, 0, 0.8125f, 1, 1, 1);
        break;
    }
    default: box(0, 0, 0, 1, 1, 1);
    }
}

/*! Appends an axis-aligned box, six quads, each shaded by the direction it faces.
 *
 * The wires are built out of these. A box takes one tile rather than the cell tile table, because a
 * wire is the same colour on every side and has no notion of a front.
 * @date 2026-09-16 */
/*! The same as emit_box, but every texel multiplied by a colour.
 *
 * For the fluid standing inside a tank: GregTech draws most of its fluids as one greyscale picture
 * coloured per material, and this is where that colour is applied.
 * @date 2026-09-17 */
inline void emit_box_tinted(std::vector<glu::vertex_t> &verts, std::vector<uint32_t> &indices,
        const float lo[3], const float hi[3], int tile, int tile_count,
        float tr, float tg, float tb);

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
            v.tr = FACE_SHADE[f]; v.tg = FACE_SHADE[f]; v.tb = FACE_SHADE[f];
            verts.push_back(v);
        }
        indices.push_back(base + 0); indices.push_back(base + 1); indices.push_back(base + 2);
        indices.push_back(base + 0); indices.push_back(base + 2); indices.push_back(base + 3);
    }
}

inline void emit_box_tinted(std::vector<glu::vertex_t> &verts, std::vector<uint32_t> &indices,
        const float lo[3], const float hi[3], int tile, int tile_count,
        float tr, float tg, float tb)
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
            v.tr = FACE_SHADE[f] * tr; v.tg = FACE_SHADE[f] * tg;
            v.tb = FACE_SHADE[f] * tb;
            verts.push_back(v);
        }
        indices.push_back(base + 0); indices.push_back(base + 1); indices.push_back(base + 2);
        indices.push_back(base + 0); indices.push_back(base + 2); indices.push_back(base + 3);
    }
}

/*! Draws a small ball of one colour, standing off a face.
 *
 * Core: THE ONE THING IN THE WORLD THAT IS NOT A BOX. Everything else the renderer emits is a
 * textured cuboid, which is right for blocks and wrong for this: an indicator lamp on the side of a
 * control block reads as a lamp because it is round, and as another panel if it is square.
 *
 * Shaded by the normal rather than by which face it belongs to - a sphere has no faces to look up
 * in FACE_SHADE - so it keeps the flat-lit look of the rest without going dark all over.
 *
 * @param cx,cy,cz  where the middle of the ball sits, in world cells
 * @param radius    in cells
 * @date 2026-09-18 */
inline void emit_sphere_tinted(std::vector<glu::vertex_t> &verts, std::vector<uint32_t> &indices,
        float cx, float cy, float cz, float radius, int tile, int tile_count,
        float tr, float tg, float tb)
{
    /* Coarse on purpose: this is a blob a few pixels across on screen, and a finer one costs
    triangles for a difference nobody can see. */
    const int RINGS = 8, SEGS = 12;
    const float PI = 3.14159265358979f;

    float u0 = (float)tile / (float)tile_count;
    float du = 1.0f / (float)tile_count;
    uint32_t base = (uint32_t)verts.size();

    for (int i = 0; i <= RINGS; i++) {
        float phi = PI * (float)i / (float)RINGS;              /* 0 at the top, PI at the bottom */
        float sp = sinf(phi), cp = cosf(phi);
        for (int j = 0; j <= SEGS; j++) {
            float th = 2.0f * PI * (float)j / (float)SEGS;
            float nx = sp * cosf(th), ny = cp, nz = sp * sinf(th);

            glu::vertex_t v;
            v.x = cx + nx * radius;
            v.y = cy + ny * radius;
            v.z = cz + nz * radius;
            /* The middle of the tile, so nothing bleeds in from the squares either side of it. */
            v.u = u0 + du * 0.5f;
            v.v = 0.5f;

            /* Lit from above and a little to one side, which is what the box shading amounts to. */
            float lit = 0.62f + 0.26f * (ny * 0.5f + 0.5f) + 0.12f * (nx * 0.5f + 0.5f);
            v.tr = lit * tr; v.tg = lit * tg; v.tb = lit * tb;
            verts.push_back(v);
        }
    }

    for (int i = 0; i < RINGS; i++) {
        for (int j = 0; j < SEGS; j++) {
            uint32_t a = base + (uint32_t)(i * (SEGS + 1) + j);
            uint32_t b = a + (uint32_t)(SEGS + 1);
            indices.push_back(a);     indices.push_back(b);     indices.push_back(a + 1);
            indices.push_back(a + 1); indices.push_back(b);     indices.push_back(b + 1);
        }
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
/*! Draws an Applied Energistics part - a bus, an interface - on one face of a block.
 *
 * Core: A PART IS SMALL AND IT IS NOT A CUBE. Six of them fit on one cable bus along with the cable
 * itself, so anything drawn at the size of a block is not merely ugly, it makes the arrangement
 * impossible to see. AE2's own model is a wide flat plate against the surface with a narrower body
 * standing off it, and that is what this is: ten pixels across and two deep for the plate, six
 * across and five deep for the body.
 *
 * The lift off the surface is the wire's, for the same reason - a part sitting exactly on the face
 * fights it for the depth buffer.
 * @date 2026-09-18 */
inline void emit_part(std::vector<glu::vertex_t> &verts, std::vector<uint32_t> &indices,
        int cx, int cy, int cz, int face, int tile, int tile_count)
{
    int axis = face / 2;
    const int axes[2] = {(axis + 1) % 3, (axis + 2) % 3};
    int cell[3] = {cx, cy, cz};
    bool positive = worldc::FACE_DIR[face][axis] > 0;
    float plane = (float)cell[axis] + (positive ? 1.0f : 0.0f);

    /* plate and body, in sixteenths: how far in from the block's edge, and how far out. */
    const float SHAPE[2][2] = {{3.0f / 16.0f, 2.0f / 16.0f}, {5.0f / 16.0f, 5.0f / 16.0f}};

    for (const float *s : SHAPE) {
        float inset = s[0], depth = s[1];
        float lo[3], hi[3];
        lo[axis] = positive ? plane + WIRE_LIFT : plane - (WIRE_LIFT + depth);
        hi[axis] = positive ? plane + (WIRE_LIFT + depth) : plane - WIRE_LIFT;
        for (int i = 0; i < 2; i++) {
            lo[axes[i]] = (float)cell[axes[i]] + inset;
            hi[axes[i]] = (float)cell[axes[i]] + 1.0f - inset;
        }
        emit_box(verts, indices, lo, hi, tile, tile_count);
    }
}

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

/*! Rebuilds the mesh of one 16-cube section of the map (world_t::SECTION), emitting only the faces
 * something can see. Section `s` counts as world_t::section_bit does, x fastest; its cells, its
 * redstone lamps and the wires on its cells' faces are its own. The whole map was one mesh until
 * 2026-10-05, rebuilt on every change - 0.08 s for one cell (3d-draw/redesign/08-order.md).
 *
 * What follows is that mesher's rule, unchanged:
 *
 * A face is emitted when the neighbour in that direction is empty, which for a lone block means all
 * six and for a wall means only its outside. The bottom face of a cell resting on the floor is the
 * one exception: it is dropped because it is coplanar with the ground quad underneath and the two
 * would otherwise fight over the same depth.
 * @date 2026-09-16 */
inline void rebuild_world_section(renderer_t &r, const worldc::world_t &w, int s) {
    std::vector<glu::vertex_t> verts;
    std::vector<uint32_t> indices;
    std::vector<glu::vertex_t> gverts;             /* the see-through blocks, ghost 2 */
    std::vector<uint32_t> gindices;

    const int S = worldc::world_t::SECTION;
    const int sx = s % worldc::world_t::SECTIONS_X;
    const int sy = (s / worldc::world_t::SECTIONS_X) % worldc::world_t::SECTIONS_Y;
    const int sz = s / (worldc::world_t::SECTIONS_X * worldc::world_t::SECTIONS_Y);
    const int x0 = sx * S, y0 = sy * S, z0 = sz * S;
    auto inside = [&](int x, int y, int z) {
        return x >= x0 && x < x0 + S && y >= y0 && y < y0 + S && z >= z0 && z < z0 + S;
    };
    /* The section's cells, in the order the whole map's were walked. */
    std::vector<worldc::cell_p> here;
    for (int z = z0; z < z0 + S; z++)
        for (int y = y0; y < y0 + S; y++)
            for (int x = x0; x < x0 + S; x++)
                if (worldc::cell_p c = w.get(x, y, z))
                    here.push_back(c);

    for (const worldc::cell_p &c : here) {
        if (!c)
            continue;

        int kind = c->kind;
        int state = c->state;
        if (kind < 0 || kind >= KIND_MAX) kind = worldc::CELL_KIND_CASE;
        if (state < 0 || state > 3) state = worldc::CELL_STATE_OFF;

        /* A Minecraft block a scene named (3d-draw): its own tile and tint, a plain cube of the
        tint when it has no tile, and a guess (ghost 1) drawn as a smaller box so it reads as one.
        A face is hidden only by a neighbour that is a whole, seen block. Ghost 2 is whole but
        see-through - what a build still has to place (3d-draw's J, the user, 2026-10-05: "the
        rest as ghostly blocks, with say 30% alpha") - and goes to the section's second mesh;
        between two of those the faces are hidden too, so only their outside is drawn. */
        if (c->kind == worldc::CELL_KIND_MC_BLOCK) {
            const bool see = c->ghost == 2;
            std::vector<glu::vertex_t> &V = see ? gverts : verts;
            std::vector<uint32_t> &I = see ? gindices : indices;
            int tile = (c->tile >= 0 && c->tile < r.tile_count) ? c->tile : r.tile_solid;
            float tr = (float)((c->tint >> 16) & 0xff) / 255.0f;
            float tg = (float)((c->tint >> 8) & 0xff) / 255.0f;
            float tb = (float)(c->tint & 0xff) / 255.0f;
            if (c->ghost == 1) {
                float lo[3] = {c->x + 0.3f, c->y + 0.3f, c->z + 0.3f};
                float hi[3] = {c->x + 0.7f, c->y + 0.7f, c->z + 0.7f};
                emit_box_tinted(V, I, lo, hi, tile, r.tile_count, tr, tg, tb);
                continue;
            }
            if (c->shape == 1) {
                emit_cross_tinted(V, I, c->x, c->y, c->z, tile, r.tile_count,
                        tr, tg, tb);
                continue;
            }
            if (c->shape >= 3) {
                emit_part_shape(V, I, w, *c, tile, r.tile_count, tr, tg, tb);
                continue;
            }
            for (int f = 0; f < worldc::FACE_COUNT; f++) {
                worldc::cell_p n = w.get(c->x + worldc::FACE_DIR[f][0],
                        c->y + worldc::FACE_DIR[f][1], c->z + worldc::FACE_DIR[f][2]);
                bool hides = n && worldc::kind_is_full_cube(n->kind)
                        && !(n->kind == worldc::CELL_KIND_MC_BLOCK
                             && (n->ghost || n->shape != 0));
                if (see && n && n->kind == worldc::CELL_KIND_MC_BLOCK && n->ghost == 2
                        && n->shape == 0)
                    hides = true;
                if (hides && c->shape == 0)
                    continue;
                if (f == worldc::FACE_YNEG && c->y == 0)
                    continue;
                emit_face_tinted(V, I, c->x, c->y, c->z, f, tile, r.tile_count,
                        FACE_SHADE[f], tr, tg, tb);
            }
            continue;
        }

        /* A cable is not a cube: its shape follows what it joins onto, so it is built whole and
        the per-face walk below is skipped entirely. */
        if (worldc::kind_is_cable(kind)) {
            int tile = r.tile_cable, cap = r.tile_cable_cap;
            if (kind == worldc::CELL_KIND_AE_CABLE)      { tile = cap = r.tile_ae_cable; }
            else if (kind == worldc::CELL_KIND_AE_DENSE) { tile = cap = r.tile_ae_dense; }
            else if (kind == worldc::CELL_KIND_EIO_ME) {
                tile = r.tile_eio_me; cap = r.tile_eio_me_core;
            }
            else if (kind == worldc::CELL_KIND_EIO_DENSE) {
                tile = r.tile_eio_dense; cap = r.tile_eio_dense_core;
            }
            emit_cable(verts, indices, c->x, c->y, c->z,
                    w.cable_links(c->x, c->y, c->z), tile, cap, r.tile_count);
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

        /* What is in a tank, drawn as a smaller box standing inside the shell. It is visible
        because the shell's own texture has a transparent middle and the fragment shader discards
        fully transparent texels - the same arrangement Iron Tanks itself uses. The box is as tall
        as the tank is full, so a glance says roughly how much is in there. */
        if (worldc::kind_is_tank(kind) && !c->fluid.empty() && c->fluid_amount > 0.0) {
            int tile = fluid_tile_of(r, c->fluid);
            uint32_t rgb = fluid_tint_of(r, c->fluid);
            if (tile >= 0) {
                /* THE TANK'S OWN CAPACITY, not a constant. A quantum tank holds sixteen times
                what an ordinary one does, so dividing by the ordinary figure drew every bank tank
                brim full from a sixteenth of the way up - the author saw one reading full at seven
                percent. A cell already knows how much it can hold; nothing else should decide. */
                double cap = c->fluid_capacity();
                double full = (cap > 0.0) ? (c->fluid_amount / cap) : 0.0;
                if (full > 1.0) full = 1.0;
                if (full < 0.0) full = 0.0;
                /* Never quite nothing: a tank holding a single litre of something should still
                show a film of it rather than looking empty. */
                float height = (float)(0.04 + full * 0.88);
                float lo[3] = {(float)c->x + 0.08f, (float)c->y + 0.04f, (float)c->z + 0.08f};
                float hi[3] = {(float)c->x + 0.92f, (float)c->y + 0.04f + height,
                        (float)c->z + 0.92f};
                emit_box_tinted(verts, indices, lo, hi, tile, r.tile_count,
                        ((rgb >> 16) & 0xff) / 255.0f, ((rgb >> 8) & 0xff) / 255.0f,
                        (rgb & 0xff) / 255.0f);
            }
        }
    }

    /* THE INPUT INDICATORS: a ball on every face something is wired into, dark red when the signal
    is down and bright when it is up.
    --
    -- The author, 2026-09-18: "draw it as a sphere on the face, black red not active, bright red
    -- active". It sits on the face rather than in the block because that is what it reports - what
    -- is coming IN on that side - and a face with nothing wired to it shows nothing at all, so the
    -- board reads as four lamps rather than as twenty-four. */
    for (const worldc::cell_p &c : here) {
        if (!c || c->kind != worldc::CELL_KIND_REDSTONE)
            continue;
        for (int f = 0; f < worldc::FACE_COUNT; f++) {
            if (!c->rs_in_wired(f))
                continue;
            bool on = c->rs_in_get(f) > 0;

            /* Just clear of the face, so it reads as a lamp set into the side rather than as a
            decal fighting the surface for the depth buffer. */
            const float out = 0.46f;
            const float radius = 0.13f;
            float bx = (float)c->x + 0.5f + (float)worldc::FACE_DIR[f][0] * out;
            float by = (float)c->y + 0.5f + (float)worldc::FACE_DIR[f][1] * out;
            float bz = (float)c->z + 0.5f + (float)worldc::FACE_DIR[f][2] * out;

            emit_sphere_tinted(verts, indices, bx, by, bz, radius, r.tile_solid, r.tile_count,
                    on ? 1.0f : 0.22f, on ? 0.13f : 0.02f, on ? 0.10f : 0.02f);
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
        if (!inside(wx, wy, wz))
            continue;
        if (wire->kind == worldc::CELL_KIND_KEYBOARD) {
            emit_keyboard(verts, indices, wx, wy, wz, wface, r.tile_keyboard, r.tile_count);
        }
        else if (wire->kind == worldc::CELL_KIND_IMPORT_BUS
                || wire->kind == worldc::CELL_KIND_EXPORT_BUS) {
            emit_part(verts, indices, wx, wy, wz, wface,
                    r.tile_cell[wire->kind][state][ROLE_FRONT], r.tile_count);
        }
        else {
            emit_wire(verts, indices, wx, wy, wz, wface,
                    w.face_links(wx, wy, wz, wface), r.tile_wire[state], r.tile_count);
        }
    }

    r.world_meshes[(size_t)s].upload(verts, indices);
    r.ghost_meshes[(size_t)s].upload(gverts, gindices);
}

/*! Brings the sections' meshes up to date: every one for a world not meshed before, else those
 * the world marked. A change that marked nothing (none should) rebuilds them all.
 * @date 2026-10-05 */
inline void rebuild_world_mesh(renderer_t &r, worldc::world_t &w) {
    const int n = worldc::world_t::SECTIONS_X * worldc::world_t::SECTIONS_Y
            * worldc::world_t::SECTIONS_Z;
    uint64_t dirty = w.take_dirty();
    if (r.mesh_world != &w || dirty == 0)
        dirty = ~0ull;
    for (int s = 0; s < n; s++)
        if (dirty & (1ull << s))
            rebuild_world_section(r, w, s);
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
            float lit = 0.55f + 0.45f * (v.y * 0.5f + 0.5f);
            v.tr = lit; v.tg = lit; v.tb = lit;
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
    r.loc_alpha  = r.shader.uniform("u_alpha_pct");
    r.attr_pos   = r.shader.attribute("a_pos");
    r.attr_uv    = r.shader.attribute("a_uv");
    r.attr_tint = r.shader.attribute("a_tint");

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
    r.mesh_world = nullptr;       /* every section again, not only those marked */
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
/*! Every fluid the installed GregTech has a picture for, by internal name.
 *
 * What a tank can be configured to hold. Empty when GregTech is not there, which the panel shows
 * as "no fluids found" rather than pretending to a list of its own.
 * @date 2026-09-17 */
inline std::vector<std::string> render_fluid_names() {
    return renderc::g_rend.fluid_names;
}

/*! The same fluids, as the game writes them - "Sulfuric Acid" for "sulfuricacid".
 *
 * A second list rather than a table of pairs, because it is handed to Lua as a plain array and
 * the two are always the same length and the same order.
 * @date 2026-09-17 */
inline std::vector<std::string> render_fluid_labels() {
    return renderc::g_rend.fluid_labels;
}

/*! Where one fluid's picture sits in the atlas, or -1 when it has none.
 *
 * For drawing a fluid in the interface: hand it to render_tile_uv's companion the same way a
 * cell's face tile is used.
 * @date 2026-09-17 */
inline double render_fluid_tile(const char *name) {
    if (!name)
        return -1.0;
    const renderer_t &r = renderc::g_rend;

    /* No picture of its own is the usual case; see fluid_tile_of. */
    return (double)fluid_tile_of(r, name);
}

/*! The colour a fluid is drawn in, as 0x00RRGGBB, or white when it is not known.
 *
 * Core: GregTech's own model. A fluid with no texture is a greyscale picture multiplied by the
 * material's colour, and the colour comes out of the same constructor the material's texture set
 * does - see mc_assets.h's gt_materials. A fluid that HAS its own picture is left alone, because
 * that picture is already the right colour.
 * @date 2026-09-17 */
inline double render_fluid_tint(const char *name) {
    if (!name)
        return (double)0xffffff;
    return (double)fluid_tint_of(renderc::g_rend, name);
}

/*! Where a tile sits in the atlas, as `{u0, v0, u1, v1}`.
 *
 * The same answer render_tile_uv gives for a cell's face, but for a tile index that was not found
 * through a cell - a fluid's, which belongs to no kind.
 * @date 2026-09-17 */
inline std::vector<double> render_tile_uv_at(int tile) {
    const renderer_t &r = renderc::g_rend;
    if (tile < 0 || tile >= r.tile_count || r.tile_count <= 0)
        return {0.0, 0.0, 1.0, 1.0};
    double du = 1.0 / (double)r.tile_count;
    return {(double)tile * du, 0.0, (double)(tile + 1) * du, 1.0};
}

/*! Finds block textures for a scene that names arbitrary Minecraft blocks (3d-draw), adds the
 * ones found to the atlas, and answers each key's tile, or -1.
 *
 * `keys` is one per line, lower case: `minecraft:<file>` is a vanilla block texture, any other
 * `<namespace>:<file>` is looked for in every jar under mods/, the way mod_textures keys them
 * (its subfolder dropped), and `<namespace>:<folder>/<file>` is that one file in that folder. 1.7.10 has no block models, so which file draws a block is the
 * scene's guess, and the scene falls back to a colour for a -1.
 *
 * Every key is looked for once: the answer, -1 too, is kept in block_tiles. The jars are read
 * in one pass for all the keys of a call, so a scene should ask for a batch. Adding tiles
 * changes the atlas's row length, so the meshes are rebuilt.
 * @date 2026-10-04 */
inline std::vector<double> render_block_tiles(const char *keys) {
    renderer_t &r = renderc::g_rend;
    std::vector<std::string> list;
    std::string cur;
    for (const char *p = keys ? keys : ""; ; p++) {
        if (*p == '\n' || *p == 0) {
            if (!cur.empty()) list.push_back(cur);
            cur.clear();
            if (*p == 0) break;
        }
        else if (*p != '\r') {
            cur += (char)tolower((unsigned char)*p);
        }
    }

    std::vector<std::string> vanilla;
    std::unordered_set<std::string> wanted;
    for (const std::string &k : list) {
        if (r.block_tiles.count(k))
            continue;
        if (k.rfind("minecraft:", 0) == 0) vanilla.push_back(k);
        else wanted.insert(k);
    }
    if (!vanilla.empty() || !wanted.empty()) {
        mca::mc_source_t src;
        src.open(r.mc_path);
        src.open_vanilla(r.vanilla_path);
        size_t before = r.tiles.size();
        for (const std::string &k : vanilla) {
            mca::tile_t t;
            if (src.vanilla_tile(k.c_str() + 10, t)) {
                r.block_tiles[k] = (int)r.tiles.size();
                r.tiles.push_back(t);
            }
            else {
                r.block_tiles[k] = -1;
            }
        }
        std::map<std::string, mca::tile_t> found = src.mod_textures(r.mc_path, wanted);
        for (const std::string &k : wanted) {
            auto it = found.find(k);
            if (it != found.end()) {
                r.block_tiles[k] = (int)r.tiles.size();
                r.tiles.push_back(it->second);
            }
            else {
                r.block_tiles[k] = -1;
            }
        }
        if (r.tiles.size() != before) {
            upload_atlas(r);
            build_ground_mesh(r);
            build_marker_mesh(r);
            rebuild_highlight_mesh(r);
            r.mesh_version = 0;
            r.mesh_world = nullptr;   /* every section again, not only those marked */
        }
        DBG("render: block textures, %zu asked, %zu new tiles", list.size(),
                r.tiles.size() - before);
    }

    std::vector<double> out;
    for (const std::string &k : list)
        out.push_back((double)r.block_tiles[k]);
    return out;
}

/*! What a liquid tank holds when it is full, in litres. GregTech's Super Tank IV.
 * @date 2026-09-17 */
inline double render_tank_capacity() {
    return worldc::TANK_CAPACITY_L;
}

/*! Every item the panel can stock a chest with, as ids.
 *
 * Real registry names when there is a save to read them out of - see build_item_atlas.
 * @date 2026-09-17 */
inline std::vector<std::string> render_item_ids() {
    return renderc::g_rend.item_ids;
}

/*! The same, tidied for reading - "apple golden" rather than "apple_golden". @date 2026-09-17 */
inline std::vector<std::string> render_item_labels() {
    return renderc::g_rend.item_labels;
}

/*! The GL texture the item pictures live in. A different one from the world's atlas.
 * @date 2026-09-17 */
/*! The variant of each offered item, matching render_item_ids one for one. @date 2026-09-17 */
inline std::vector<double> render_item_damage() {
    std::vector<double> out;
    out.reserve(renderc::g_rend.item_damage.size());
    for (int d : renderc::g_rend.item_damage)
        out.push_back((double)d);
    return out;
}

inline bool render_item_from_registry() {
    return renderc::g_rend.items_from_registry;
}

/*! The GL texture the item pictures live in. A different one from the world's atlas.
 * @date 2026-09-17 */
inline double render_item_atlas_id() {
    return (double)renderc::g_rend.item_atlas.tex;
}

/*! Where one item sits in the item atlas, as `{u0, v0, u1, v1}`.
 *
 * A whole tile of a blank texture when the item is not in the catalogue, so a caller drawing an
 * unknown name gets nothing rather than a wrong picture.
 * @date 2026-09-17 */
inline std::vector<double> render_item_uv(const char *id, int damage) {
    const renderer_t &r = renderc::g_rend;
    if (!id || r.item_cols <= 0 || r.item_rows <= 0)
        return {0.0, 0.0, 0.0, 0.0};
    auto it = r.item_index.find(std::string(id) + "#" + std::to_string(damage));
    if (it == r.item_index.end())
        return {0.0, 0.0, 0.0, 0.0};

    int col = it->second % r.item_cols;
    int row = it->second / r.item_cols;
    return {(double)col / r.item_cols, (double)row / r.item_rows,
            (double)(col + 1) / r.item_cols, (double)(row + 1) / r.item_rows};
}

/*! Where a point in the world lands on the screen.
 *
 * Core: FOR DRAWING TEXT ON A BLOCK. A sign carries a string, and a string is not a texture - it
 * has to be drawn by the interface, which needs to know where the block is in screen coordinates.
 * The same projection the world pass uses, so a label lands exactly on the block it belongs to.
 *
 * Answers `{x, y, visible}` - visible is nought when the point is behind the camera or off the
 * edge, which a caller must check before drawing or the text lands on the wrong side of the
 * screen.
 * @date 2026-09-18 */
inline std::tuple<double, double, double> cam_forward();   /* defined below, with the camera */

inline std::vector<double> render_project(double wx, double wy, double wz,
        int width, int height) {
    const renderer_t &r = renderc::g_rend;
    if (width <= 0 || height <= 0)
        return {0.0, 0.0, 0.0};

    float eye[3] = {r.cam_x, r.cam_y, r.cam_z};
    auto [fx, fy, fz] = renderc::cam_forward();
    float fwd[3] = {(float)fx, (float)fy, (float)fz};
    float up[3] = {0, 1, 0};

    glu::mat4_t proj = glu::mat4_t::perspective(r.cam_fov, (float)width / (float)height,
            0.05f, 512.0f);
    glu::mat4_t view = glu::mat4_t::look_dir(eye, fwd, up);
    glu::mat4_t mvp = glu::mat4_t::mul(proj, view);

    /* Column-major, the way mat4_t stores it and the way the shader multiplies. */
    const float *m = mvp.m;
    float x = (float)wx, y = (float)wy, z = (float)wz;
    float cx = m[0] * x + m[4] * y + m[8]  * z + m[12];
    float cy = m[1] * x + m[5] * y + m[9]  * z + m[13];
    float cw = m[3] * x + m[7] * y + m[11] * z + m[15];

    if (cw <= 0.0001f)
        return {0.0, 0.0, 0.0};             /* behind the eye */

    double sx = (cx / cw * 0.5 + 0.5) * width;
    double sy = (1.0 - (cy / cw * 0.5 + 0.5)) * height;
    return {sx, sy, 1.0};
}

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

/*! How opaque the see-through blocks (ghost 2) are drawn, in percent, 0 to 100. @date 2026-10-05 */
inline void render_ghost_alpha(int pct) {
    renderc::g_rend.ghost_alpha = pct < 0 ? 0 : pct > 100 ? 100 : pct;
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
    if (r.loc_alpha >= 0)
        glUniform1i(r.loc_alpha, 100);

    r.ground_mesh.draw(r.attr_pos, r.attr_uv, r.attr_tint);
    for (const glu::mesh_t &m : r.world_meshes)
        m.draw(r.attr_pos, r.attr_uv, r.attr_tint);

    /* The see-through blocks last of the world, tested against the depth the solid ones left but
    writing none, so one does not hide another behind it. @date 2026-10-05 */
    if (r.loc_alpha >= 0)
        glUniform1i(r.loc_alpha, r.ghost_alpha);
    glDepthMask(GL_FALSE);
    for (const glu::mesh_t &m : r.ghost_meshes)
        m.draw(r.attr_pos, r.attr_uv, r.attr_tint);
    glDepthMask(GL_TRUE);
    if (r.loc_alpha >= 0)
        glUniform1i(r.loc_alpha, 100);
    r.highlight_mesh.draw(r.attr_pos, r.attr_uv, r.attr_tint);

    /* The marker goes last and with its own matrix: the sphere is a unit ball at the origin, so the
    model transform is what puts it where the crosshair is pointing. Still depth tested, so a ball
    behind a block is hidden by it - which is correct, since a block cannot be placed there either
    without the ray having stopped short of it. */
    if (r.have_marker) {
        glu::mat4_t model = glu::mat4_t::translate_scale(r.mk_x, r.mk_y, r.mk_z, r.mk_radius);
        glu::mat4_t marker_mvp = glu::mat4_t::mul(mvp, model);
        glUniformMatrix4fv(r.loc_mvp, 1, GL_FALSE, marker_mvp.m);
        r.marker_mesh.draw(r.attr_pos, r.attr_uv, r.attr_tint);
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
        {"render_fluid_names", vc::luaw_function_wrapper<
               /* FN:    */ renderc::render_fluid_names
        >},
        {"render_fluid_labels", vc::luaw_function_wrapper<
               /* FN:    */ renderc::render_fluid_labels
        >},
        {"render_fluid_tile", vc::luaw_function_wrapper<
               /* FN:    */ renderc::render_fluid_tile,
               /* PARAMS:*/ const char *
        >},
        {"render_fluid_tint", vc::luaw_function_wrapper<
               /* FN:    */ renderc::render_fluid_tint,
               /* PARAMS:*/ const char *
        >},
        {"render_tile_uv_at", vc::luaw_function_wrapper<
               /* FN:    */ renderc::render_tile_uv_at,
               /* PARAMS:*/ int
        >},
        {"render_block_tiles", vc::luaw_function_wrapper<
               /* FN:    */ renderc::render_block_tiles,
               /* PARAMS:*/ const char *
        >},
        {"render_tank_capacity", vc::luaw_function_wrapper<
               /* FN:    */ renderc::render_tank_capacity
        >},
        {"render_item_ids", vc::luaw_function_wrapper<
               /* FN:    */ renderc::render_item_ids
        >},
        {"render_item_labels", vc::luaw_function_wrapper<
               /* FN:    */ renderc::render_item_labels
        >},
        {"render_item_from_registry", vc::luaw_function_wrapper<
               /* FN:    */ renderc::render_item_from_registry
        >},
        {"render_item_atlas_id", vc::luaw_function_wrapper<
               /* FN:    */ renderc::render_item_atlas_id
        >},
        {"render_item_uv", vc::luaw_function_wrapper<
               /* FN:    */ renderc::render_item_uv,
               /* PARAMS:*/ const char *, int
        >},
        {"render_item_damage", vc::luaw_function_wrapper<
               /* FN:    */ renderc::render_item_damage
        >},
        {"render_project", vc::luaw_function_wrapper<
               /* FN:    */ renderc::render_project,
               /* PARAMS:*/ double, double, double, int, int
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
        {"render_ghost_alpha", vc::luaw_function_wrapper<
               /* FN:    */ renderc::render_ghost_alpha,
               /* PARAMS:*/ int
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
