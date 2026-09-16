#ifndef MACHINE_COMPOSER_H
#define MACHINE_COMPOSER_H

/*! machine_composer.h - one simulated OpenComputers computer: its own Lua state, its components,
 * and the loop that drives it.
 *
 * Core: a machine runs the mod's own `machine.lua` inside a Lua state of its own, and this file is
 * the host that state talks to. That host surface is small and completely specified by machine.lua
 * itself - six `component` functions, seventeen on `computer`, ten on `unicode` and three on
 * `system` - and everything above it, the sandbox, the BIOS and eventually OpenOS, is the mod's Lua
 * running unmodified.
 *
 * THE GUEST GETS A RAW LUA STATE, NOT A VIRT_COMPOSER ONE. virt_composer is the simulator's own
 * scripting layer, and the guest is untrusted code being emulated; letting it see `vc` would hand a
 * simulated computer the keys to the simulator. The two never meet: the guest's state is built with
 * luaL_newstate here, its host functions are plain lua_CFunctions, and the only path between the
 * two worlds is this file's own interface.
 *
 * THE YIELD PROTOCOL is the whole of the contract. machine.lua runs as a coroutine and the first
 * value it yields says what it wants:
 *
 *   nothing    a user coroutine yielded; resume it and carry on
 *   a number   seconds to wait, from computer.pullSignal; resume with a signal or with nothing
 *   a function an indirect component call; call it, resume with what it returns
 *   a boolean  shut down, or reboot when true
 *
 * A signal queue backs the third of those. It is a deque and a deadline and nothing more: the pool
 * is cooperative and single threaded, so "wait until a signal arrives" is a question the host can
 * answer by looking, and needs no synchronisation primitive at all.
 *
 * @date 2026-09-16 */

#include "virt_composer.h"
#include "mc_assets.h"
#include "oc_filesystem.h"
#include "oc_rom.h"
#include "oc_screen.h"
#include "world_composer.h"

#include <chrono>
#include <cstring>
#include <deque>
#include <string>
#include <unordered_map>
#include <vector>

namespace virt_composer {

VIRT_COMPOSER_REGISTER_TYPE(SIM_TYPE_MACHINE);

} /* namespace virt_composer */

namespace machine_composer {

namespace vc = virt_composer;
namespace mca = mc_assets;
namespace ocfs = oc_filesystem;
namespace ocsc = oc_screen;
namespace worldc = world_composer;
namespace machc = machine_composer;

struct machine_t;

/*! Seconds on a monotonic clock, read live every time it is asked.
 *
 * It has to be live. machine.lua opens by busy-looping until `computer.realTime()` moves, to
 * measure how many Lua instructions a slice of time buys, and a clock sampled once per frame never
 * moves inside that loop - the first machine ever started simply hangs. This was exactly that bug.
 *
 * Monotonic rather than wall clock, because the only questions asked of it are differences.
 * @date 2026-09-16 */
inline double host_clock() {
    using clock = std::chrono::steady_clock;
    static const clock::time_point origin = clock::now();
    return std::chrono::duration<double>(clock::now() - origin).count();
}

/*! What a machine is doing. Reported to Lua, and what drives a case's lit textures.
 * @date 2026-09-16 */
enum machine_state_e : int {
    MACHINE_OFF = 0,
    MACHINE_RUNNING = 1,
    MACHINE_ERROR = 2,
    MACHINE_BUSY = 3,
};

/*! One value in a signal. A signal is a name and a list of these, which is what
 * `computer.pushSignal` takes and `computer.pullSignal` gives back.
 *
 * Only the three types OpenComputers actually passes around are carried. Anything else a caller
 * tries to push is dropped rather than approximated, so a signal never arrives subtly wrong.
 * @date 2026-09-16 */
struct sig_val_t {
    enum kind_e { NIL, BOOL, NUM, STR } kind = NIL;
    bool b = false;
    double n = 0;
    std::string s;
};

struct signal_t {
    std::string name;
    std::vector<sig_val_t> args;
};

/*! One method on one component: what it does, and whether it may be called inline.
 *
 * `direct` is not decoration. machine.lua asks `component.methods` for it and routes the call
 * differently: a direct method runs inside the guest's own resume, an indirect one is bounced out
 * to the host as a yielded closure and answered on the next tick. Everything here is direct, since
 * nothing yet needs to cost the guest a tick.
 * @date 2026-09-16 */
struct method_t {
    bool direct = true;
    /* Pushes its results onto `L` and answers how many. */
    int (*fn)(machine_t &m, struct component_t &c, lua_State *L) = nullptr;
    const char *doc = nullptr;
};

/*! One component attached to a machine.
 *
 * Core: an address, a type, and a table of methods. The fields below it are the storage the
 * built-in kinds need - an EEPROM's code and boot address today, a filesystem's tree tomorrow -
 * kept on the component rather than in a parallel structure so a component is one object.
 *
 * @date 2026-09-16 */
struct component_t {
    std::string address;
    std::string type;
    int slot = -1;

    std::unordered_map<std::string, method_t> methods;

    /* EEPROM storage: `code` is what `get` answers and `data` what `getData` answers. The BIOS
    keeps the boot filesystem's address in `data`, which is why it survives a reboot. */
    std::string code;
    std::string data;
    std::string label;

    /*! A filesystem component's storage. Shared rather than owned, because a hard disk outlives the
     * machine's Lua state: rebooting rebuilds every component but must not wipe the disk.
     * @date 2026-09-16 */
    std::shared_ptr<ocfs::filesystem_t> fs;

    /*! A screen's character grid, shared with whichever gpu is bound to it.
     *
     * A gpu writes into the screen it is bound to rather than into one of its own, so the buffer
     * belongs to the screen and both components point at the same one.
     * @date 2026-09-17 */
    std::shared_ptr<ocsc::buffer_t> screen;

    /*! A redstone block's emitted level per side, indexed by face. Kept on the component because
     * that is what `setOutput` writes and `getOutput` reads. @date 2026-09-17 */
    int rs_output[6] = {};

    /*! What a gpu is bound to, and what a keyboard is attached to - an address either way, empty
     * when nothing. @date 2026-09-17 */
    std::string bound_to;
};

/*! Builds an address that looks like the ones OpenComputers uses.
 *
 * A machine's programs compare addresses and take prefixes of them - this repo's own
 * `hw_interface.lua` does `component.get("6861")` - so they have to look like UUIDs and they have
 * to be stable for as long as the thing they name exists. The counter makes them unique within a
 * run; persistence across runs is the world file's business, not this function's.
 * @date 2026-09-16 */
inline std::string make_address(uint64_t seed) {
    static const char *hex = "0123456789abcdef";
    uint64_t s = seed * 6364136223846793005ull + 1442695040888963407ull;
    std::string out;
    out.reserve(36);
    for (int i = 0; i < 32; i++) {
        if (i == 8 || i == 12 || i == 16 || i == 20)
            out.push_back('-');
        s ^= s << 13; s ^= s >> 7; s ^= s << 17;
        out.push_back(hex[s & 0xf]);
    }
    return out;
}

/*! A simulated computer.
 *
 * Owns its Lua state and everything in it. Destroying a machine closes that state, which is what
 * releases the guest's memory; nothing outside holds a pointer into it.
 * @date 2026-09-16 */
struct machine_t : public vc::object_t {
    lua_State *L = nullptr;         /*!< the guest state; null until start() */
    lua_State *co = nullptr;        /*!< machine.lua running as a coroutine inside L */
    int co_ref = LUA_NOREF;         /*!< keeps `co` alive against the guest's collector */

    int status = MACHINE_OFF;
    std::string error;

    std::string address;
    std::string tmp_address;

    std::vector<component_t> components;
    std::deque<signal_t> signals;

    /*! The machine's own hard disk, which outlives every reboot.
     *
     * A restart rebuilds the Lua state and every component, and it must not wipe the disk - the
     * whole point of installing an operating system onto one is that it is still there next time.
     * So the tree is held here and re-attached, rather than made fresh at boot.
     * @date 2026-09-16 */
    std::shared_ptr<ocfs::filesystem_t> hdd;
    std::string mc_path;

    /*! The screen the interface shows. One machine may drive several, but the panel has to pick
     * one, and the first attached is the one the player put next to the case.
     * @date 2026-09-17 */
    std::shared_ptr<ocsc::buffer_t> primary_screen;

    double boot_time = 0;           /*!< host clock at start(), for computer.uptime */
    double now = 0;                 /*!< host clock, refreshed by step() */
    double wake_at = 0;             /*!< when a sleeping machine may be resumed */
    bool sleeping = false;
    int resume_args = 0;            /*!< values already pushed onto `co` for the next resume */

    /*! How many resumes a single step() will grant before giving the frame back.
     *
     * machine.lua bounds one resume from the inside through `system.timeout`; this bounds how many
     * of them a frame pays for. Without it a machine in a tight loop starves the renderer, since
     * the whole simulator runs on one thread.
     * @date 2026-09-16 */
    int budget_per_step = 24;

    /*! Everything the machine has printed, as lines. This is what a screen shows.
     *
     * Kept here rather than on a screen component because at this stage a machine's output is its
     * error and its boot messages, which exist before any screen does.
     * @date 2026-09-16 */
    std::vector<std::string> output;

    machine_t(vc::object_t::Private priv) : vc::object_t(priv) {}
    virtual ~machine_t() { shutdown(); }

    static vc::object_type_e type_id_static() { return vc::SIM_TYPE_MACHINE; }
    virtual vc::object_type_e type_id() const override { return vc::SIM_TYPE_MACHINE; }

    static vc::ref_t<machine_t> create() {
        auto ret = std::make_shared<machine_t>(vc::object_t::Private{type_id_static()});
        static uint64_t counter = 1;
        ret->address = make_address(counter++);
        ret->tmp_address = make_address(counter++);
        return ret;
    }

    inline virtual std::string to_string() const override {
        return std::format("machine::machine_t[{}] status {} components {}",
                (void *)this, status, components.size());
    }

    component_t *find(const std::string &addr) {
        for (component_t &c : components)
            if (c.address == addr)
                return &c;
        return nullptr;
    }

    /*! Adds a line to what the machine has printed, trimming the backlog.
     *
     * A few hundred lines is more than a screen shows and enough to scroll back through; a machine
     * left running for an hour must not grow without bound.
     * @date 2026-09-16 */
    void emit(const std::string &line) {
        output.push_back(line);
        if (output.size() > 512)
            output.erase(output.begin(), output.begin() + 128);
    }

    /*! Closes the guest state and forgets everything in it. Safe to call twice.
     * @date 2026-09-16 */
    void shutdown() {
        if (L) {
            lua_close(L);
            L = nullptr;
        }
        co = nullptr;
        co_ref = LUA_NOREF;
        sleeping = false;
        if (status != MACHINE_ERROR)
            status = MACHINE_OFF;
    }

    bool running() const { return status == MACHINE_RUNNING || status == MACHINE_BUSY; }
    int get_status() const { return status; }
    std::string get_error() const { return error; }
    std::string get_address() const { return address; }
    int output_len() const { return (int)output.size(); }

    /*! Is the machine asleep waiting for a signal rather than burning its budget?
     *
     * The difference between a computer sitting at a prompt and one stuck in a loop, and the only
     * way to tell them apart from outside: both report themselves as running.
     * @date 2026-09-17 */
    bool idle() const { return sleeping; }

    /*! How many components the machine can see. @date 2026-09-17 */
    int component_count() const { return (int)components.size(); }

    /*! Does this machine have a screen to draw on? @date 2026-09-17 */
    bool has_screen() const { return primary_screen != nullptr; }

    /*! The screen's size in characters, as a two element table. @date 2026-09-17 */
    std::tuple<int, int> screen_size() const {
        if (!primary_screen)
            return {0, 0};
        return {primary_screen->w, primary_screen->h};
    }

    /*! One row of the screen, counted from one, as text. @date 2026-09-17 */
    std::string screen_row(int y) const {
        return primary_screen ? primary_screen->row_text(y) : std::string();
    }

    /*! One row of the screen as coloured runs: a list of {foreground, background, text}.
     *
     * Core: a screen carries a colour per cell, and a reader that takes only the characters throws
     * all of it away - which is why the terminal came out monochrome, and why the cursor was
     * invisible. The cursor is not a thing OpenComputers has: a terminal draws one by swapping a
     * cell's two colours, so the colours ARE the cursor.
     *
     * Runs rather than cells, because a terminal row is overwhelmingly long stretches of one
     * colour. A row of eighty identical cells crosses into Lua as one entry instead of eighty, and
     * the worst case - every cell different - is no worse than sending them all anyway.
     *
     * Trailing blanks in the screen's own colours are dropped, the way row_text drops them, so an
     * empty row costs nothing to draw.
     * @date 2026-09-17 */
    std::vector<std::tuple<double, double, std::string>> screen_row_runs(int y) const {
        std::vector<std::tuple<double, double, std::string>> out;
        if (!primary_screen)
            return out;
        const ocsc::buffer_t &b = *primary_screen;
        if (y < 1 || y > b.h)
            return out;

        /* How far along the row anything worth drawing reaches. A cell is worth drawing when it
        holds a character or when its background differs from the screen's own. */
        int last = 0;
        for (int x = 1; x <= b.w; x++) {
            const ocsc::cell_t &c = b.at(x, y);
            if ((c.ch != ' ' && c.ch != 0) || c.bg != b.bg)
                last = x;
        }
        if (last == 0)
            return out;

        auto encode = [](std::string &dst, uint32_t cp) {
            if (cp == 0)
                cp = ' ';
            if (cp < 0x80) {
                dst.push_back((char)cp);
            }
            else if (cp < 0x800) {
                dst.push_back((char)(0xC0 | (cp >> 6)));
                dst.push_back((char)(0x80 | (cp & 0x3F)));
            }
            else {
                dst.push_back((char)(0xE0 | (cp >> 12)));
                dst.push_back((char)(0x80 | ((cp >> 6) & 0x3F)));
                dst.push_back((char)(0x80 | (cp & 0x3F)));
            }
        };

        uint32_t run_fg = b.at(1, y).fg;
        uint32_t run_bg = b.at(1, y).bg;
        std::string run;
        for (int x = 1; x <= last; x++) {
            const ocsc::cell_t &c = b.at(x, y);
            if (c.fg != run_fg || c.bg != run_bg) {
                if (!run.empty())
                    out.push_back({(double)run_fg, (double)run_bg, run});
                run.clear();
                run_fg = c.fg;
                run_bg = c.bg;
            }
            encode(run, c.ch);
        }
        if (!run.empty())
            out.push_back({(double)run_fg, (double)run_bg, run});
        return out;
    }

    /*! Where the cursor is, as a two element table, or zeroes when there is none.
     *
     * Core: OpenComputers has no cursor. A terminal draws one by SWAPPING THE COLOURS of the cell
     * it sits on and swapping them back a moment later, which is why one blinks - and why a reader
     * that only takes the characters out of the grid, as screen_row does, cannot see it at all.
     *
     * So it is found rather than reported: the one cell whose foreground and background are the
     * exact reverse of the colours the graphics card is currently drawing with. That is the
     * definition the terminal itself is working to, so it finds the cursor wherever the cursor is,
     * without either side having to agree on anything extra.
     *
     * It blinks, so half the time there is nothing to find. That is not a failure - it is the
     * blink, and passing the zeroes through is what makes it blink on screen too.
     * @date 2026-09-17 */
    std::tuple<int, int> screen_cursor() const {
        if (!primary_screen)
            return {0, 0};
        const ocsc::buffer_t &b = *primary_screen;

        for (int y = 1; y <= b.h; y++)
            for (int x = 1; x <= b.w; x++) {
                const ocsc::cell_t &c = b.at(x, y);
                if (c.fg == b.bg && c.bg == b.fg)
                    return {x, y};
            }
        return {0, 0};
    }

    /*! One line of the machine's output, counted from one. @date 2026-09-16 */
    std::string output_at(int i) const {
        if (i < 1 || i > (int)output.size())
            return {};
        return output[(size_t)(i - 1)];
    }

    /*! Queues a signal for the guest.
     *
     * The queue is bounded, as the real mod's is: a producer that outruns the machine must be told
     * so rather than be allowed to grow the queue until memory runs out. Returns false when full.
     * @date 2026-09-16 */
    bool push_signal(const std::string &name, const std::vector<sig_val_t> &args) {
        if (signals.size() >= 256)
            return false;
        signals.push_back(signal_t{name, args});
        return true;
    }

    /*! Queues a signal carrying only strings and numbers, which is all Lua hands over here.
     * @date 2026-09-16 */
    bool signal_str(const char *name, const char *a) {
        std::vector<sig_val_t> args;
        if (a) {
            sig_val_t v;
            v.kind = sig_val_t::STR;
            v.s = a;
            args.push_back(v);
        }
        return push_signal(name ? name : "", args);
    }

    bool signal_num(const char *name, double a, double b) {
        std::vector<sig_val_t> args;
        sig_val_t v;
        v.kind = sig_val_t::NUM;
        v.n = a;
        args.push_back(v);
        v.n = b;
        args.push_back(v);
        return push_signal(name ? name : "", args);
    }
};

using machine_p = vc::ref_t<machine_t>;

/* --- reaching the machine from a host function --------------------------------------------- */

/*! The machine a host function belongs to, taken from the closure's upvalue.
 *
 * Every host function below is registered as a closure over a light pointer to its machine, which
 * is how one C function serves many machines without a lookup table. @date 2026-09-16 */
inline machine_t *self(lua_State *L) {
    return (machine_t *)lua_touserdata(L, lua_upvalueindex(1));
}

/*! Registers one host function on the table at the top of the stack, closed over `m`.
 * @date 2026-09-16 */
inline void put(lua_State *L, machine_t *m, const char *name, lua_CFunction fn) {
    lua_pushlightuserdata(L, m);
    lua_pushcclosure(L, fn, 1);
    lua_setfield(L, -2, name);
}

/* --- the component table -------------------------------------------------------------------- */

inline int l_component_list(lua_State *L) {
    machine_t *m = self(L);
    const char *filter = lua_isnoneornil(L, 1) ? nullptr : luaL_checkstring(L, 1);
    bool exact = lua_toboolean(L, 2);

    lua_newtable(L);
    for (component_t &c : m->components) {
        if (filter) {
            if (exact ? c.type != filter : c.type.find(filter) == std::string::npos)
                continue;
        }
        lua_pushstring(L, c.type.c_str());
        lua_setfield(L, -2, c.address.c_str());
    }
    return 1;
}

inline int l_component_type(lua_State *L) {
    machine_t *m = self(L);
    component_t *c = m->find(luaL_checkstring(L, 1));
    if (!c) {
        lua_pushnil(L);
        lua_pushstring(L, "no such component");
        return 2;
    }
    lua_pushstring(L, c->type.c_str());
    return 1;
}

inline int l_component_slot(lua_State *L) {
    machine_t *m = self(L);
    component_t *c = m->find(luaL_checkstring(L, 1));
    if (!c) {
        lua_pushnil(L);
        lua_pushstring(L, "no such component");
        return 2;
    }
    lua_pushinteger(L, c->slot);
    return 1;
}

/*! Every method of a component, shaped the way machine.lua reads it.
 *
 * It wants a table of name to descriptor, and it looks for `direct` on each - that is what decides
 * whether a call runs inline or is bounced out to the host. A descriptor with neither a getter nor
 * a setter is a method rather than a field, which is all this file has.
 * @date 2026-09-16 */
inline int l_component_methods(lua_State *L) {
    machine_t *m = self(L);
    component_t *c = m->find(luaL_checkstring(L, 1));
    if (!c) {
        lua_pushnil(L);
        lua_pushstring(L, "no such component");
        return 2;
    }

    lua_newtable(L);
    for (auto &kv : c->methods) {
        lua_newtable(L);
        lua_pushboolean(L, kv.second.direct);
        lua_setfield(L, -2, "direct");
        lua_pushboolean(L, false);
        lua_setfield(L, -2, "getter");
        lua_pushboolean(L, false);
        lua_setfield(L, -2, "setter");
        lua_setfield(L, -2, kv.first.c_str());
    }
    return 1;
}

inline int l_component_doc(lua_State *L) {
    machine_t *m = self(L);
    component_t *c = m->find(luaL_checkstring(L, 1));
    const char *name = luaL_checkstring(L, 2);
    if (c) {
        auto it = c->methods.find(name);
        if (it != c->methods.end() && it->second.doc) {
            lua_pushstring(L, it->second.doc);
            return 1;
        }
    }
    lua_pushnil(L);
    return 1;
}

inline int l_component_invoke(lua_State *L) {
    machine_t *m = self(L);
    const char *addr = luaL_checkstring(L, 1);
    const char *name = luaL_checkstring(L, 2);

    component_t *c = m->find(addr);
    if (!c) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, "no such component");
        return 2;
    }

    auto it = c->methods.find(name);
    if (it == c->methods.end()) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, "no such method");
        return 2;
    }

    /* The method reads its own arguments from index 3 up and pushes its results.
    THE LEADING BOOLEAN IS THE CONTRACT. machine.lua's processResult() reads what comes back as
    `{ok, results...}` and rethrows `result[2]` when `result[1]` is false - so a method's first
    real result must not land in slot one. Returning the results bare made the BIOS code itself
    read as the success flag and the code read as nil, which surfaced as "no bios found" with
    every layer below working perfectly.
    The flag is pushed after the call and moved underneath, so the method still sees its own
    arguments at the indices it expects. */
    int base = lua_gettop(L);
    int n = it->second.fn(*m, *c, L);
    lua_pushboolean(L, 1);
    lua_insert(L, base + 1);
    return n + 1;
}

/* --- the computer table --------------------------------------------------------------------- */

inline int l_computer_address(lua_State *L) {
    lua_pushstring(L, self(L)->address.c_str());
    return 1;
}

inline int l_computer_tmp_address(lua_State *L) {
    lua_pushstring(L, self(L)->tmp_address.c_str());
    return 1;
}

inline int l_computer_uptime(lua_State *L) {
    lua_pushnumber(L, host_clock() - self(L)->boot_time);
    return 1;
}

inline int l_computer_real_time(lua_State *L) {
    lua_pushnumber(L, host_clock());
    return 1;
}

/*! Memory, energy and the rest of the numbers a machine reports about itself.
 *
 * Constants for now. They are real questions with real answers once components are modelled - free
 * memory follows from the RAM installed - but nothing in the boot path branches on them, and a
 * plausible constant is more honest than a number computed from nothing.
 * @date 2026-09-16 */
inline int l_computer_total_memory(lua_State *L) { lua_pushinteger(L, 2 * 1024 * 1024); return 1; }
inline int l_computer_free_memory(lua_State *L)  { lua_pushinteger(L, 1024 * 1024); return 1; }
inline int l_computer_energy(lua_State *L)       { lua_pushnumber(L, 1000.0); return 1; }
inline int l_computer_max_energy(lua_State *L)   { lua_pushnumber(L, 1000.0); return 1; }
inline int l_computer_is_robot(lua_State *L)     { lua_pushboolean(L, 0); return 1; }
inline int l_computer_users(lua_State *L)        { return 0; }
inline int l_computer_add_user(lua_State *L)     { lua_pushboolean(L, 1); return 1; }
inline int l_computer_remove_user(lua_State *L)  { lua_pushboolean(L, 1); return 1; }

inline int l_computer_get_arch(lua_State *L) {
    lua_pushstring(L, "Lua 5.4");
    return 1;
}

inline int l_computer_get_archs(lua_State *L) {
    lua_newtable(L);
    lua_pushstring(L, "Lua 5.4");
    lua_rawseti(L, -2, 1);
    return 1;
}

inline int l_computer_set_arch(lua_State *L) {
    lua_pushboolean(L, 0);
    lua_pushstring(L, "unsupported architecture");
    return 2;
}

/*! The boot address, which bios.lua overrides with its own EEPROM-backed pair almost immediately.
 * Present because machine.lua captures them before the BIOS runs. @date 2026-09-16 */
inline int l_computer_get_boot(lua_State *L) { lua_pushnil(L); return 1; }
inline int l_computer_set_boot(lua_State *L) { lua_pushboolean(L, 1); return 1; }

inline int l_computer_push_signal(lua_State *L) {
    machine_t *m = self(L);
    const char *name = luaL_checkstring(L, 1);

    std::vector<sig_val_t> args;
    int top = lua_gettop(L);
    for (int i = 2; i <= top; i++) {
        sig_val_t v;
        switch (lua_type(L, i)) {
            case LUA_TBOOLEAN: v.kind = sig_val_t::BOOL; v.b = lua_toboolean(L, i); break;
            case LUA_TNUMBER:  v.kind = sig_val_t::NUM;  v.n = lua_tonumber(L, i);  break;
            case LUA_TSTRING:  v.kind = sig_val_t::STR;  v.s = lua_tostring(L, i);  break;
            default:           v.kind = sig_val_t::NIL;  break;
        }
        args.push_back(v);
    }

    lua_pushboolean(L, m->push_signal(name, args) ? 1 : 0);
    return 1;
}

/* --- unicode -------------------------------------------------------------------------------- */

/*! How many bytes the UTF-8 character starting at `c` occupies. @date 2026-09-16 */
inline int utf8_len(unsigned char c) {
    if (c < 0x80) return 1;
    if ((c & 0xE0) == 0xC0) return 2;
    if ((c & 0xF0) == 0xE0) return 3;
    if ((c & 0xF8) == 0xF0) return 4;
    return 1;
}

inline int l_unicode_len(lua_State *L) {
    size_t n = 0;
    const char *s = luaL_checklstring(L, 1, &n);
    lua_Integer count = 0;
    for (size_t i = 0; i < n; i += (size_t)utf8_len((unsigned char)s[i]))
        count++;
    lua_pushinteger(L, count);
    return 1;
}

/*! A substring by character rather than by byte, with Lua's own negative-index convention.
 * @date 2026-09-16 */
inline int l_unicode_sub(lua_State *L) {
    size_t n = 0;
    const char *s = luaL_checklstring(L, 1, &n);

    std::vector<size_t> starts;
    for (size_t i = 0; i < n; i += (size_t)utf8_len((unsigned char)s[i]))
        starts.push_back(i);
    starts.push_back(n);
    lua_Integer chars = (lua_Integer)starts.size() - 1;

    lua_Integer a = luaL_optinteger(L, 2, 1);
    lua_Integer b = luaL_optinteger(L, 3, -1);
    if (a < 0) a = chars + a + 1;
    if (b < 0) b = chars + b + 1;
    if (a < 1) a = 1;
    if (b > chars) b = chars;

    if (a > b) {
        lua_pushstring(L, "");
        return 1;
    }
    lua_pushlstring(L, s + starts[(size_t)a - 1], starts[(size_t)b] - starts[(size_t)a - 1]);
    return 1;
}

/*! The character for a code point, and its companions.
 *
 * Only the Basic Multilingual Plane is encoded, which covers everything a terminal shows. Width is
 * answered as one for everything: double-width forms would change how text lays out on a screen,
 * and that is a question for when there is a screen to lay it out on.
 * @date 2026-09-16 */
inline int l_unicode_char(lua_State *L) {
    std::string out;
    int top = lua_gettop(L);
    for (int i = 1; i <= top; i++) {
        unsigned cp = (unsigned)luaL_checkinteger(L, i);
        if (cp < 0x80) {
            out.push_back((char)cp);
        }
        else if (cp < 0x800) {
            out.push_back((char)(0xC0 | (cp >> 6)));
            out.push_back((char)(0x80 | (cp & 0x3F)));
        }
        else {
            out.push_back((char)(0xE0 | (cp >> 12)));
            out.push_back((char)(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back((char)(0x80 | (cp & 0x3F)));
        }
    }
    lua_pushlstring(L, out.data(), out.size());
    return 1;
}

inline int l_unicode_char_width(lua_State *L) { lua_pushinteger(L, 1); return 1; }
inline int l_unicode_is_wide(lua_State *L)    { lua_pushboolean(L, 0); return 1; }

inline int l_unicode_wlen(lua_State *L) { return l_unicode_len(L); }

inline int l_unicode_wtrunc(lua_State *L) {
    lua_settop(L, 2);
    lua_Integer want = luaL_checkinteger(L, 2);
    lua_pushinteger(L, 1);
    lua_pushinteger(L, want > 0 ? want - 1 : 0);
    lua_remove(L, 2);
    return l_unicode_sub(L);
}

inline int l_unicode_lower(lua_State *L) {
    std::string s = luaL_checkstring(L, 1);
    for (char &c : s)
        if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
    lua_pushlstring(L, s.data(), s.size());
    return 1;
}

inline int l_unicode_upper(lua_State *L) {
    std::string s = luaL_checkstring(L, 1);
    for (char &c : s)
        if (c >= 'a' && c <= 'z') c = (char)(c - 'a' + 'A');
    lua_pushlstring(L, s.data(), s.size());
    return 1;
}

/*! Reverses by character, so multi-byte sequences survive. @date 2026-09-16 */
inline int l_unicode_reverse(lua_State *L) {
    size_t n = 0;
    const char *s = luaL_checklstring(L, 1, &n);
    std::string out;
    out.reserve(n);
    std::vector<size_t> starts;
    for (size_t i = 0; i < n; i += (size_t)utf8_len((unsigned char)s[i]))
        starts.push_back(i);
    for (size_t i = starts.size(); i-- > 0; ) {
        size_t end = (i + 1 < starts.size()) ? starts[i + 1] : n;
        out.append(s + starts[i], end - starts[i]);
    }
    lua_pushlstring(L, out.data(), out.size());
    return 1;
}

/* --- system --------------------------------------------------------------------------------- */

/*! Bytecode is refused, so the guest's `load` is forced to text mode. Loading compiled chunks is
 * the standard way out of a Lua sandbox. @date 2026-09-16 */
inline int l_system_allow_bytecode(lua_State *L) { lua_pushboolean(L, 0); return 1; }

/*! User `__gc` handlers stay off, which is what the mod does by default too - they run at times
 * hooks cannot bound. @date 2026-09-16 */
inline int l_system_allow_gc(lua_State *L) { lua_pushboolean(L, 0); return 1; }

/*! How long one resume may run before machine.lua's own watchdog stops it. @date 2026-09-16 */
inline int l_system_timeout(lua_State *L) { lua_pushnumber(L, 3.0); return 1; }

/* --- the EEPROM ----------------------------------------------------------------------------- */

inline int eeprom_get(machine_t &, component_t &c, lua_State *L) {
    lua_pushlstring(L, c.code.data(), c.code.size());
    return 1;
}

inline int eeprom_set(machine_t &, component_t &c, lua_State *L) {
    size_t n = 0;
    const char *s = lua_tolstring(L, 3, &n);
    c.code.assign(s ? s : "", s ? n : 0);
    return 0;
}

inline int eeprom_get_data(machine_t &, component_t &c, lua_State *L) {
    lua_pushlstring(L, c.data.data(), c.data.size());
    return 1;
}

inline int eeprom_set_data(machine_t &, component_t &c, lua_State *L) {
    size_t n = 0;
    const char *s = lua_tolstring(L, 3, &n);
    c.data.assign(s ? s : "", s ? n : 0);
    return 0;
}

inline int eeprom_get_label(machine_t &, component_t &c, lua_State *L) {
    lua_pushstring(L, c.label.c_str());
    return 1;
}

inline int eeprom_set_label(machine_t &, component_t &c, lua_State *L) {
    c.label = lua_tostring(L, 3) ? lua_tostring(L, 3) : "";
    lua_pushstring(L, c.label.c_str());
    return 1;
}

inline int eeprom_get_size(machine_t &, component_t &, lua_State *L) {
    lua_pushinteger(L, 4096);
    return 1;
}

inline int eeprom_get_data_size(machine_t &, component_t &, lua_State *L) {
    lua_pushinteger(L, 256);
    return 1;
}

/* --- the filesystem ------------------------------------------------------------------------- */

/*! The argument at `i`, as a path. @date 2026-09-16 */
inline std::string fs_path(lua_State *L, int i) {
    const char *s = lua_tostring(L, i);
    return s ? s : "";
}

inline int fs_is_read_only(machine_t &, component_t &c, lua_State *L) {
    lua_pushboolean(L, c.fs && c.fs->read_only);
    return 1;
}

inline int fs_get_label(machine_t &, component_t &c, lua_State *L) {
    lua_pushstring(L, c.fs ? c.fs->label.c_str() : "");
    return 1;
}

inline int fs_set_label(machine_t &, component_t &c, lua_State *L) {
    if (c.fs && !c.fs->read_only)
        c.fs->label = fs_path(L, 3);
    lua_pushstring(L, c.fs ? c.fs->label.c_str() : "");
    return 1;
}

inline int fs_space_total(machine_t &, component_t &c, lua_State *L) {
    lua_pushinteger(L, c.fs ? (lua_Integer)c.fs->capacity : 0);
    return 1;
}

inline int fs_space_used(machine_t &, component_t &c, lua_State *L) {
    lua_pushinteger(L, c.fs ? (lua_Integer)c.fs->used() : 0);
    return 1;
}

inline int fs_exists(machine_t &, component_t &c, lua_State *L) {
    lua_pushboolean(L, c.fs && c.fs->find(fs_path(L, 3)) != nullptr);
    return 1;
}

inline int fs_is_directory(machine_t &, component_t &c, lua_State *L) {
    ocfs::node_t *n = c.fs ? c.fs->find(fs_path(L, 3)) : nullptr;
    lua_pushboolean(L, n && n->dir);
    return 1;
}

inline int fs_size(machine_t &, component_t &c, lua_State *L) {
    ocfs::node_t *n = c.fs ? c.fs->find(fs_path(L, 3)) : nullptr;
    lua_pushinteger(L, (n && !n->dir) ? (lua_Integer)n->data.size() : 0);
    return 1;
}

inline int fs_last_modified(machine_t &, component_t &c, lua_State *L) {
    ocfs::node_t *n = c.fs ? c.fs->find(fs_path(L, 3)) : nullptr;
    lua_pushinteger(L, n ? (lua_Integer)n->mtime : 0);
    return 1;
}

/*! The names in a directory, with a trailing slash on each that is itself a directory.
 *
 * That slash is the component's convention and OpenOS's `filesystem.list` relies on it to tell the
 * two apart without asking again per entry.
 * @date 2026-09-16 */
inline int fs_list(machine_t &, component_t &c, lua_State *L) {
    ocfs::node_t *n = c.fs ? c.fs->find(fs_path(L, 3)) : nullptr;
    if (!n || !n->dir) {
        lua_pushnil(L);
        return 1;
    }
    lua_newtable(L);
    int i = 1;
    for (auto &kv : n->children) {
        std::string name = kv.first + (kv.second.dir ? "/" : "");
        lua_pushlstring(L, name.data(), name.size());
        lua_rawseti(L, -2, i++);
    }
    return 1;
}

inline int fs_make_directory(machine_t &, component_t &c, lua_State *L) {
    if (!c.fs || c.fs->read_only) {
        lua_pushboolean(L, 0);
        return 1;
    }
    lua_pushboolean(L, c.fs->make_directory(fs_path(L, 3)));
    return 1;
}

inline int fs_remove(machine_t &, component_t &c, lua_State *L) {
    if (!c.fs || c.fs->read_only) {
        lua_pushboolean(L, 0);
        return 1;
    }
    lua_pushboolean(L, c.fs->remove(fs_path(L, 3)));
    return 1;
}

inline int fs_rename(machine_t &, component_t &c, lua_State *L) {
    if (!c.fs || c.fs->read_only) {
        lua_pushboolean(L, 0);
        return 1;
    }
    lua_pushboolean(L, c.fs->rename(fs_path(L, 3), fs_path(L, 4)));
    return 1;
}

/*! Opens a file and answers a handle.
 *
 * The modes are the component's: `r` and `w` and `a`, with an optional `b` that changes nothing
 * here because everything is bytes already. Opening for writing truncates and opening for appending
 * seeks to the end, both of which create the file and the directories above it.
 *
 * A read of something absent answers nil and a reason, which is what the guest's `io.open` turns
 * into its own error.
 * @date 2026-09-16 */
inline int fs_open(machine_t &, component_t &c, lua_State *L) {
    if (!c.fs) {
        lua_pushnil(L);
        lua_pushstring(L, "no medium");
        return 2;
    }
    std::string path = fs_path(L, 3);
    std::string mode = lua_isnoneornil(L, 4) ? "r" : fs_path(L, 4);

    bool want_write = mode.find('w') != std::string::npos;
    bool want_append = mode.find('a') != std::string::npos;

    if ((want_write || want_append) && c.fs->read_only) {
        lua_pushnil(L);
        lua_pushstring(L, "filesystem is read only");
        return 2;
    }

    ocfs::node_t *n = c.fs->find(path);
    if (!want_write && !want_append) {
        if (!n || n->dir) {
            lua_pushnil(L);
            lua_pushstring(L, "file not found");
            return 2;
        }
    }
    else {
        if (want_write || !n) {
            if (!c.fs->write_file(path, want_append && n ? n->data : std::string())) {
                lua_pushnil(L);
                lua_pushstring(L, "cannot create file");
                return 2;
            }
            n = c.fs->find(path);
        }
    }

    ocfs::handle_t h;
    h.path = path;
    h.write = want_write || want_append;
    h.pos = want_append && n ? n->data.size() : 0;

    int id = c.fs->next_handle++;
    c.fs->handles[id] = h;
    lua_pushinteger(L, id);
    return 1;
}

inline int fs_close(machine_t &, component_t &c, lua_State *L) {
    if (c.fs)
        c.fs->handles.erase((int)lua_tointeger(L, 3));
    return 0;
}

/*! Reads up to `count` bytes, or nil once the end is reached.
 *
 * `count` arrives as `math.huge` when the caller wants everything left, which is how bios.lua reads
 * init.lua - it loops until this answers nil.
 * @date 2026-09-16 */
inline int fs_read(machine_t &, component_t &c, lua_State *L) {
    if (!c.fs) {
        lua_pushnil(L);
        return 1;
    }
    auto it = c.fs->handles.find((int)lua_tointeger(L, 3));
    if (it == c.fs->handles.end()) {
        lua_pushnil(L);
        lua_pushstring(L, "bad file descriptor");
        return 2;
    }

    ocfs::node_t *n = c.fs->find(it->second.path);
    if (!n || n->dir) {
        lua_pushnil(L);
        return 1;
    }

    double want = lua_tonumber(L, 4);
    size_t left = n->data.size() - std::min(it->second.pos, n->data.size());
    if (left == 0) {
        lua_pushnil(L);
        return 1;
    }
    size_t take = (want >= (double)left || want <= 0) ? left : (size_t)want;

    lua_pushlstring(L, n->data.data() + it->second.pos, take);
    it->second.pos += take;
    return 1;
}

inline int fs_write(machine_t &, component_t &c, lua_State *L) {
    if (!c.fs || c.fs->read_only) {
        lua_pushboolean(L, 0);
        return 1;
    }
    auto it = c.fs->handles.find((int)lua_tointeger(L, 3));
    if (it == c.fs->handles.end()) {
        lua_pushboolean(L, 0);
        return 1;
    }

    size_t len = 0;
    const char *bytes = lua_tolstring(L, 4, &len);
    ocfs::node_t *n = c.fs->find(it->second.path);
    if (!n || n->dir || !bytes) {
        lua_pushboolean(L, 0);
        return 1;
    }

    if (it->second.pos > n->data.size())
        n->data.resize(it->second.pos, '\0');
    n->data.replace(it->second.pos, std::min(len, n->data.size() - it->second.pos),
            bytes, len);
    it->second.pos += len;
    lua_pushboolean(L, 1);
    return 1;
}

inline int fs_seek(machine_t &, component_t &c, lua_State *L) {
    if (!c.fs) {
        lua_pushnil(L);
        return 1;
    }
    auto it = c.fs->handles.find((int)lua_tointeger(L, 3));
    if (it == c.fs->handles.end()) {
        lua_pushnil(L);
        lua_pushstring(L, "bad file descriptor");
        return 2;
    }

    std::string whence = fs_path(L, 4);
    lua_Integer offset = (lua_Integer)lua_tointeger(L, 5);
    ocfs::node_t *n = c.fs->find(it->second.path);
    size_t size = (n && !n->dir) ? n->data.size() : 0;

    lua_Integer base = 0;
    if (whence == "cur")
        base = (lua_Integer)it->second.pos;
    else if (whence == "end")
        base = (lua_Integer)size;

    lua_Integer target = base + offset;
    if (target < 0)
        target = 0;
    it->second.pos = (size_t)target;
    lua_pushinteger(L, target);
    return 1;
}

/*! Builds a filesystem component around an existing tree. @date 2026-09-16 */
inline component_t make_filesystem(std::shared_ptr<ocfs::filesystem_t> fs, uint64_t seed) {
    component_t c;
    c.address = make_address(seed);
    c.type = "filesystem";
    c.fs = fs;
    c.label = fs ? fs->label : std::string();

    c.methods["isReadOnly"]    = {true, fs_is_read_only,   "isReadOnly():boolean"};
    c.methods["getLabel"]      = {true, fs_get_label,      "getLabel():string"};
    c.methods["setLabel"]      = {true, fs_set_label,      "setLabel(v:string):string"};
    c.methods["spaceTotal"]    = {true, fs_space_total,    "spaceTotal():number"};
    c.methods["spaceUsed"]     = {true, fs_space_used,     "spaceUsed():number"};
    c.methods["exists"]        = {true, fs_exists,         "exists(path:string):boolean"};
    c.methods["size"]          = {true, fs_size,           "size(path:string):number"};
    c.methods["isDirectory"]   = {true, fs_is_directory,   "isDirectory(path:string):boolean"};
    c.methods["lastModified"]  = {true, fs_last_modified,  "lastModified(path:string):number"};
    c.methods["list"]          = {true, fs_list,           "list(path:string):table"};
    c.methods["makeDirectory"] = {true, fs_make_directory, "makeDirectory(path:string):boolean"};
    c.methods["remove"]        = {true, fs_remove,         "remove(path:string):boolean"};
    c.methods["rename"]        = {true, fs_rename,         "rename(from:string,to:string):boolean"};
    c.methods["open"]          = {true, fs_open,           "open(path:string[,mode:string])"};
    c.methods["close"]         = {true, fs_close,          "close(handle:number)"};
    c.methods["read"]          = {true, fs_read,           "read(handle:number,count:number)"};
    c.methods["write"]         = {true, fs_write,          "write(handle:number,value:string)"};
    c.methods["seek"]          = {true, fs_seek,           "seek(handle:number,whence:string,off)"};
    return c;
}

/* --- the screen, the gpu and the keyboard ---------------------------------------------------- */

/*! The grid a gpu is currently bound to, or null when it is bound to nothing. @date 2026-09-17 */
inline std::shared_ptr<ocsc::buffer_t> bound_screen(machine_t &m, component_t &gpu) {
    if (gpu.bound_to.empty())
        return nullptr;
    component_t *c = m.find(gpu.bound_to);
    return c ? c->screen : nullptr;
}

/*! The characters of a Lua string, as code points.
 *
 * The grid is addressed in characters, not bytes, so a multi-byte character must occupy one cell
 * rather than two or three. This is the decode that makes that true.
 * @date 2026-09-17 */
inline std::vector<uint32_t> to_codepoints(const char *s, size_t n) {
    std::vector<uint32_t> out;
    for (size_t i = 0; i < n; ) {
        unsigned char c = (unsigned char)s[i];
        int len = utf8_len(c);
        uint32_t cp = c;
        if (len == 2 && i + 1 < n)
            cp = ((c & 0x1Fu) << 6) | ((unsigned char)s[i + 1] & 0x3Fu);
        else if (len == 3 && i + 2 < n)
            cp = ((c & 0x0Fu) << 12) | (((unsigned char)s[i + 1] & 0x3Fu) << 6)
                    | ((unsigned char)s[i + 2] & 0x3Fu);
        else if (len == 4 && i + 3 < n)
            cp = '?';       /* beyond the basic plane; the grid has nothing to show for it */
        out.push_back(cp);
        i += (size_t)len;
    }
    return out;
}

inline int gpu_bind(machine_t &m, component_t &c, lua_State *L) {
    const char *addr = lua_tostring(L, 3);
    component_t *target = addr ? m.find(addr) : nullptr;
    if (!target || target->type != "screen") {
        lua_pushboolean(L, 0);
        lua_pushstring(L, "invalid address");
        return 2;
    }
    c.bound_to = target->address;
    lua_pushboolean(L, 1);
    return 1;
}

inline int gpu_get_screen(machine_t &, component_t &c, lua_State *L) {
    if (c.bound_to.empty())
        lua_pushnil(L);
    else
        lua_pushstring(L, c.bound_to.c_str());
    return 1;
}

inline int gpu_max_resolution(machine_t &m, component_t &c, lua_State *L) {
    auto b = bound_screen(m, c);
    lua_pushinteger(L, b ? b->max_w : 160);
    lua_pushinteger(L, b ? b->max_h : 50);
    return 2;
}

inline int gpu_get_resolution(machine_t &m, component_t &c, lua_State *L) {
    auto b = bound_screen(m, c);
    lua_pushinteger(L, b ? b->w : 0);
    lua_pushinteger(L, b ? b->h : 0);
    return 2;
}

inline int gpu_set_resolution(machine_t &m, component_t &c, lua_State *L) {
    auto b = bound_screen(m, c);
    if (!b) {
        lua_pushboolean(L, 0);
        return 1;
    }
    int w = (int)lua_tointeger(L, 3);
    int h = (int)lua_tointeger(L, 4);
    bool changed = (w != b->w || h != b->h);
    b->resize(w, h);
    lua_pushboolean(L, changed);
    return 1;
}

/*! The visible part of the screen, which here is always the whole of it - there is no scrolling
 * viewport smaller than the grid. @date 2026-09-17 */
inline int gpu_get_viewport(machine_t &m, component_t &c, lua_State *L) {
    return gpu_get_resolution(m, c, L);
}

inline int gpu_set_viewport(machine_t &m, component_t &c, lua_State *L) {
    return gpu_set_resolution(m, c, L);
}

inline int gpu_max_depth(machine_t &, component_t &, lua_State *L) {
    lua_pushinteger(L, 8);
    return 1;
}

inline int gpu_get_depth(machine_t &m, component_t &c, lua_State *L) {
    auto b = bound_screen(m, c);
    lua_pushinteger(L, b ? b->depth : 8);
    return 1;
}

inline int gpu_set_depth(machine_t &m, component_t &c, lua_State *L) {
    auto b = bound_screen(m, c);
    int was = b ? b->depth : 8;
    if (b)
        b->depth = (int)lua_tointeger(L, 3);
    lua_pushinteger(L, was);
    return 1;
}

/*! The pen colours. The second result says whether the colour is a palette index, which it never is
 * here - the palette is not implemented and every colour is a direct value.
 * @date 2026-09-17 */
inline int gpu_get_background(machine_t &m, component_t &c, lua_State *L) {
    auto b = bound_screen(m, c);
    lua_pushinteger(L, b ? (lua_Integer)b->bg : 0);
    lua_pushboolean(L, 0);
    return 2;
}

inline int gpu_get_foreground(machine_t &m, component_t &c, lua_State *L) {
    auto b = bound_screen(m, c);
    lua_pushinteger(L, b ? (lua_Integer)b->fg : 0xffffff);
    lua_pushboolean(L, 0);
    return 2;
}

inline int gpu_set_background(machine_t &m, component_t &c, lua_State *L) {
    auto b = bound_screen(m, c);
    lua_Integer was = b ? (lua_Integer)b->bg : 0;
    if (b)
        b->bg = (uint32_t)lua_tointeger(L, 3);
    lua_pushinteger(L, was);
    return 1;
}

inline int gpu_set_foreground(machine_t &m, component_t &c, lua_State *L) {
    auto b = bound_screen(m, c);
    lua_Integer was = b ? (lua_Integer)b->fg : 0xffffff;
    if (b)
        b->fg = (uint32_t)lua_tointeger(L, 3);
    lua_pushinteger(L, was);
    return 1;
}

/*! The palette, which is flat: index n answers n. Nothing in OpenOS's boot path depends on a real
 * palette, and a wrong colour is better than a missing method. @date 2026-09-17 */
inline int gpu_get_palette_color(machine_t &, component_t &, lua_State *L) {
    lua_pushinteger(L, lua_tointeger(L, 3));
    return 1;
}

inline int gpu_set_palette_color(machine_t &, component_t &, lua_State *L) {
    lua_pushinteger(L, lua_tointeger(L, 4));
    return 1;
}

inline int gpu_get(machine_t &m, component_t &c, lua_State *L) {
    auto b = bound_screen(m, c);
    int x = (int)lua_tointeger(L, 3);
    int y = (int)lua_tointeger(L, 4);
    if (!b || !b->in_bounds(x, y)) {
        lua_pushnil(L);
        return 1;
    }
    const ocsc::cell_t &cell = b->at(x, y);

    /* The character comes back as a string, since that is what the guest writes and compares. */
    std::vector<uint32_t> one{cell.ch};
    ocsc::buffer_t tmp;
    (void)tmp;
    std::string ch;
    uint32_t cp = cell.ch;
    if (cp < 0x80) {
        ch.push_back((char)cp);
    }
    else if (cp < 0x800) {
        ch.push_back((char)(0xC0 | (cp >> 6)));
        ch.push_back((char)(0x80 | (cp & 0x3F)));
    }
    else {
        ch.push_back((char)(0xE0 | (cp >> 12)));
        ch.push_back((char)(0x80 | ((cp >> 6) & 0x3F)));
        ch.push_back((char)(0x80 | (cp & 0x3F)));
    }

    lua_pushlstring(L, ch.data(), ch.size());
    lua_pushinteger(L, (lua_Integer)cell.fg);
    lua_pushinteger(L, (lua_Integer)cell.bg);
    return 3;
}

inline int gpu_set(machine_t &m, component_t &c, lua_State *L) {
    auto b = bound_screen(m, c);
    if (!b) {
        lua_pushboolean(L, 0);
        return 1;
    }
    int x = (int)lua_tointeger(L, 3);
    int y = (int)lua_tointeger(L, 4);
    size_t n = 0;
    const char *text = lua_tolstring(L, 5, &n);
    bool vertical = lua_toboolean(L, 6);

    if (text)
        b->write(x, y, to_codepoints(text, n), vertical);
    lua_pushboolean(L, 1);
    return 1;
}

inline int gpu_fill(machine_t &m, component_t &c, lua_State *L) {
    auto b = bound_screen(m, c);
    if (!b) {
        lua_pushboolean(L, 0);
        return 1;
    }
    int x = (int)lua_tointeger(L, 3);
    int y = (int)lua_tointeger(L, 4);
    int w = (int)lua_tointeger(L, 5);
    int h = (int)lua_tointeger(L, 6);
    size_t n = 0;
    const char *text = lua_tolstring(L, 7, &n);

    std::vector<uint32_t> cps = text ? to_codepoints(text, n) : std::vector<uint32_t>{' '};
    b->fill(x, y, w, h, cps.empty() ? ' ' : cps[0]);
    lua_pushboolean(L, 1);
    return 1;
}

inline int gpu_copy(machine_t &m, component_t &c, lua_State *L) {
    auto b = bound_screen(m, c);
    if (!b) {
        lua_pushboolean(L, 0);
        return 1;
    }
    b->copy((int)lua_tointeger(L, 3), (int)lua_tointeger(L, 4),
            (int)lua_tointeger(L, 5), (int)lua_tointeger(L, 6),
            (int)lua_tointeger(L, 7), (int)lua_tointeger(L, 8));
    lua_pushboolean(L, 1);
    return 1;
}

/*! Builds a gpu, bound to nothing until the BIOS or OpenOS binds it. @date 2026-09-17 */
inline component_t make_gpu(uint64_t seed) {
    component_t c;
    c.address = make_address(seed);
    c.type = "gpu";
    c.label = "Graphics Card (Tier 3)";

    c.methods["bind"]            = {true, gpu_bind,            "bind(address:string)"};
    c.methods["getScreen"]       = {true, gpu_get_screen,      "getScreen():string"};
    c.methods["maxResolution"]   = {true, gpu_max_resolution,  "maxResolution():number,number"};
    c.methods["getResolution"]   = {true, gpu_get_resolution,  "getResolution():number,number"};
    c.methods["setResolution"]   = {true, gpu_set_resolution,  "setResolution(w:number,h:number)"};
    c.methods["getViewport"]     = {true, gpu_get_viewport,    "getViewport():number,number"};
    c.methods["setViewport"]     = {true, gpu_set_viewport,    "setViewport(w:number,h:number)"};
    c.methods["maxDepth"]        = {true, gpu_max_depth,       "maxDepth():number"};
    c.methods["getDepth"]        = {true, gpu_get_depth,       "getDepth():number"};
    c.methods["setDepth"]        = {true, gpu_set_depth,       "setDepth(bits:number)"};
    c.methods["getBackground"]   = {true, gpu_get_background,  "getBackground():number,boolean"};
    c.methods["getForeground"]   = {true, gpu_get_foreground,  "getForeground():number,boolean"};
    c.methods["setBackground"]   = {true, gpu_set_background,  "setBackground(v:number)"};
    c.methods["setForeground"]   = {true, gpu_set_foreground,  "setForeground(v:number)"};
    c.methods["getPaletteColor"] = {true, gpu_get_palette_color, "getPaletteColor(i:number)"};
    c.methods["setPaletteColor"] = {true, gpu_set_palette_color, "setPaletteColor(i:number,v)"};
    c.methods["get"]             = {true, gpu_get,             "get(x:number,y:number)"};
    c.methods["set"]             = {true, gpu_set,             "set(x:number,y:number,value)"};
    c.methods["fill"]            = {true, gpu_fill,            "fill(x,y,w,h,char:string)"};
    c.methods["copy"]            = {true, gpu_copy,            "copy(x,y,w,h,tx,ty)"};
    return c;
}

inline int screen_is_on(machine_t &, component_t &c, lua_State *L) {
    lua_pushboolean(L, c.screen && c.screen->on);
    return 1;
}

inline int screen_turn_on(machine_t &, component_t &c, lua_State *L) {
    bool was = c.screen && c.screen->on;
    if (c.screen)
        c.screen->on = true;
    lua_pushboolean(L, !was);
    return 1;
}

inline int screen_turn_off(machine_t &, component_t &c, lua_State *L) {
    bool was = c.screen && c.screen->on;
    if (c.screen)
        c.screen->on = false;
    lua_pushboolean(L, was);
    return 1;
}

inline int screen_aspect_ratio(machine_t &, component_t &, lua_State *L) {
    lua_pushinteger(L, 1);
    lua_pushinteger(L, 1);
    return 2;
}

/*! The keyboards attached to this screen.
 *
 * This is the whole of how typing reaches a program: OpenOS asks a screen which keyboards belong to
 * it, and only accepts `key_down` signals whose first value is one of them. A screen with no
 * keyboard is a display and nothing more, which is exactly how it behaves in the game.
 * @date 2026-09-17 */
inline int screen_get_keyboards(machine_t &m, component_t &c, lua_State *L) {
    lua_newtable(L);
    int i = 1;
    for (component_t &k : m.components)
        if (k.type == "keyboard" && k.bound_to == c.address) {
            lua_pushstring(L, k.address.c_str());
            lua_rawseti(L, -2, i++);
        }
    return 1;
}

inline int screen_is_precise(machine_t &, component_t &, lua_State *L) {
    lua_pushboolean(L, 0);
    return 1;
}

inline int screen_set_precise(machine_t &, component_t &, lua_State *L) {
    lua_pushboolean(L, 0);
    return 1;
}

/*! Builds a screen and the grid behind it. @date 2026-09-17 */
inline component_t make_screen(std::shared_ptr<ocsc::buffer_t> buf, uint64_t seed) {
    component_t c;
    c.address = make_address(seed);
    c.type = "screen";
    c.label = "Screen (Tier 3)";
    c.screen = buf;

    c.methods["isOn"]           = {true, screen_is_on,        "isOn():boolean"};
    c.methods["turnOn"]         = {true, screen_turn_on,      "turnOn():boolean"};
    c.methods["turnOff"]        = {true, screen_turn_off,     "turnOff():boolean"};
    c.methods["getAspectRatio"] = {true, screen_aspect_ratio, "getAspectRatio():number,number"};
    c.methods["getKeyboards"]   = {true, screen_get_keyboards, "getKeyboards():table"};
    c.methods["isPrecise"]      = {true, screen_is_precise,   "isPrecise():boolean"};
    c.methods["setPrecise"]     = {true, screen_set_precise,  "setPrecise(v:boolean):boolean"};
    return c;
}

/*! Builds a keyboard, attached to the screen it is bolted to.
 *
 * A keyboard has no methods of its own worth having - it exists to be named in a screen's
 * `getKeyboards` and to be the first value of a `key_down` signal. That is the whole of its part.
 * @date 2026-09-17 */
inline component_t make_keyboard(const std::string &screen_address, uint64_t seed) {
    component_t c;
    c.address = make_address(seed);
    c.type = "keyboard";
    c.label = "Keyboard";
    c.bound_to = screen_address;
    return c;
}

/* --- the transposer and the redstone block --------------------------------------------------- */

/*! The side argument, numbered the way OpenComputers' own `sides` library does.
 * @date 2026-09-17 */
inline int side_arg(lua_State *L, int i) {
    int v = (int)lua_tointeger(L, i);
    return (v >= 0 && v < 6) ? v : 0;
}

inline int rs_get_input(machine_t &, component_t &, lua_State *L) {
    /* Nothing in the world emits into a block yet, so what comes in is nothing. This answers
    honestly rather than inventing a level. */
    lua_pushinteger(L, 0);
    return 1;
}

inline int rs_get_output(machine_t &, component_t &c, lua_State *L) {
    lua_pushinteger(L, c.rs_output[side_arg(L, 3)]);
    return 1;
}

inline int rs_set_output(machine_t &, component_t &c, lua_State *L) {
    /* Two shapes are accepted, as the real component does: a side and a level, or a table of six
    levels at once. This repository's own hw_interface.lua uses the first. */
    if (lua_istable(L, 3)) {
        for (int i = 0; i < 6; i++) {
            lua_rawgeti(L, 3, i);
            if (lua_isnumber(L, -1))
                c.rs_output[i] = (int)lua_tointeger(L, -1);
            lua_pop(L, 1);
        }
        lua_pushboolean(L, 1);
        return 1;
    }

    int side = side_arg(L, 3);
    int was = c.rs_output[side];
    c.rs_output[side] = (int)lua_tointeger(L, 4);
    lua_pushinteger(L, was);
    return 1;
}

/*! Builds the redstone I/O block's component. @date 2026-09-17 */
inline component_t make_redstone(uint64_t seed) {
    component_t c;
    c.address = make_address(seed);
    c.type = "redstone";
    c.label = "Redstone I/O";
    c.methods["getInput"]  = {true, rs_get_input,  "getInput(side:number):number"};
    c.methods["getOutput"] = {true, rs_get_output, "getOutput(side:number):number"};
    c.methods["setOutput"] = {true, rs_set_output, "setOutput(side:number,value:number)"};
    return c;
}

/*! A transposer's methods, answering for the inventories beside it.
 *
 * Registered so a program can SEE the transposer and ask what it can do - which is what
 * `components` lists and what `component.methods` reports. Moving items is not here yet: an
 * inventory is script-layer state today, and reaching it from a component means the item model
 * moving into C++ first. Each of these says so plainly rather than pretending to succeed, because
 * a transfer that silently does nothing is far worse to debug than one that refuses.
 * @date 2026-09-17 */
inline int tr_unimplemented(machine_t &, component_t &, lua_State *L) {
    lua_pushnil(L);
    lua_pushstring(L, "the simulator has no item model yet");
    return 2;
}

inline int tr_inventory_size(machine_t &, component_t &, lua_State *L) {
    lua_pushnil(L);
    lua_pushstring(L, "no inventory");
    return 2;
}

inline component_t make_transposer(uint64_t seed) {
    component_t c;
    c.address = make_address(seed);
    c.type = "transposer";
    c.label = "Transposer";
    c.methods["getInventorySize"] = {true, tr_inventory_size,
            "getInventorySize(side:number):number"};
    c.methods["getInventoryName"] = {true, tr_inventory_size,
            "getInventoryName(side:number):string"};
    c.methods["getStackInSlot"]   = {true, tr_unimplemented,
            "getStackInSlot(side:number,slot:number):table"};
    c.methods["getAllStacks"]     = {true, tr_unimplemented,
            "getAllStacks(side:number):table"};
    c.methods["transferItem"]     = {true, tr_unimplemented,
            "transferItem(source:number,sink:number[,count[,sourceSlot[,sinkSlot]]])"};
    c.methods["getTankLevel"]     = {true, tr_unimplemented,
            "getTankLevel(side:number[,tank:number]):number"};
    c.methods["transferFluid"]    = {true, tr_unimplemented,
            "transferFluid(source:number,sink:number[,count]):boolean"};
    return c;
}

/* --- the computer itself, as a component ----------------------------------------------------- */

/*! The computer block is a component too, and it has to be, because `computer.beep` is not a host
 * function at all - machine.lua defines it as `component.invoke(computer.address(), "beep")`.
 *
 * bios.lua beeps on its way out of the boot, so a machine with no computer component fails at the
 * very last line of a successful boot with "no such component", which is a confusing way to be
 * told that a block is missing from its own machine. That was exactly the symptom.
 * @date 2026-09-16 */
inline int computer_beep(machine_t &, component_t &, lua_State *) { return 0; }

inline int computer_is_running(machine_t &m, component_t &, lua_State *L) {
    lua_pushboolean(L, m.running());
    return 1;
}

inline int computer_start(machine_t &, component_t &, lua_State *L) {
    lua_pushboolean(L, 0);      /* already running, which is the only way this can be called */
    return 1;
}

inline int computer_stop(machine_t &m, component_t &, lua_State *L) {
    m.status = MACHINE_OFF;
    lua_pushboolean(L, 1);
    return 1;
}

/*! What the machine is made of, as OpenOS's own tools report it. An empty table is a valid answer -
 * nothing in the boot path branches on the contents. @date 2026-09-16 */
inline int computer_device_info(machine_t &, component_t &, lua_State *L) {
    lua_newtable(L);
    return 1;
}

/*! Where OpenOS may look for programs it does not have. Empty, since there is no internet card and
 * no loot beyond what is already on the disks. @date 2026-09-16 */
inline int computer_program_locations(machine_t &, component_t &, lua_State *L) {
    lua_newtable(L);
    return 1;
}

/*! Builds the component that stands for the computer block itself.
 *
 * Its address is the machine's own, because that is what machine.lua invokes against.
 * @date 2026-09-16 */
inline component_t make_computer(const std::string &address) {
    component_t c;
    c.address = address;
    c.type = "computer";
    c.label = "Computer";
    c.methods["beep"]  = {true, computer_beep,      "beep([frequency:number[,duration:number]])"};
    c.methods["start"] = {true, computer_start,     "start():boolean"};
    c.methods["stop"]  = {true, computer_stop,      "stop():boolean"};
    c.methods["isRunning"] = {true, computer_is_running, "isRunning():boolean"};
    c.methods["getDeviceInfo"] = {true, computer_device_info, "getDeviceInfo():table"};
    c.methods["getProgramLocations"] = {true, computer_program_locations,
            "getProgramLocations():table"};
    return c;
}

/*! Builds the EEPROM every machine boots from, holding the mod's own BIOS. @date 2026-09-16 */
inline component_t make_eeprom(const std::string &bios, uint64_t seed) {
    component_t c;
    c.address = make_address(seed);
    c.type = "eeprom";
    c.label = "EEPROM (Lua BIOS)";
    c.code = bios;
    c.methods["get"]         = {true, eeprom_get,          "get():string -- the code"};
    c.methods["set"]         = {true, eeprom_set,          "set(data:string) -- replace the code"};
    c.methods["getData"]     = {true, eeprom_get_data,     "getData():string"};
    c.methods["setData"]     = {true, eeprom_set_data,     "setData(data:string)"};
    c.methods["getLabel"]    = {true, eeprom_get_label,    "getLabel():string"};
    c.methods["setLabel"]    = {true, eeprom_set_label,    "setLabel(v:string):string"};
    c.methods["getSize"]     = {true, eeprom_get_size,     "getSize():number"};
    c.methods["getDataSize"] = {true, eeprom_get_data_size, "getDataSize():number"};
    return c;
}

/* --- building the guest state ---------------------------------------------------------------- */

/*! Puts the four host tables into a fresh guest state.
 *
 * These are globals rather than a module, because machine.lua expects to find them that way - it
 * reads `component.list`, `computer.realTime` and the rest straight off the global table before it
 * builds its sandbox, and the sandbox it builds deliberately does not include them.
 * @date 2026-09-16 */
inline void install_host(lua_State *L, machine_t *m) {
    lua_newtable(L);
    put(L, m, "list", l_component_list);
    put(L, m, "type", l_component_type);
    put(L, m, "slot", l_component_slot);
    put(L, m, "methods", l_component_methods);
    put(L, m, "doc", l_component_doc);
    put(L, m, "invoke", l_component_invoke);
    lua_setglobal(L, "component");

    lua_newtable(L);
    put(L, m, "address", l_computer_address);
    put(L, m, "tmpAddress", l_computer_tmp_address);
    put(L, m, "uptime", l_computer_uptime);
    put(L, m, "realTime", l_computer_real_time);
    put(L, m, "totalMemory", l_computer_total_memory);
    put(L, m, "freeMemory", l_computer_free_memory);
    put(L, m, "energy", l_computer_energy);
    put(L, m, "maxEnergy", l_computer_max_energy);
    put(L, m, "isRobot", l_computer_is_robot);
    put(L, m, "users", l_computer_users);
    put(L, m, "addUser", l_computer_add_user);
    put(L, m, "removeUser", l_computer_remove_user);
    put(L, m, "pushSignal", l_computer_push_signal);
    put(L, m, "getArchitecture", l_computer_get_arch);
    put(L, m, "getArchitectures", l_computer_get_archs);
    put(L, m, "setArchitecture", l_computer_set_arch);
    put(L, m, "getBootAddress", l_computer_get_boot);
    put(L, m, "setBootAddress", l_computer_set_boot);
    lua_setglobal(L, "computer");

    lua_newtable(L);
    put(L, m, "len", l_unicode_len);
    put(L, m, "sub", l_unicode_sub);
    put(L, m, "char", l_unicode_char);
    put(L, m, "charWidth", l_unicode_char_width);
    put(L, m, "isWide", l_unicode_is_wide);
    put(L, m, "wlen", l_unicode_wlen);
    put(L, m, "wtrunc", l_unicode_wtrunc);
    put(L, m, "lower", l_unicode_lower);
    put(L, m, "upper", l_unicode_upper);
    put(L, m, "reverse", l_unicode_reverse);
    lua_setglobal(L, "unicode");

    lua_newtable(L);
    put(L, m, "allowBytecode", l_system_allow_bytecode);
    put(L, m, "allowGC", l_system_allow_gc);
    put(L, m, "timeout", l_system_timeout);
    lua_setglobal(L, "system");
}

/* --- starting and driving a machine ---------------------------------------------------------- */

/*! Clears a machine down and gives it a fresh EEPROM holding the mod's BIOS.
 *
 * The first of three steps. A boot is prepare, then attach whatever the world says is connected,
 * then start - which is the order the game itself implies: a computer is the sum of what is plugged
 * into it at the moment the button is pressed.
 * @date 2026-09-16 */
inline bool machine_prepare(machine_p mp, const char *mc_path) {
    if (!mp)
        return false;
    machine_t &m = *mp;

    m.shutdown();
    m.error.clear();
    m.output.clear();
    m.signals.clear();
    m.components.clear();
    m.sleeping = false;
    m.primary_screen = nullptr;
    m.mc_path = mc_path ? mc_path : "";

    mca::mc_source_t src;
    if (!src.open(m.mc_path)) {
        m.status = MACHINE_ERROR;
        m.error = "no OpenComputers jar - set the minecraft path in the settings";
        m.emit(m.error);
        return false;
    }

    std::string bios_src = oc_rom::bios_source(src);
    if (bios_src.empty()) {
        m.status = MACHINE_ERROR;
        m.error = "the OpenComputers jar has no bios.lua in it";
        m.emit(m.error);
        return false;
    }

    static uint64_t seed = 1000;
    m.components.push_back(make_computer(m.address));
    m.components.push_back(make_eeprom(bios_src, seed++));

    /* The scratch filesystem every computer has, and it must be a real component: OpenOS's
    boot/02_os.lua does `if computer.tmpAddress() then fs.mount(computer.tmpAddress(), "/tmp")`,
    so answering an address with nothing behind it sends it looking up a filesystem that is not in
    the component list - which fails deep inside its own library rather than anywhere near here.
    Rebuilt on every boot, because temporary is what it means. */
    {
        auto tmp = std::make_shared<ocfs::filesystem_t>();
        tmp->label = "tmpfs";
        tmp->capacity = 512 * 1024;
        component_t c = make_filesystem(tmp, seed++);
        c.address = m.tmp_address;
        m.components.push_back(c);
    }
    return true;
}

/*! Tells a running machine that a component has arrived or gone.
 *
 * A machine that is already running has to be TOLD, or it will never look again. OpenOS caches
 * what it has found - lib/tty.lua says so in as many words, "calling getKeyboards() on the screen
 * is costly" - and only looks afresh when a `component_added` or `component_removed` signal
 * arrives. Without this, anything plugged into a running computer does nothing until the next
 * reboot, which is not how it behaves in the game.
 *
 * Silent while the machine is off: there is nobody to tell, and the boot will find it anyway.
 * @date 2026-09-17 */
inline void announce(machine_t &m, const std::string &address, const char *type, bool added) {
    if (m.status != MACHINE_RUNNING)
        return;

    std::vector<sig_val_t> args;
    sig_val_t a;
    a.kind = sig_val_t::STR;
    a.s = address;
    args.push_back(a);
    a.s = type ? type : "";
    args.push_back(a);
    m.push_signal(added ? "component_added" : "component_removed", args);
}

/*! Detaches a component by address, telling the machine it has gone.
 *
 * Answers false when there was nothing at that address, which is the ordinary case for a caller
 * tidying up after something it is not sure it ever attached.
 * @date 2026-09-17 */
inline bool machine_remove_component(machine_p mp, const char *address) {
    if (!mp || !address)
        return false;
    machine_t &m = *mp;

    for (size_t i = 0; i < m.components.size(); i++) {
        if (m.components[i].address == address) {
            std::string type = m.components[i].type;
            /* The primary screen goes with its component, or the interface would go on reading a
            grid nothing is drawing into. */
            if (m.components[i].screen && m.components[i].screen == m.primary_screen)
                m.primary_screen = nullptr;
            m.components.erase(m.components.begin() + (ptrdiff_t)i);
            announce(m, address, type.c_str(), false);
            return true;
        }
    }
    return false;
}

/*! Attaches the machine's own hard disk - empty the first time, and whatever it has become after.
 *
 * Returns its address, so a caller can tell one filesystem from another.
 * @date 2026-09-16 */
inline std::string machine_add_hdd(machine_p mp, const char *label) {
    if (!mp)
        return {};
    machine_t &m = *mp;

    if (!m.hdd) {
        m.hdd = std::make_shared<ocfs::filesystem_t>();
        m.hdd->label = label ? label : "hdd";
    }
    static uint64_t seed = 2000;
    component_t c = make_filesystem(m.hdd, seed++);
    m.components.push_back(c);
    return c.address;
}

/*! Every file on the machine's hard disk, as paths.
 *
 * For saving it. The tree is walked depth first and the paths come back with no leading slash, the
 * way the filesystem component addresses them, so a path can be handed straight back to
 * machine_hdd_read and machine_hdd_write.
 *
 * Directories are not listed. They are implied by the paths of the files inside them, and an empty
 * one carries nothing worth keeping.
 * @date 2026-09-17 */
inline std::vector<std::string> machine_hdd_files(machine_p mp) {
    std::vector<std::string> out;
    if (!mp || !mp->hdd)
        return out;

    struct walker {
        static void go(const ocfs::node_t &n, const std::string &prefix,
                std::vector<std::string> &out) {
            for (const auto &kv : n.children) {
                std::string path = prefix.empty() ? kv.first : prefix + "/" + kv.first;
                if (kv.second.dir)
                    go(kv.second, path, out);
                else
                    out.push_back(path);
            }
        }
    };
    walker::go(mp->hdd->root, "", out);
    return out;
}

/*! One file off the hard disk. Empty for anything that is not there. @date 2026-09-17 */
inline std::string machine_hdd_read(machine_p mp, const char *path) {
    if (!mp || !mp->hdd || !path)
        return {};
    ocfs::node_t *n = mp->hdd->find(path);
    return (n && !n->dir) ? n->data : std::string();
}

/*! Puts one file onto the hard disk, making the directories above it.
 *
 * For loading a save back. The disk is created if the machine has not made one yet, so a world can
 * be restored before anything has been started.
 * @date 2026-09-17 */
inline bool machine_hdd_write(machine_p mp, const char *path, const char *data) {
    if (!mp || !path)
        return false;
    if (!mp->hdd) {
        mp->hdd = std::make_shared<ocfs::filesystem_t>();
        mp->hdd->label = "hdd";
    }
    return mp->hdd->write_file(path, data ? data : "");
}

/*! How many bytes the hard disk is holding. @date 2026-09-17 */
inline double machine_hdd_used(machine_p mp) {
    return (mp && mp->hdd) ? (double)mp->hdd->used() : 0.0;
}

/*! Attaches a read-only floppy, filled from a folder inside the OpenComputers jar.
 *
 * Core: this is how an operating system arrives. A disk drive in the world holds a floppy, the
 * floppy names a folder in the mod's own loot - "loot/openos" for OpenOS - and that folder's files
 * are copied into a fresh tree here. The BIOS then finds it like any other filesystem and boots it,
 * which is exactly how it happens in the game.
 *
 * Read-only, as a loot disk is. Putting the system onto the hard disk is what OpenOS's own
 * `install` does, and that needs the source to stay put while it copies.
 *
 * Params: `label` what the disk calls itself, `jar_folder` a path under assets/opencomputers.
 * Returns the address, or an empty string when nothing could be read.
 * @date 2026-09-16 */
inline std::string machine_add_floppy(machine_p mp, const char *label, const char *jar_folder) {
    if (!mp || !jar_folder)
        return {};
    machine_t &m = *mp;

    mca::mc_source_t src;
    if (!src.open(m.mc_path))
        return {};

    std::string prefix = std::string("assets/opencomputers/") + jar_folder;
    if (!prefix.empty() && prefix.back() != '/')
        prefix += "/";

    std::vector<std::string> entries = mca::zip_list(src.jar, prefix);
    if (entries.empty()) {
        m.emit(std::string("floppy is empty: nothing under ") + jar_folder);
        return {};
    }

    auto fs = std::make_shared<ocfs::filesystem_t>();
    fs->read_only = true;
    fs->label = label ? label : "floppy";

    for (const std::string &entry : entries) {
        std::vector<uint8_t> bytes = mca::zip_extract(src.jar, entry);
        fs->write_file(entry.substr(prefix.size()), std::string(bytes.begin(), bytes.end()));
    }
    fs->capacity = 512 * 1024;

    static uint64_t seed = 3000;
    component_t c = make_filesystem(fs, seed++);
    m.components.push_back(c);
    announce(m, c.address, "filesystem", true);
    m.emit("inserted " + fs->label + " (" + std::to_string(entries.size()) + " files)");
    return c.address;
}

/*! Attaches a screen and the graphics card that drives it.
 *
 * Both at once, because one without the other is useless: a screen with no gpu is never written to,
 * and a gpu with no screen has nothing to write on. bios.lua binds the two itself on the way up -
 * it looks for the first of each and calls `bind` - so nothing here has to.
 *
 * Returns the screen's address.
 * @date 2026-09-17 */
inline std::string machine_add_screen(machine_p mp) {
    if (!mp)
        return {};
    machine_t &m = *mp;

    auto buf = std::make_shared<ocsc::buffer_t>();
    static uint64_t seed = 4000;
    component_t screen = make_screen(buf, seed++);
    m.components.push_back(screen);
    m.components.push_back(make_gpu(seed++));

    if (!m.primary_screen)
        m.primary_screen = buf;
    announce(m, screen.address, "screen", true);
    announce(m, m.components.back().address, "gpu", true);
    return screen.address;
}

/*! Attaches a keyboard to a screen that is already on the machine.
 *
 * A keyboard belongs to a screen rather than to the computer - that is what `screen.getKeyboards`
 * answers and what decides whose typing a program sees.
 * @date 2026-09-17 */
inline std::string machine_add_keyboard(machine_p mp, const char *screen_address) {
    if (!mp || !screen_address)
        return {};
    machine_t &m = *mp;

    static uint64_t seed = 5000;
    component_t kb = make_keyboard(screen_address, seed++);
    m.components.push_back(kb);

    announce(m, kb.address, "keyboard", true);
    return kb.address;
}

/*! Queues a key going down or coming back up, as OpenComputers shapes the signal.
 *
 * `key_down` and `key_up` both carry the keyboard's address, the character, the key code and who
 * typed it. OpenOS checks that first value against the screen's keyboards, which is why a keyboard
 * has to exist as a component before any of this reaches a program.
 *
 * BOTH DIRECTIONS MATTER, and not only for tidiness. OpenOS keeps a set of currently pressed codes
 * and answers `keyboard.isControlDown()` out of it, so a control key that goes down and never comes
 * up is held forever; and a key that never goes down at all means control combinations can never be
 * recognised. That is what stopped `lua` being exited with ctrl+d.
 *
 * Params: `ch` the character's code point, zero for a key that produces none; `code` the key code,
 * which is what a program compares against `keyboard.keys.*`; `down` false for a release.
 * @date 2026-09-17 */
inline bool machine_key(machine_p mp, const char *kb_address, double ch, double code, bool down) {
    if (!mp || !kb_address)
        return false;

    std::vector<sig_val_t> args;
    sig_val_t a;
    a.kind = sig_val_t::STR;
    a.s = kb_address;
    args.push_back(a);

    sig_val_t v;
    v.kind = sig_val_t::NUM;
    v.n = ch;
    args.push_back(v);
    v.n = code;
    args.push_back(v);

    sig_val_t who;
    who.kind = sig_val_t::STR;
    who.s = "player";
    args.push_back(who);

    return mp->push_signal(down ? "key_down" : "key_up", args);
}

/*! Attaches a transposer to the machine. Returns its address. @date 2026-09-17 */
inline std::string machine_add_transposer(machine_p mp) {
    if (!mp)
        return {};
    static uint64_t seed = 6000;
    component_t c = make_transposer(seed++);
    mp->components.push_back(c);
    announce(*mp, c.address, "transposer", true);
    return c.address;
}

/*! Attaches a redstone I/O block to the machine. Returns its address. @date 2026-09-17 */
inline std::string machine_add_redstone(machine_p mp) {
    if (!mp)
        return {};
    static uint64_t seed = 7000;
    component_t c = make_redstone(seed++);
    mp->components.push_back(c);
    announce(*mp, c.address, "redstone", true);
    return c.address;
}

/*! The level a redstone component is emitting on one side, by address. Lua reads this to light a
 * lamp or drive a wire. Answers zero for anything that is not a redstone block. @date 2026-09-17 */
inline int machine_redstone_output(machine_p mp, const char *address, int side) {
    if (!mp || !address || side < 0 || side > 5)
        return 0;
    component_t *c = mp->find(address);
    return (c && c->type == "redstone") ? c->rs_output[side] : 0;
}

/*! Builds the guest state and starts machine.lua running.
 *
 * Whatever was attached before this call is what the machine sees. Attaching afterwards does
 * nothing until the next boot - which is also true of pushing a disk into a running computer.
 * @date 2026-09-16 */
inline bool machine_boot(machine_p mp) {
    if (!mp)
        return false;
    machine_t &m = *mp;

    if (m.components.empty()) {
        m.status = MACHINE_ERROR;
        m.error = "nothing is installed in this computer";
        m.emit(m.error);
        return false;
    }

    mca::mc_source_t src;
    if (!src.open(m.mc_path)) {
        m.status = MACHINE_ERROR;
        m.error = "no OpenComputers jar - set the minecraft path in the settings";
        m.emit(m.error);
        return false;
    }

    std::string machine_src = oc_rom::machine_source(src);
    if (machine_src.empty()) {
        m.status = MACHINE_ERROR;
        m.error = "the OpenComputers jar has no machine.lua in it";
        m.emit(m.error);
        return false;
    }

    m.boot_time = host_clock();
    m.now = m.boot_time;

    m.L = luaL_newstate();
    if (!m.L) {
        m.status = MACHINE_ERROR;
        m.error = "out of memory starting the machine";
        m.emit(m.error);
        return false;
    }
    /* The guest gets the standard library because machine.lua's sandbox is built by picking from
    it - the sandbox is what the guest's own code eventually sees, not this. */
    luaL_openlibs(m.L);
    install_host(m.L, &m);

    if (luaL_loadbuffer(m.L, machine_src.data(), machine_src.size(), "=machine") != LUA_OK) {
        m.error = std::string("machine.lua would not load: ") + lua_tostring(m.L, -1);
        m.emit(m.error);
        m.shutdown();
        m.status = MACHINE_ERROR;
        return false;
    }

    /* The chunk becomes a coroutine, and the reference keeps it from being collected while the
    only other thing pointing at it is a C++ pointer the guest cannot see. */
    m.co = lua_newthread(m.L);
    m.co_ref = luaL_ref(m.L, LUA_REGISTRYINDEX);
    lua_xmove(m.L, m.co, 1);

    m.status = MACHINE_RUNNING;
    m.emit("machine started");
    return true;
}

/*! Stops a machine and releases its state. @date 2026-09-16 */
inline void machine_stop(machine_p mp) {
    if (!mp)
        return;
    mp->shutdown();
    mp->status = MACHINE_OFF;
    mp->emit("machine stopped");
}

/*! Moves the machine forward by up to one frame's worth of work.
 *
 * Core: this is the yield protocol, and nothing else. Resume the coroutine, look at the first value
 * it yielded, act on it, resume again - until the budget runs out, the machine asks to wait, or it
 * stops. Everything the guest does between two of those yields is its own business.
 *
 * A machine that is waiting is not resumed at all until its deadline passes or a signal arrives,
 * which is what keeps an idle computer free rather than merely cheap.
 *
 * @date 2026-09-16 */
inline void machine_step(machine_p mp) {
    if (!mp || !mp->co || mp->status != MACHINE_RUNNING)
        return;
    machine_t &m = *mp;
    double now = host_clock();
    m.now = now;

    for (int budget = 0; budget < m.budget_per_step; budget++) {
        if (m.sleeping) {
            if (m.signals.empty() && now < m.wake_at)
                return;
            m.sleeping = false;

            /* What the guest gets back from `coroutine.yield` inside pullSignal: the signal's name
            and its values, or nothing at all when the wait simply expired. */
            if (!m.signals.empty()) {
                signal_t sig = m.signals.front();
                m.signals.pop_front();
                lua_pushstring(m.co, sig.name.c_str());
                for (const sig_val_t &v : sig.args) {
                    switch (v.kind) {
                        case sig_val_t::BOOL: lua_pushboolean(m.co, v.b); break;
                        case sig_val_t::NUM:  lua_pushnumber(m.co, v.n); break;
                        case sig_val_t::STR:  lua_pushstring(m.co, v.s.c_str()); break;
                        default:              lua_pushnil(m.co); break;
                    }
                }
                m.resume_args = 1 + (int)sig.args.size();
            }
            else {
                m.resume_args = 0;
            }
        }

        int nres = 0;
        int rc = lua_resume(m.co, nullptr, m.resume_args, &nres);
        m.resume_args = 0;

        if (rc != LUA_OK && rc != LUA_YIELD) {
            const char *msg = lua_tostring(m.co, -1);
            m.error = msg ? msg : "the machine faulted";
            m.emit(m.error);
            m.status = MACHINE_ERROR;
            m.shutdown();
            m.status = MACHINE_ERROR;
            return;
        }

        if (rc == LUA_OK) {
            /* machine.lua's main() never returns while the computer is up; reaching here means it
            fell out, and whatever it answered is the reason. */
            if (nres >= 2 && lua_isstring(m.co, -1))
                m.error = lua_tostring(m.co, -1);
            if (!m.error.empty())
                m.emit(m.error);
            m.emit("machine halted");
            m.status = m.error.empty() ? MACHINE_OFF : MACHINE_ERROR;
            int keep = m.status;
            m.shutdown();
            m.status = keep;
            return;
        }

        /* A yield. The first value is the whole of what the host is being told. */
        if (nres == 0) {
            lua_settop(m.co, 0);
            continue;
        }

        int type = lua_type(m.co, 1);

        if (type == LUA_TNUMBER) {
            double secs = lua_tonumber(m.co, 1);
            lua_settop(m.co, 0);
            m.sleeping = true;
            /* math.huge means "until something happens", which the deadline expresses as never. */
            m.wake_at = (secs > 1e18) ? 1e30 : now + secs;
            continue;
        }

        if (type == LUA_TBOOLEAN) {
            bool reboot = lua_toboolean(m.co, 1);
            lua_settop(m.co, 0);
            if (reboot) {
                m.emit("machine rebooting");
                m.status = MACHINE_OFF;
                return;             /* the caller starts it again; a reboot is a fresh state */
            }
            m.emit("machine shut down");
            m.shutdown();
            m.status = MACHINE_OFF;
            return;
        }

        if (type == LUA_TFUNCTION) {
            /* An indirect component call. The closure is run on the main thread rather than on the
            suspended coroutine's own stack, and whatever it answers is handed back in. */
            lua_xmove(m.co, m.L, 1);
            lua_settop(m.co, 0);
            if (lua_pcall(m.L, 0, 1, 0) != LUA_OK) {
                const char *msg = lua_tostring(m.L, -1);
                m.error = msg ? msg : "a component call faulted";
                m.emit(m.error);
                lua_settop(m.L, 0);
                m.status = MACHINE_ERROR;
                m.shutdown();
                m.status = MACHINE_ERROR;
                return;
            }
            lua_xmove(m.L, m.co, 1);
            m.resume_args = 1;
            continue;
        }

        /* Anything else is the sandbox bubbling a user yield up; nothing is owed in reply. */
        lua_settop(m.co, 0);
    }

    /* The budget ran out with the machine still willing to run. It resumes next frame. */
}

/* --- the Lua boundary ----------------------------------------------------------------------- */

inline machine_p machine_create() {
    return machine_t::create();
}

/*! Queues a signal from the simulator's own scripts - the event injection the project exists for.
 * @date 2026-09-16 */
inline bool machine_signal(machine_p mp, const char *name, const char *arg) {
    return mp ? mp->signal_str(name, arg) : false;
}

inline int register_meta(vc::virt_state_t *vs) {
    DBG_SCOPE();

    VC_REGISTER_MEMBER_FUNCTION(vs, machine_t, get_status);
    VC_REGISTER_MEMBER_FUNCTION(vs, machine_t, get_error);
    VC_REGISTER_MEMBER_FUNCTION(vs, machine_t, get_address);
    VC_REGISTER_MEMBER_FUNCTION(vs, machine_t, running);
    VC_REGISTER_MEMBER_FUNCTION(vs, machine_t, output_len);
    VC_REGISTER_MEMBER_FUNCTION(vs, machine_t, idle);
    VC_REGISTER_MEMBER_FUNCTION(vs, machine_t, component_count);
    VC_REGISTER_MEMBER_FUNCTION(vs, machine_t, has_screen);
    VC_REGISTER_MEMBER_FUNCTION(vs, machine_t, screen_size);
    VC_REGISTER_MEMBER_FUNCTION(vs, machine_t, screen_row, int);
    VC_REGISTER_MEMBER_FUNCTION(vs, machine_t, screen_cursor);
    VC_REGISTER_MEMBER_FUNCTION(vs, machine_t, screen_row_runs, int);
    VC_REGISTER_MEMBER_FUNCTION(vs, machine_t, output_at, int);

    std::vector<luaL_Reg> machine_tab_funcs = {
        {"machine_create", vc::luaw_function_wrapper<
               /* FN:    */ machc::machine_create
        >},
        {"machine_prepare", vc::luaw_function_wrapper<
               /* FN:    */ machc::machine_prepare,
               /* PARAMS:*/ machine_p, const char *
        >},
        {"machine_add_hdd", vc::luaw_function_wrapper<
               /* FN:    */ machc::machine_add_hdd,
               /* PARAMS:*/ machine_p, const char *
        >},
        {"machine_hdd_files", vc::luaw_function_wrapper<
               /* FN:    */ machc::machine_hdd_files,
               /* PARAMS:*/ machine_p
        >},
        {"machine_hdd_read", vc::luaw_function_wrapper<
               /* FN:    */ machc::machine_hdd_read,
               /* PARAMS:*/ machine_p, const char *
        >},
        {"machine_hdd_write", vc::luaw_function_wrapper<
               /* FN:    */ machc::machine_hdd_write,
               /* PARAMS:*/ machine_p, const char *, const char *
        >},
        {"machine_hdd_used", vc::luaw_function_wrapper<
               /* FN:    */ machc::machine_hdd_used,
               /* PARAMS:*/ machine_p
        >},
        {"machine_add_floppy", vc::luaw_function_wrapper<
               /* FN:    */ machc::machine_add_floppy,
               /* PARAMS:*/ machine_p, const char *, const char *
        >},
        {"machine_add_screen", vc::luaw_function_wrapper<
               /* FN:    */ machc::machine_add_screen,
               /* PARAMS:*/ machine_p
        >},
        {"machine_remove_component", vc::luaw_function_wrapper<
               /* FN:    */ machc::machine_remove_component,
               /* PARAMS:*/ machine_p, const char *
        >},
        {"machine_add_transposer", vc::luaw_function_wrapper<
               /* FN:    */ machc::machine_add_transposer,
               /* PARAMS:*/ machine_p
        >},
        {"machine_add_redstone", vc::luaw_function_wrapper<
               /* FN:    */ machc::machine_add_redstone,
               /* PARAMS:*/ machine_p
        >},
        {"machine_redstone_output", vc::luaw_function_wrapper<
               /* FN:    */ machc::machine_redstone_output,
               /* PARAMS:*/ machine_p, const char *, int
        >},
        {"machine_add_keyboard", vc::luaw_function_wrapper<
               /* FN:    */ machc::machine_add_keyboard,
               /* PARAMS:*/ machine_p, const char *
        >},
        {"machine_key", vc::luaw_function_wrapper<
               /* FN:    */ machc::machine_key,
               /* PARAMS:*/ machine_p, const char *, double, double, bool
        >},
        {"machine_boot", vc::luaw_function_wrapper<
               /* FN:    */ machc::machine_boot,
               /* PARAMS:*/ machine_p
        >},
        {"machine_stop", vc::luaw_function_wrapper<
               /* FN:    */ machc::machine_stop,
               /* PARAMS:*/ machine_p
        >},
        {"machine_step", vc::luaw_function_wrapper<
               /* FN:    */ machc::machine_step,
               /* PARAMS:*/ machine_p
        >},
        {"machine_signal", vc::luaw_function_wrapper<
               /* FN:    */ machc::machine_signal,
               /* PARAMS:*/ machine_p, const char *, const char *
        >},
    };

    ASSERT_FN(add_lua_tab_funcs(vs, machine_tab_funcs));
    return vc::VC_ERROR_OK;
}

} /* namespace machine_composer */

#endif /* MACHINE_COMPOSER_H */
