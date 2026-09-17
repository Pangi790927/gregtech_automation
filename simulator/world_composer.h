#ifndef WORLD_COMPOSER_H
#define WORLD_COMPOSER_H

/*! world_composer.h - the map and the things in it: a `cell_t` is one block, a `world_t` is the
 * matrix of them, and both are C++ objects Lua holds references to.
 *
 * Core: a cell is a leaf. It is the same idea as math_writer's `mexpr_t` - a C++ object with a free
 * `u` slot Lua hangs its own table on - minus the tree. An mexpr has children and a parent; a cell
 * has a position and nothing below it. The author's framing, 2026-09-16: what Lua stores at a slot
 * is "similar to an mexpr ... but not a recursive one, only a cell".
 *
 * Who does what. Lua asks for a cell, decides where it goes, and puts it there; the matrix, the
 * bounds, the ray marching and the notion of what a cell is are all here. A cell carries only what
 * drawing and simulation need to agree on - a kind, a state, a facing and where it sits - because
 * everything else Lua invents for itself goes in `u`, where adding a field costs no C++ change.
 *
 * Changing a cell makes it react. Writing `cell.state = 1` from Lua goes through a setter
 * registered below that bumps the owning world's version, and the renderer rebuilds its mesh when
 * that version moves. That is the whole mechanism behind a cell reacting to being modified, and it
 * is why these three fields have a hand-written setter instead of the stock one.
 *
 * @date 2026-09-16 */

#include "virt_composer.h"

#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <unordered_map>
#include <string>
#include <tuple>
#include <vector>

namespace virt_composer {

VIRT_COMPOSER_REGISTER_TYPE(SIM_TYPE_CELL);
VIRT_COMPOSER_REGISTER_TYPE(SIM_TYPE_WORLD);

} /* namespace virt_composer */

namespace world_composer {

namespace vc = virt_composer;
namespace worldc = world_composer;

/*! The map's extent, in cells: 64 wide, 64 long and 32 tall, as asked for. X is width, Z is length
 * and Y is height, so Y is up - which is both what OpenGL expects of a default camera and what
 * Minecraft itself uses, keeping the coordinates readable against the game they model.
 * @date 2026-09-16 */
constexpr int WORLD_X = 64;
constexpr int WORLD_Y = 32;
constexpr int WORLD_Z = 64;

/*! What a cell is. Zero is reserved for "nothing", so a kind is never confused with an empty slot,
 * and the names are mirrored in scripts/blocks.lua rather than pushed onto the Lua table from here
 * - Lua owns its own vocabulary. @date 2026-09-16 */
enum cell_kind_e : int {
    CELL_KIND_NONE = 0,
    CELL_KIND_CASE = 1,     /*!< An OpenComputers computer case. A cube, filling its cell. */
    CELL_KIND_WIRE = 2,     /*!< A redstone wire. Lives on a face, not in a cell - see below. */
    CELL_KIND_SCREEN = 3,   /*!< A screen. A cube, with a display on the face it points with. */
    CELL_KIND_KEYBOARD = 4, /*!< A keyboard. Flat, and lives on a face like a wire does. */
    CELL_KIND_LAMP = 5,     /*!< A redstone lamp. A cube, lit by a signal. */
    CELL_KIND_DRIVE = 6,    /*!< A disk drive. A cube, and it arrives with a floppy in it. */
    CELL_KIND_CABLE = 7,    /*!< An OpenComputers cable. Carries the component network. */
    CELL_KIND_CHEST = 8,    /*!< A chest. Holds items; not part of the component network. */
    CELL_KIND_TRANSPOSER = 9,  /*!< A transposer. Moves items between the inventories beside it. */
    CELL_KIND_REDSTONE = 10,   /*!< A redstone I/O block. Reads and emits a signal per side. */
    CELL_KIND_TANK = 11,       /*!< A liquid tank. Holds one fluid; read through a transposer. */
    CELL_KIND_IMPORT_BUS = 12, /*!< An ME import bus. Scenery: it has no behaviour yet. */
    CELL_KIND_EXPORT_BUS = 13, /*!< An ME export bus. Scenery: it has no behaviour yet. */
    CELL_KIND_QTANK = 14,      /*!< A quantum tank. A tank, but far bigger and not see-through. */
    CELL_KIND_SIGN = 15,       /*!< A sign. Holds a line of text, which the interface draws. */
};

/*! Does this kind sit on the component network?
 *
 * A cable joins to devices and to other cables, and to nothing else. A chest is deliberately not on
 * the list: in OpenComputers a chest is an inventory that a transposer reaches into from the side,
 * not a component the computer can see, so a cable running past one connects to nothing there.
 * @date 2026-09-17 */
inline bool kind_on_network(int kind) {
    return kind == CELL_KIND_CASE || kind == CELL_KIND_SCREEN
            || kind == CELL_KIND_DRIVE || kind == CELL_KIND_CABLE
            || kind == CELL_KIND_TRANSPOSER || kind == CELL_KIND_REDSTONE;
}

/*! Does this kind live on a face rather than filling a slot?
 *
 * Two things do: a redstone wire and a keyboard. Both are flat, both cling to the surface of
 * something else, and neither can be built upon. Everything that treats them alike - the placement
 * refusal, the breaking order, the face map they are stored in - asks this rather than listing the
 * two kinds again.
 * @date 2026-09-16 */
inline bool kind_is_flat(int kind) {
    return kind == CELL_KIND_WIRE || kind == CELL_KIND_KEYBOARD;
}

/*! Is this kind a tank of some sort? Both hold one fluid and both are read the same way by a
 * transposer; they differ in how much they hold and in whether you can see inside.
 * @date 2026-09-17 */
inline bool kind_is_tank(int kind) {
    return kind == CELL_KIND_TANK || kind == CELL_KIND_QTANK;
}

/*! Does this kind fill its whole cell?
 *
 * Everything that occupies a slot does, except a cable, which is a thin run through the middle of
 * one. The difference decides whether a neighbour may stop drawing the face they share: a face
 * hidden behind a solid cube is genuinely invisible, but a face behind a cable is mostly open air,
 * and skipping it leaves a hole straight through the block.
 *
 * A TANK IS NOT ONE EITHER. Both look like cubes and neither fills its cell: a cable is a thin run
 * through the middle, and a tank is a metal frame around a window you can see straight through.
 * Counting either as solid punches a hole in whatever stands next to it - which the cable did once
 * and the tank did the moment it existed.
 * @date 2026-09-17 */
inline bool kind_is_full_cube(int kind) {
    return kind != CELL_KIND_NONE && kind != CELL_KIND_CABLE && !kind_is_tank(kind)
            && !kind_is_flat(kind);
}



/*! What a cell is doing, which is what picks its lit textures. The values line up with the texture
 * variants OpenComputers ships - a plain face, an "On" one, an "Error" one and an "Activity" one.
 * @date 2026-09-16 */
enum cell_state_e : int {
    CELL_STATE_OFF   = 0,
    CELL_STATE_ON    = 1,
    CELL_STATE_ERROR = 2,
    CELL_STATE_BUSY  = 3,
};

/*! The six faces of a cell, ordered so that `face ^ 1` is always the opposite face and the three
 * axes come in pairs. The renderer and the ray marcher both index by this, and `facing` on a cell
 * is one of the four horizontal members. @date 2026-09-16 */
enum face_e : int {
    FACE_XNEG = 0, FACE_XPOS = 1,
    FACE_YNEG = 2, FACE_YPOS = 3,
    FACE_ZNEG = 4, FACE_ZPOS = 5,
    FACE_COUNT = 6,
};

/*! The unit vector of each face, indexed by face_e. @date 2026-09-16 */
constexpr int FACE_DIR[FACE_COUNT][3] = {
    {-1, 0, 0}, {1, 0, 0},
    {0, -1, 0}, {0, 1, 0},
    {0, 0, -1}, {0, 0, 1},
};

struct world_t;

/*! One stack of items in one slot. An empty slot is a count of zero. @date 2026-09-17 */
struct item_stack_t {
    std::string name;
    int count = 0;

    /*! Which variant of that name this is, and what the game calls it.
     *
     * A MOD'S ITEMS ARE OFTEN ONE REGISTRY NAME AND A DAMAGE VALUE. Every GregTech dust, cell and
     * pipe is `gregtech:gt.metaitem.01` with a number after it; without the number they are all
     * the same item and none of them can be told apart. OpenComputers reports it - `damage` is one
     * of the fields its ConverterItemStack puts on a stack, beside `name`, `label`, `size`,
     * `maxSize`, `maxDamage` and `hasTag` - so a program can already read it.
     *
     * The label is carried rather than looked up for the same reason the fluid's is: the component
     * that answers with it runs inside a guest machine and cannot reach the asset layer.
     * @date 2026-09-17 */
    int damage = 0;
    std::string label;
};

/*! How many slots a chest has. A single vanilla chest, which is what every program that moves items
 * already expects to find. @date 2026-09-17 */
constexpr int CHEST_SLOTS = 27;

/*! What a liquid tank holds, in litres.
 *
 * THE MOD'S OWN NUMBER. The author asked for a Super Tank IV's interface on 2026-09-17, and a
 * Super Tank IV is tier 4 of GregTech's digital tank: GT_MetaTileEntity_DigitalTankBase's
 * commonSizeCompute answers 4000000, 8000000, 16000000, 32000000 ... for tiers one upward, so tier
 * four is thirty-two million. Not 32,768,000 - the quest book rounds these to powers of two in its
 * prose and the code does not.
 *
 * Litres because that is the unit GregTech itself displays: the tank's tooltip is getCapacity()
 * followed by " L".
 * @date 2026-09-17 */
constexpr double TANK_CAPACITY_L = 32000000.0;

/*! What a quantum tank holds, in litres.
 *
 * GregTech's Quantum Tank III, which is tier 8 of the same commonSizeCompute the super tanks use:
 * 512,000,000. A scenario standing a row of them up as a fluid bank wanted exactly this, and the
 * author picked the tank to match the number rather than the other way round.
 * @date 2026-09-17 */
constexpr double QTANK_CAPACITY_L = 512000000.0;


/*! Translates an OpenComputers side number into one of this file's face indices.
 *
 * THE TWO ORDERINGS ARE NOT THE SAME and must not be confused. The mod's own sides library, which
 * every program is written against, says in as many words: negy = 0, posy = 1, negz = 2, posz = 3,
 * negx = 4, posx = 5. This file orders its faces by axis instead, so that `face ^ 1` is the
 * opposite face. Anything crossing from a component call into the world passes through here.
 *
 * Returns -1 for a side that is not one of the six.
 * @date 2026-09-17 */
inline int face_from_oc_side(int side) {
    switch (side) {
        case 0: return FACE_YNEG;
        case 1: return FACE_YPOS;
        case 2: return FACE_ZNEG;
        case 3: return FACE_ZPOS;
        case 4: return FACE_XNEG;
        case 5: return FACE_XPOS;
        default: return -1;
    }
}

/*! One block of the map - what Lua builds and drops into a slot.
 *
 * Core: a kind, a state, a facing, and where it sits. `u` is the free slot Lua keeps its own
 * bookkeeping in, exactly as `mexpr_t::u` is in math_writer, and it is the place a new per-cell
 * field goes - adding one here would mean changing C++ for a script-layer concern.
 *
 * `owner` is a raw, non-owning back-pointer to the world holding this cell, used only to bump that
 * world's version when a field changes. It is null for a cell that has been built but not yet
 * placed, and world_t::set() clears it when the cell is taken out again, so it never outlives the
 * relationship it describes.
 *
 * A cell may be held by Lua after being removed from the map. It stays a perfectly good object -
 * `placed()` simply answers false - which is what lets Lua pick a block up and put it down again.
 *
 * @date 2026-09-16 */
struct cell_t : public vc::object_t {
    int kind = CELL_KIND_NONE;
    int state = CELL_STATE_OFF;
    int facing = FACE_ZPOS;

    int x = -1, y = -1, z = -1;

    /*! Free slot for Lua's own per-cell table. Needs lua_object_t's capture()/push() to put a value
     * in, not a bare assignment - see vc::lua_object_t. @date 2026-09-16 */
    vc::ref_t<vc::lua_object_t> u;

    world_t *owner = nullptr;

    /*! What this cell is holding, for the kinds that hold anything.
     *
     * In C++ rather than in Lua's `u`, and that is the whole point: a transposer is a component
     * running inside a guest machine, and a component cannot reach a Lua table belonging to the
     * simulator's own scripts. Items are simulation state that both sides need, so they live where
     * both sides can get at them.
     * @date 2026-09-17 */
    std::vector<item_stack_t> inventory;

    /*! What a redstone block is emitting on each of its six faces, indexed by face_e.
     * @date 2026-09-17 */
    int rs_out[FACE_COUNT] = {};

    /*! What the WORLD is feeding into this cell on each face, which is a different thing from what
     * the cell emits.
     *
     * OpenComputers' Redstone I/O has both and keeps them apart: getInput answers what the blocks
     * around it are giving it, getOutput what it is giving them. Until this existed getInput
     * answered nothing at all, so a scenario had no way to TELL a program anything - every wire ran
     * one direction, out of the computer. A signal that says "the catalyst bank is full" has to
     * come the other way.
     *
     * MINUS ONE MEANS NOTHING IS WIRED THERE, which is a different thing from a wire carrying
     * nothing - and the difference is visible: a face somebody has connected shows its indicator
     * dark, a face nobody has connected shows none at all. getInput answers zero for both.
     *
     * Not saved: it is driven from whatever the scenario is measuring, and recomputed every tick.
     * @date 2026-09-18 */
    int rs_in[FACE_COUNT] = {-1, -1, -1, -1, -1, -1};

    /*! The fluid a tank holds: its internal name, such as "chlorine", and how many litres of it.
     *
     * In C++ for the same reason the inventory is - a transposer is a component inside a guest
     * machine and cannot reach a Lua table belonging to the simulator's own scripts, so anything
     * both sides need lives where both sides can get at it.
     *
     * An empty name means an empty tank. A tank with no fluid has no capacity to report either, in
     * the sense that getFluidInTank answers nothing - but the capacity itself is fixed, so it is a
     * constant rather than a field.
     * @date 2026-09-17 */
    std::string fluid;
    double fluid_amount = 0.0;

    /*! What this tank holds when full, in litres.
     *
     * PER CELL, not one constant for every tank. A tank placed by hand is a Super Tank IV, which is
     * what TANK_CAPACITY_L is; a scenario standing a row of them up as a fluid bank sets whatever
     * the thing it is standing in for holds - a Quantum Tank III, say. Not written to the save: a
     * capacity belongs to the part a tank is playing, and the scenario sets it again every time it
     * loads.
     * @date 2026-09-17 */
    double fluid_cap = TANK_CAPACITY_L;

    /*! The one fluid this tank will hold, whether or not it holds any right now.
     *
     * THE MOD'S OWN IDEA, not ours: GregTech's digital tanks have a lock, and its tooltip says so -
     * "This tank will be locked to only accept one type of fluid". It is what lets a row of tanks
     * standing in for a fluid bank say what each of them is FOR while they are empty, which a
     * contents-only model cannot: draining a tank to nothing would otherwise forget what it was.
     * @date 2026-09-17 */
    std::string fluid_lock;
    std::string fluid_lock_label;

    /*! The fluid's name as the game shows it - "Chlorine" for "chlorine".
     *
     * Carried on the cell rather than looked up when asked, because the lookup is GregTech's lang
     * file and the transposer's getFluidInTank runs inside a guest machine that has no business
     * reaching the asset layer. The script layer knows the label when it sets the fluid, so it
     * passes it in then.
     * @date 2026-09-17 */
    std::string fluid_label;

    cell_t(vc::object_t::Private priv) : vc::object_t(priv) {}

    static vc::object_type_e type_id_static() { return vc::SIM_TYPE_CELL; }
    virtual vc::object_type_e type_id() const override { return vc::SIM_TYPE_CELL; }

    static vc::ref_t<cell_t> create(int kind) {
        auto ret = std::make_shared<cell_t>(vc::object_t::Private{type_id_static()});
        ret->kind = kind;
        if (kind == CELL_KIND_QTANK)
            ret->fluid_cap = QTANK_CAPACITY_L;
        ret->u = vc::lua_object_t::create(); /* always a valid receiver for u:capture()/u:push() */
        return ret;
    }

    inline virtual std::string to_string() const override {
        return std::format("world::cell_t[{}] kind: {} state: {} at ({}, {}, {})",
                (void *)this, kind, state, x, y, z);
    }

    /*! Is this cell currently sitting in a world? @date 2026-09-16 */
    bool placed() const { return owner != nullptr; }

    /*! Where this cell sits, as a three element table; all -1 when it is not placed.
     * @date 2026-09-16 */
    std::tuple<int, int, int> pos() const { return {x, y, z}; }

    /*! Marks the owning world as changed, so the renderer rebuilds. Defined after world_t, which it
     * needs the body of. Safe on an unplaced cell, where it does nothing. @date 2026-09-16 */
    void touch();

    /*! How many slots this cell has. Zero for anything that holds nothing. @date 2026-09-17 */
    int inv_size() const { return (int)inventory.size(); }

    /*! Gives this cell an inventory of `n` slots, keeping whatever already fits. @date 2026-09-17 */
    void inv_resize(int n) {
        if (n < 0)
            n = 0;
        inventory.resize((size_t)n);
    }

    /*! One slot, counted from one, as `{name, count}`. An empty slot answers an empty name and a
     * zero, so a caller never has to guard. @date 2026-09-17 */
    std::tuple<std::string, int, int, std::string> inv_get(int slot) const {
        if (slot < 1 || slot > (int)inventory.size())
            return {std::string(), 0, 0, std::string()};
        const item_stack_t &st = inventory[(size_t)slot - 1];
        return {st.name, st.count, st.damage, st.label};
    }

    /*! Puts a stack in a slot, or empties it when the count is not positive. @date 2026-09-17 */
    bool inv_set(int slot, const char *name, int count, int damage, const char *label) {
        if (slot < 1 || slot > (int)inventory.size())
            return false;
        item_stack_t &st = inventory[(size_t)slot - 1];
        if (count <= 0 || !name || !*name) {
            st.name.clear();
            st.label.clear();
            st.count = 0;
            st.damage = 0;
        }
        else {
            st.name = name;
            st.count = count;
            st.damage = damage;
            st.label = (label && *label) ? label : name;
        }
        touch();
        return true;
    }

    /*! Sets what this cell emits on one face, clamped to what redstone can carry.
     *
     * The counterpart of rs_get, and the way anything OUTSIDE a guest machine drives a signal: a
     * scenario's controller working the world, or a test standing in for the program under test.
     * A guest does it through the redstone component's setOutput, which ends up here too.
     *
     * Lamps are not relit from here - a cell does not know its world. Whatever owns the world does
     * that, the same as it does after a component writes.
     * @date 2026-09-17 */
    void rs_set(int face, int value) {
        if (face < 0 || face >= FACE_COUNT)
            return;
        rs_out[face] = (value < 0) ? 0 : ((value > 15) ? 15 : value);
        touch();
    }

    /*! What this cell is emitting on one face. @date 2026-09-17 */
    int rs_get(int face) const {
        return (face >= 0 && face < FACE_COUNT) ? rs_out[face] : 0;
    }

    /*! Drives a signal INTO this cell on one face, the way a neighbouring block would.
     *
     * This is how a scenario answers a program rather than only listening to it. A guest reads it
     * back through the redstone component's getInput.
     * @date 2026-09-18 */
    void rs_in_set(int face, int value) {
        if (face < 0 || face >= FACE_COUNT)
            return;
        rs_in[face] = (value < 0) ? 0 : ((value > 15) ? 15 : value);
        touch();
    }

    /*! What the world is feeding into this cell on one face. An unwired face answers nothing, the
     * same as a wired one carrying nothing - that distinction is for the picture, not the program.
     * @date 2026-09-18 */
    int rs_in_get(int face) const {
        if (face < 0 || face >= FACE_COUNT || rs_in[face] < 0)
            return 0;
        return rs_in[face];
    }

    /*! Whether anything has been wired into this face at all. @date 2026-09-18 */
    bool rs_in_wired(int face) const {
        return face >= 0 && face < FACE_COUNT && rs_in[face] >= 0;
    }

    /*! What this tank holds, as `{name, litres}`. An empty tank answers an empty name and a zero.
     * @date 2026-09-17 */
    std::tuple<std::string, double, std::string> fluid_get() const {
        return {fluid, fluid_amount, fluid_label};
    }

    /*! Puts a fluid in this tank, clamped to what a tank can hold.
     *
     * A name that is empty, or an amount that is not positive, empties it - there is no such thing
     * as nought litres of chlorine, only an empty tank, which is how the mod stores it too: a
     * drained tank has a null FluidStack rather than one with a zero.
     *
     * @return the litres actually held afterwards
     * @date 2026-09-17 */
    /*! Sets what this tank holds when full, and spills nothing: an amount already over the new
     * capacity is clipped to it. @date 2026-09-17 */
    /*! Locks this tank to one fluid, or unlocks it when given nothing. @date 2026-09-17 */
    void fluid_lock_set(const char *name, const char *label) {
        if (!name || !*name) {
            fluid_lock.clear();
            fluid_lock_label.clear();
        }
        else {
            fluid_lock = name;
            fluid_lock_label = (label && *label) ? label : name;
        }
        touch();
    }

    /*! What this tank is locked to, as `{name, label}`; empty names when it is not locked.
     * @date 2026-09-17 */
    std::tuple<std::string, std::string> fluid_lock_get() const {
        return {fluid_lock, fluid_lock_label};
    }

    void fluid_set_capacity(double litres) {
        fluid_cap = (litres > 0.0) ? litres : TANK_CAPACITY_L;
        if (fluid_amount > fluid_cap)
            fluid_amount = fluid_cap;
        touch();
    }

    double fluid_set(const char *name, double litres, const char *label) {
        if (!name || !*name || litres <= 0.0) {
            fluid.clear();
            fluid_label.clear();
            fluid_amount = 0.0;
        }
        else {
            fluid = name;
            fluid_label = (label && *label) ? label : name;
            fluid_amount = (litres > fluid_cap) ? fluid_cap : litres;
        }
        touch();
        return fluid_amount;
    }

    /*! What a tank can hold, in litres. A cell that is not a tank holds nothing.
     * @date 2026-09-17 */
    double fluid_capacity() const {
        return kind_is_tank(kind) ? fluid_cap : 0.0;
    }
};

using cell_p = vc::ref_t<cell_t>;

/*! The map: a fixed WORLD_X by WORLD_Y by WORLD_Z matrix of cell references, plus the version
 * counter everything downstream watches.
 *
 * Core: a slot holds either a cell or nothing. There is no air block and no default cell - an empty
 * slot is a null reference, which keeps an empty world genuinely empty rather than a hundred and
 * thirty thousand objects nobody asked for.
 *
 * `version` is the contract, the same way `container.version` is in math_writer: it moves on every
 * change that alters what should be drawn - a cell placed, a cell removed, a field written through
 * one of the registered setters - and on nothing else. The renderer keeps the version its mesh was
 * built from and rebuilds when the two differ.
 *
 * The matrix is flat and indexed x-major, then y, then z. Nothing outside this struct computes that
 * index; `idx()` is the one definition.
 *
 * @date 2026-09-16 */
struct world_t : public vc::object_t {
    std::vector<cell_p> cells;

    /*! Wires, keyed by the face they cling to rather than by a cell.
     *
     * A redstone wire is not a cube and does not fill a slot: it lies flat on the surface of
     * something else, and what identifies it is a face - a cell together with one of its six
     * sides. The author's framing, 2026-09-16: "the faces on which redstone is placed can connect
     * to other adjacent faces", and "you can't place blocks on a redstone face". That second rule
     * is the one that settles the model. If a wire owned a cell, refusing to build there would be
     * automatic and would not be worth stating; it is worth stating precisely because the cell in
     * front of a wired face is otherwise empty and would happily take a block.
     *
     * The floor is included. Its faces live at y = -1 pointing up, which is the same coordinate
     * raycast() already reports a ground hit at, so a wire on the ground needs no special case
     * anywhere - not in aiming, not in placing, not in drawing.
     *
     * A wire is still a cell_t. It keeps its `u` table, its state and its kind, so everything
     * written for cells - the reacting setters, the Lua bookkeeping - works on a wire unchanged.
     * Only where it is stored differs.
     * @date 2026-09-16 */
    std::unordered_map<uint32_t, cell_p> faces;

    uint64_t version = 1;

    /*! How many times a block has been PLACED OR BROKEN, which is a different question from
     * `version`.
     *
     * Core: `version` moves whenever anything at all changes, a tank's contents included, and that
     * is right for the renderer - the mesh has to be rebuilt when a fluid level moves. It is quite
     * wrong for anything asking "has the wiring changed?": a scenario pumping liquid bumps it
     * thousands of times a second while the map stands perfectly still.
     *
     * Stepping the computers once per world tick made that expensive enough to look like a hang -
     * every machine re-scanned the world for its components on every substep, four hundred times a
     * frame. Hot swapping only has to notice blocks coming and going, so this counts only those.
     * @date 2026-09-18 */
    uint64_t topo_version = 1;

    int placed_count = 0;
    int face_count = 0;

    world_t(vc::object_t::Private priv) : vc::object_t(priv) {
        cells.resize((size_t)WORLD_X * WORLD_Y * WORLD_Z);
    }

    static vc::object_type_e type_id_static() { return vc::SIM_TYPE_WORLD; }
    virtual vc::object_type_e type_id() const override { return vc::SIM_TYPE_WORLD; }

    static vc::ref_t<world_t> create() {
        return std::make_shared<world_t>(vc::object_t::Private{type_id_static()});
    }

    inline virtual std::string to_string() const override {
        return std::format("world::world_t[{}] {}x{}x{} holding {} cells, version {}",
                (void *)this, WORLD_X, WORLD_Y, WORLD_Z, placed_count, version);
    }

    /*! The flat index of a cell coordinate. Callers check in_bounds() first; this does not.
     * @date 2026-09-16 */
    static size_t idx(int x, int y, int z) {
        return ((size_t)z * WORLD_Y + (size_t)y) * WORLD_X + (size_t)x;
    }

    /*! Is this coordinate inside the map? @date 2026-09-16 */
    static bool in_bounds(int x, int y, int z) {
        return x >= 0 && y >= 0 && z >= 0 && x < WORLD_X && y < WORLD_Y && z < WORLD_Z;
    }

    /*! The map's extent, as a three element table. Read from Lua rather than hard-coded there, so
     * the size lives in exactly one place. @date 2026-09-16 */
    std::tuple<int, int, int> size() const { return {WORLD_X, WORLD_Y, WORLD_Z}; }

    /*! How many cells are currently placed. @date 2026-09-16 */
    int count() const { return placed_count; }

    /*! The version the last change left behind. @date 2026-09-16 */
    double get_version() const { return (double)version; }

    /*! How many times a block has been placed or broken. See `topo_version`. @date 2026-09-18 */
    double get_topology_version() const { return (double)topo_version; }

    /*! Declares the world changed. Lua needs this only when it has changed something the registered
     * setters cannot see; ordinary placement and field writes bump the version themselves.
     * @date 2026-09-16 */
    void touch() { version++; }

    /*! The cell at a coordinate, or nil for an empty slot or a coordinate outside the map.
     *
     * Out of bounds is not an error: the ray marcher and the mesher both ask about neighbours that
     * may be off the edge, and "nothing there" is the useful answer in both cases.
     * @date 2026-09-16 */
    cell_p get(int x, int y, int z) const {
        if (!in_bounds(x, y, z))
            return nullptr;
        return cells[idx(x, y, z)];
    }

    /*! Puts `cell` at a coordinate, or empties the slot when `cell` is nil.
     *
     * Whatever was in the slot is detached first - its owner cleared and its position reset - so a
     * cell Lua is still holding does not go on claiming to live at an address something else now
     * occupies. A cell already placed elsewhere is moved rather than duplicated, for the same
     * reason: one cell is in at most one slot.
     *
     * Returns false for a coordinate outside the map, leaving the world untouched.
     * @date 2026-09-16 */
    bool set(int x, int y, int z, cell_p cell) {
        if (!in_bounds(x, y, z))
            return false;

        cell_p &slot = cells[idx(x, y, z)];
        if (slot == cell)
            return true;

        if (slot) {
            slot->owner = nullptr;
            slot->x = slot->y = slot->z = -1;
            placed_count--;
        }

        if (cell) {
            /* Moving rather than copying: a cell that is already somewhere leaves that slot. */
            if (cell->owner == this && in_bounds(cell->x, cell->y, cell->z)) {
                cells[idx(cell->x, cell->y, cell->z)] = nullptr;
                placed_count--;
            }
            cell->owner = this;
            cell->x = x; cell->y = y; cell->z = z;
            placed_count++;
        }

        slot = cell;
        version++;
        topo_version++;
        return true;
    }

    /*! Empties the slot at a coordinate. Returns true when something was actually removed.
     * @date 2026-09-16 */
    bool clear(int x, int y, int z) {
        if (!in_bounds(x, y, z) || !cells[idx(x, y, z)])
            return false;
        set(x, y, z, nullptr);
        return true;
    }

    /* --- faces, and the wires on them ------------------------------------------------------ */

    /*! The lowest y a face may sit at. The floor's upward faces live one layer below the map, which
     * is where raycast() already reports a ground hit, so -1 is a real coordinate for a face even
     * though no cell can ever exist there. @date 2026-09-16 */
    static constexpr int FACE_Y_MIN = -1;

    /*! Is this a face the map can talk about at all? @date 2026-09-16 */
    static bool face_in_bounds(int x, int y, int z, int face) {
        return x >= 0 && z >= 0 && x < WORLD_X && z < WORLD_Z
                && y >= FACE_Y_MIN && y < WORLD_Y
                && face >= 0 && face < FACE_COUNT;
    }

    /*! One key for one face. Packs the coordinate and the side into a single integer, which is what
     * the wire map is keyed on. The y is biased by one so the floor layer at -1 packs without a
     * sign. @date 2026-09-16 */
    static uint32_t face_key(int x, int y, int z, int face) {
        uint32_t yy = (uint32_t)(y - FACE_Y_MIN);
        return ((((yy * (uint32_t)WORLD_Z) + (uint32_t)z) * (uint32_t)WORLD_X)
                + (uint32_t)x) * (uint32_t)FACE_COUNT + (uint32_t)face;
    }

    /*! Unpacks a key back into a coordinate and a side - what a save walk needs, since the map is
     * keyed by the packed form.
     *
     * A plain member rather than a static one so Lua can reach it: VC_REGISTER_MEMBER_FUNCTION
     * binds through a pointer-to-member and has nothing to bind a static to. It reads no state.
     * @date 2026-09-16 */
    std::tuple<int, int, int, int> face_unkey(double packed) const {
        uint32_t k = (uint32_t)packed;
        int face = (int)(k % (uint32_t)FACE_COUNT);  k /= (uint32_t)FACE_COUNT;
        int x = (int)(k % (uint32_t)WORLD_X);        k /= (uint32_t)WORLD_X;
        int z = (int)(k % (uint32_t)WORLD_Z);        k /= (uint32_t)WORLD_Z;
        return {x, (int)k + FACE_Y_MIN, z, face};
    }

    /*! Is this face exposed - that is, is the cell on its outer side empty?
     *
     * A wire needs somewhere to be. Two cubes stacked against each other leave no room between
     * them, and a face buried like that cannot carry anything. The cell the face belongs to must
     * itself be solid, or else be the floor.
     * @date 2026-09-16 */
    bool face_exposed(int x, int y, int z, int face) const {
        if (!face_in_bounds(x, y, z, face))
            return false;

        /* The floor: only its upward faces are surfaces, and only while nothing stands on them. */
        if (y == FACE_Y_MIN)
            return face == FACE_YPOS && !get(x, 0, z);

        if (!get(x, y, z))
            return false;

        /* The underside of a block resting on the floor is against the floor, not against open air.
        The bounds test below cannot see that on its own - it only knows y = -1 is not a cell - so
        the floor has to be excluded here or every block would offer a hidden face beneath it. */
        if (face == FACE_YNEG && y == 0)
            return false;

        int nx = x + FACE_DIR[face][0];
        int ny = y + FACE_DIR[face][1];
        int nz = z + FACE_DIR[face][2];
        /* Off the edge of the map counts as empty - the sides and the top of the world are open
        air, and a surface there is as real as any other. */
        return !in_bounds(nx, ny, nz) || !cells[idx(nx, ny, nz)];
    }

    /*! The wire on a face, or nil. @date 2026-09-16 */
    cell_p face_get(int x, int y, int z, int face) const {
        if (!face_in_bounds(x, y, z, face))
            return nullptr;
        auto it = faces.find(face_key(x, y, z, face));
        return it == faces.end() ? nullptr : it->second;
    }

    /*! Puts a wire on a face, or clears it when `cell` is nil.
     *
     * Refuses a face that is not exposed, and refuses to cover one that already carries something.
     * Returns false in both cases, leaving the world untouched.
     * @date 2026-09-16 */
    bool face_set(int x, int y, int z, int face, cell_p cell) {
        if (!face_in_bounds(x, y, z, face))
            return false;

        uint32_t key = face_key(x, y, z, face);
        auto it = faces.find(key);

        if (!cell) {
            if (it == faces.end())
                return false;
            it->second->owner = nullptr;
            it->second->x = it->second->y = it->second->z = -1;
            faces.erase(it);
            face_count--;
            version++;
            topo_version++;
            return true;
        }

        if (it != faces.end() || !face_exposed(x, y, z, face))
            return false;

        cell->owner = this;
        cell->x = x; cell->y = y; cell->z = z;
        cell->facing = face;        /* a wire's facing is the side it lies on */
        faces[key] = cell;
        face_count++;
        version++;
        topo_version++;
        return true;
    }

    /*! Takes the wire off a face. Returns true when one was there. @date 2026-09-16 */
    bool face_clear(int x, int y, int z, int face) {
        return face_set(x, y, z, face, nullptr);
    }

    /*! How many wires are placed. @date 2026-09-16 */
    int face_total() const { return face_count; }

    /*! Every wire, as a flat list of key and cell pairs - what Lua walks to write a save.
     *
     * The key is handed back rather than the coordinate because it is one number instead of four;
     * face_unkey() turns it back into a coordinate and a side on the way in.
     * @date 2026-09-16 */
    std::vector<std::tuple<double, cell_p>> occupied_faces() const {
        std::vector<std::tuple<double, cell_p>> out;
        out.reserve(faces.size());
        for (const auto &kv : faces)
            out.push_back({(double)kv.first, kv.second});
        return out;
    }

    /*! The wire on a face - the attachment there, but only if it is actually a wire.
     *
     * Face storage holds every flat thing, wires and keyboards alike, and a keyboard is not part of
     * a circuit. Linking asks through this so a keyboard bolted beside a wire run does not silently
     * become a conductor.
     * @date 2026-09-16 */
    cell_p wire_at(int x, int y, int z, int face) const {
        cell_p c = face_get(x, y, z, face);
        return (c && c->kind == CELL_KIND_WIRE) ? c : nullptr;
    }

    /*! Which of a face's four in-plane directions carry a wire that this one joins up with.
     *
     * Core: two wired faces connect when the faces themselves touch along an edge, which happens in
     * exactly three ways, and this checks all three for each of the four directions:
     *
     *   - flat, along the same surface: the neighbouring cell, same side;
     *   - over a convex edge, a wire running off a ledge and down: the same cell, the side the
     *     direction of travel points at;
     *   - into a concave corner, a wire running up a wall: the cell diagonally across that corner,
     *     on the side facing back.
     *
     * Flat is tested first, so a wire on an open floor beside a wall runs along the floor rather
     * than climbing it.
     *
     * The four directions are the two in-plane axes, each way: bits 0 and 1 are the first axis
     * forwards and back, bits 2 and 3 the second. Which axes those are follows from the face - they
     * are the two that are not its own - and render_composer.h builds its arms from the same rule,
     * so a bit and the arm drawn for it always mean the same direction.
     *
     * Params: a face, which need not carry a wire itself; the answer describes what it would join.
     * Returns a four-bit mask.
     * @date 2026-09-16 */
    int face_links(int x, int y, int z, int face) const {
        if (!face_in_bounds(x, y, z, face))
            return 0;

        int axis = face / 2;
        const int axes[2] = {(axis + 1) % 3, (axis + 2) % 3};

        int mask = 0;
        for (int i = 0; i < 2; i++)
            for (int sign = 0; sign < 2; sign++) {
                int p[3] = {0, 0, 0};
                p[axes[i]] = sign ? -1 : 1;
                int bit = i * 2 + sign;

                /* Flat: straight on along the same surface. */
                if (wire_at(x + p[0], y + p[1], z + p[2], face)) {
                    mask |= 1 << bit;
                    continue;
                }

                int toward = -1;
                for (int f = 0; f < FACE_COUNT; f++)
                    if (FACE_DIR[f][0] == p[0] && FACE_DIR[f][1] == p[1] && FACE_DIR[f][2] == p[2])
                        toward = f;
                if (toward < 0)
                    continue;

                /* Convex: over the edge of this same cell, onto the side we head towards. */
                if (wire_at(x, y, z, toward)) {
                    mask |= 1 << bit;
                    continue;
                }

                /* Concave: up the wall standing across the corner, on the side looking back. */
                int cx = x + FACE_DIR[face][0] + p[0];
                int cy = y + FACE_DIR[face][1] + p[1];
                int cz = z + FACE_DIR[face][2] + p[2];
                if (wire_at(cx, cy, cz, toward ^ 1))
                    mask |= 1 << bit;
            }
        return mask;
    }

    /*! Which of a cable's six sides join onto something, as a six bit mask indexed by face_e.
     *
     * A cable joins to another cable or to a device. What it does NOT do is join to thin air, which
     * is why a lone cable draws as a stub rather than a cross - the shape is the wiring, and a
     * length of cable that looks connected but is not would be a lie about the network.
     *
     * @date 2026-09-17 */
    int cable_links(int x, int y, int z) const {
        int mask = 0;
        for (int f = 0; f < FACE_COUNT; f++) {
            cell_p n = get(x + FACE_DIR[f][0], y + FACE_DIR[f][1], z + FACE_DIR[f][2]);
            if (n && kind_on_network(n->kind))
                mask |= 1 << f;
        }
        return mask;
    }

    /*! Every placed cell, in index order - what Lua walks to write a save file.
     *
     * Each cell knows its own coordinate, so the list carries everything a save needs without a
     * parallel list of positions.
     * @date 2026-09-16 */
    std::vector<cell_p> occupied() const {
        std::vector<cell_p> out;
        out.reserve((size_t)placed_count);
        for (const cell_p &c : cells)
            if (c)
                out.push_back(c);
        return out;
    }

    /*! Empties the whole map in one step. @date 2026-09-16 */
    void wipe() {
        for (cell_p &c : cells)
            if (c) {
                c->owner = nullptr;
                c->x = c->y = c->z = -1;
                c = nullptr;
            }
        for (auto &kv : faces)
            if (kv.second) {
                kv.second->owner = nullptr;
                kv.second->x = kv.second->y = kv.second->z = -1;
            }
        faces.clear();
        placed_count = 0;
        face_count = 0;
        version++;
        topo_version++;
    }

    /*! Marches a ray through the map and reports the first thing it meets.
     *
     * Core: a voxel traversal in the Amanatides and Woo sense - step to whichever axis boundary is
     * nearest, one cell at a time, so no cell along the line is skipped and the face the ray
     * entered through falls out of which axis was stepped. That face is the normal reported, which
     * is what makes "place against the side I clicked" work without any further geometry.
     *
     * The ground plane is part of what can be hit. When no cell is struck, the ray is intersected
     * with the plane y = 0, and a hit there is reported at y = -1 with a +Y normal. The -1 is
     * deliberate: it means a caller places at `hit + normal` for the ground exactly as it does for
     * a cell face, with no special case at the call site.
     *
     * Params: the ray origin and direction in world units, where cell (i, j, k) spans the unit cube
     * from (i, j, k) to (i+1, j+1, k+1), and `max_dist` in the same units.
     * Returns nine values as a table: whether anything was hit, the cell coordinate, the face
     * normal, whether the thing hit was the ground rather than a cell, and how far along the ray
     * the surface is. That last one is what lets a caller work out the exact point the ray struck -
     * `origin + direction * distance` - which the cell coordinate alone cannot give, since a cell
     * is a whole cubic metre and the hit is one point on one of its faces.
     * @date 2026-09-16 */
    std::tuple<bool, int, int, int, int, int, int, bool, double> raycast(
            double ox, double oy, double oz, double dx, double dy, double dz, double max_dist) const
    {
        auto miss = std::make_tuple(false, 0, 0, 0, 0, 0, 0, false, 0.0);

        double len = std::sqrt(dx * dx + dy * dy + dz * dz);
        if (len < 1e-9 || max_dist <= 0)
            return miss;
        dx /= len; dy /= len; dz /= len;
        /* Normalised, so every `t` below is a distance in world units rather than a multiple of
        whatever length the caller's direction happened to have. That is what makes the returned
        distance usable directly as `origin + direction * t`. */

        int cx = (int)std::floor(ox);
        int cy = (int)std::floor(oy);
        int cz = (int)std::floor(oz);

        int step_x = dx > 0 ? 1 : -1;
        int step_y = dy > 0 ? 1 : -1;
        int step_z = dz > 0 ? 1 : -1;

        /* How far along the ray a full cell of travel is on each axis, and how far to the first
        boundary. An axis the ray does not move along gets an infinite delta, so it never wins the
        comparison below and never steps. */
        const double huge = 1e30;
        double t_delta_x = std::fabs(dx) < 1e-12 ? huge : std::fabs(1.0 / dx);
        double t_delta_y = std::fabs(dy) < 1e-12 ? huge : std::fabs(1.0 / dy);
        double t_delta_z = std::fabs(dz) < 1e-12 ? huge : std::fabs(1.0 / dz);

        double next_x = dx > 0 ? (cx + 1 - ox) : (ox - cx);
        double next_y = dy > 0 ? (cy + 1 - oy) : (oy - cy);
        double next_z = dz > 0 ? (cz + 1 - oz) : (oz - cz);

        double t_max_x = t_delta_x == huge ? huge : next_x * t_delta_x;
        double t_max_y = t_delta_y == huge ? huge : next_y * t_delta_y;
        double t_max_z = t_delta_z == huge ? huge : next_z * t_delta_z;

        int face = -1;
        double t = 0;

        /* The starting cell is tested before any step, so a ray that begins inside a block
        hits it. */
        if (in_bounds(cx, cy, cz) && cells[idx(cx, cy, cz)])
            return {true, cx, cy, cz, 0, 1, 0, false, 0.0};

        while (t <= max_dist) {
            if (t_max_x <= t_max_y && t_max_x <= t_max_z) {
                cx += step_x;
                t = t_max_x;
                t_max_x += t_delta_x;
                face = step_x > 0 ? FACE_XNEG : FACE_XPOS;
            }
            else if (t_max_y <= t_max_z) {
                cy += step_y;
                t = t_max_y;
                t_max_y += t_delta_y;
                face = step_y > 0 ? FACE_YNEG : FACE_YPOS;
            }
            else {
                cz += step_z;
                t = t_max_z;
                t_max_z += t_delta_z;
                face = step_z > 0 ? FACE_ZNEG : FACE_ZPOS;
            }

            if (t > max_dist)
                break;

            /* Above the map or beside it the ray keeps going - it may yet come down into the
            world - but once it is below the floor and still descending there is nothing left. */
            if (cy < 0 && step_y < 0)
                break;
            if (cy >= WORLD_Y && step_y > 0)
                break;
            if ((cx < 0 && step_x < 0) || (cx >= WORLD_X && step_x > 0))
                break;
            if ((cz < 0 && step_z < 0) || (cz >= WORLD_Z && step_z > 0))
                break;

            if (in_bounds(cx, cy, cz) && cells[idx(cx, cy, cz)])
                return {true, cx, cy, cz,
                        FACE_DIR[face][0], FACE_DIR[face][1], FACE_DIR[face][2], false, t};
        }

        /* Nothing solid: fall through to the ground plane, so the first block of an empty world has
        somewhere to go. */
        if (dy < -1e-9) {
            double tg = -oy / dy;
            if (tg >= 0 && tg <= max_dist) {
                int gx = (int)std::floor(ox + dx * tg);
                int gz = (int)std::floor(oz + dz * tg);
                if (gx >= 0 && gz >= 0 && gx < WORLD_X && gz < WORLD_Z)
                    return {true, gx, -1, gz, 0, 1, 0, true, tg};
            }
        }
        return miss;
    }
};

inline void cell_t::touch() {
    if (owner)
        owner->version++;
}

/* --- the Lua boundary ---------------------------------------------------------------------- */

/*! Builds a cell of `kind`, belonging to nobody until something places it. @date 2026-09-16 */
inline cell_p cell_create(int kind) {
    return cell_t::create(kind);
}

/*! Builds an empty world. @date 2026-09-16 */
inline vc::ref_t<world_t> world_create() {
    return world_t::create();
}

/*! The setter behind `cell.kind`, `cell.state` and `cell.facing`.
 *
 * Core: it does what the stock member setter does and then calls touch(), so a write from Lua is
 * what makes the cell react - the world's version moves and the renderer rebuilds around it. That
 * one extra line is the whole reason these three fields are not registered with
 * VC_REGISTER_MEMBER_OBJECT, which installs a setter that writes the field and tells nobody.
 *
 * The stack layout is the one Lua gives a __newindex: the object, the key, then the value.
 * @date 2026-09-16 */
template <auto member_ptr>
inline int cell_member_setter(lua_State *L) {
    auto o = vc::get_object_from_lua(L, -3);
    if (!o) {
        vc::luaw_push_error(L, "cell: assignment to something that is not a cell");
        return 0;
    }
    auto cell = o->to_related<cell_t>();
    auto &member = cell.get()->*member_ptr;

    if (vc::luaw_lua_to_cpp_object(L, -1, member) < 0) {
        vc::luaw_push_error(L, "cell: cannot convert the assigned value");
        return 0;
    }
    cell->touch();
    return 0;
}

/*! Registers one cell field readable and writable from Lua, with the touching setter above.
 * @date 2026-09-16 */
template <auto member_ptr>
inline void register_cell_field(vc::virt_state_t *vs, const char *name) {
    vc::set_lua_class_member(vs, cell_t::type_id_static(), name,
            &vc::luaw_member_object_wrapper<cell_t, member_ptr>, vc::LUAW_MEMBER_OBJECT);
    vc::set_class_member_setter(vs, cell_t::type_id_static(), name,
            &worldc::cell_member_setter<member_ptr>);
}

/*! Puts cell_t and world_t on the vc table, as `cell_create` and `world_create` plus the members of
 * each. Named with a prefix rather than nested, the way every other composer here does.
 * @date 2026-09-16 */
inline int register_meta(vc::virt_state_t *vs) {
    DBG_SCOPE();

    /* `u` takes the stock setter: it is Lua's own scratch table and writing it changes nothing the
    renderer can see, so there is nothing to invalidate. */
    VC_REGISTER_MEMBER_OBJECT(vs, cell_t, u);

    worldc::register_cell_field<&cell_t::kind>(vs, "kind");
    worldc::register_cell_field<&cell_t::state>(vs, "state");
    worldc::register_cell_field<&cell_t::facing>(vs, "facing");

    VC_REGISTER_MEMBER_FUNCTION(vs, cell_t, pos);
    VC_REGISTER_MEMBER_FUNCTION(vs, cell_t, placed);
    VC_REGISTER_MEMBER_FUNCTION(vs, cell_t, touch);
    VC_REGISTER_MEMBER_FUNCTION(vs, cell_t, fluid_get);
    VC_REGISTER_MEMBER_FUNCTION(vs, cell_t, fluid_set, const char *, double,
            const char *);
    VC_REGISTER_MEMBER_FUNCTION(vs, cell_t, fluid_capacity);
    VC_REGISTER_MEMBER_FUNCTION(vs, cell_t, fluid_set_capacity, double);
    VC_REGISTER_MEMBER_FUNCTION(vs, cell_t, fluid_lock_set, const char *,
            const char *);
    VC_REGISTER_MEMBER_FUNCTION(vs, cell_t, fluid_lock_get);
    VC_REGISTER_MEMBER_FUNCTION(vs, cell_t, inv_size);
    VC_REGISTER_MEMBER_FUNCTION(vs, cell_t, inv_resize, int);
    VC_REGISTER_MEMBER_FUNCTION(vs, cell_t, inv_get, int);
    VC_REGISTER_MEMBER_FUNCTION(vs, cell_t, inv_set, int, const char *, int, int,
            const char *);
    VC_REGISTER_MEMBER_FUNCTION(vs, cell_t, rs_get, int);
    VC_REGISTER_MEMBER_FUNCTION(vs, cell_t, rs_set, int, int);
    VC_REGISTER_MEMBER_FUNCTION(vs, cell_t, rs_in_get, int);
    VC_REGISTER_MEMBER_FUNCTION(vs, cell_t, rs_in_wired, int);
    VC_REGISTER_MEMBER_FUNCTION(vs, cell_t, rs_in_set, int, int);

    VC_REGISTER_MEMBER_FUNCTION(vs, world_t, get, int, int, int);
    VC_REGISTER_MEMBER_FUNCTION(vs, world_t, set, int, int, int, cell_p);
    VC_REGISTER_MEMBER_FUNCTION(vs, world_t, clear, int, int, int);
    VC_REGISTER_MEMBER_FUNCTION(vs, world_t, size);
    VC_REGISTER_MEMBER_FUNCTION(vs, world_t, count);
    VC_REGISTER_MEMBER_FUNCTION(vs, world_t, get_version);
    VC_REGISTER_MEMBER_FUNCTION(vs, world_t, get_topology_version);
    VC_REGISTER_MEMBER_FUNCTION(vs, world_t, touch);
    VC_REGISTER_MEMBER_FUNCTION(vs, world_t, occupied);
    VC_REGISTER_MEMBER_FUNCTION(vs, world_t, face_get, int, int, int, int);
    VC_REGISTER_MEMBER_FUNCTION(vs, world_t, wire_at, int, int, int, int);
    VC_REGISTER_MEMBER_FUNCTION(vs, world_t, cable_links, int, int, int);
    VC_REGISTER_MEMBER_FUNCTION(vs, world_t, face_set, int, int, int, int, cell_p);
    VC_REGISTER_MEMBER_FUNCTION(vs, world_t, face_clear, int, int, int, int);
    VC_REGISTER_MEMBER_FUNCTION(vs, world_t, face_exposed, int, int, int, int);
    VC_REGISTER_MEMBER_FUNCTION(vs, world_t, face_links, int, int, int, int);
    VC_REGISTER_MEMBER_FUNCTION(vs, world_t, face_unkey, double);
    VC_REGISTER_MEMBER_FUNCTION(vs, world_t, face_total);
    VC_REGISTER_MEMBER_FUNCTION(vs, world_t, occupied_faces);
    VC_REGISTER_MEMBER_FUNCTION(vs, world_t, wipe);
    VC_REGISTER_MEMBER_FUNCTION(vs, world_t, raycast,
            double, double, double, double, double, double, double);

    std::vector<luaL_Reg> world_tab_funcs = {
        {"cell_create", vc::luaw_function_wrapper<
               /* FN:    */ worldc::cell_create,
               /* PARAMS:*/ int
        >},
        {"world_create", vc::luaw_function_wrapper<
               /* FN:    */ worldc::world_create
        >},
    };

    ASSERT_FN(add_lua_tab_funcs(vs, world_tab_funcs));

    return vc::VC_ERROR_OK;
}

} /* namespace world_composer */

#endif /* WORLD_COMPOSER_H */
