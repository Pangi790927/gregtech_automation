/*! term.h - the terminal: a connector that opens a "terminal" zone on a computer, shows its
 * screen in a console window, and types into it.
 *
 * On connecting, the relay says which computers there are. With exactly one, the terminal
 * attaches at once; with several, it lists their addresses and a number key picks one. Attached,
 * it opens the zone running term.lua, the payload beside term.exe: first by its hash alone, and
 * with the code only when the computer's cache does not have it. Then the window is that zone's
 * screen and every key goes to it, Ctrl+C and Ctrl+Alt+C included; the zone keeps them from
 * octerm itself. Ctrl+D is the terminal's own: it disconnects, which ends the zone.
 *
 * Two commands use the same connection without a window: `term.exe zones` lists the zones open on
 * the computer, and `term.exe kill <name>` terminates one.
 *
 * Needs colib.h included first.
 *
 * @date 2026-09-30 */

#pragma once

#include <cstdio>
#include <string>
#include <vector>

#include "keys.h"
#include "net.h"
#include "protocol.h"
#include "screen.h"
#include "winconsole.h"

enum class term_state { choosing, attaching, opening, running };

struct term_t {
    sender_p out;
    term_state state = term_state::choosing;
    std::string addr;                   /*!< the computer attached to */
    std::vector<std::string> list;      /*!< the computers the relay last listed */
    std::string code, hash;             /*!< term.lua, and the hash it is cached under */
    std::string command;                /*!< "" for the terminal, or "zones" / "kill" */
    std::string argument;               /*!< the zone `kill` terminates */
    std::string prefix;                 /*!< a command's computer, by the start of its address */
    screen_t screen;
    int win_w = 0, win_h = 0;           /*!< the console window's size, last told to the zone */
    std::string zone_buf;               /*!< the zone's bytes that are not a whole frame yet */
    std::string goodbye;                /*!< why the terminal ended, said after the window */
};
inline term_t term;

inline void term_title() {
    std::string t = "terminal - choosing a computer";
    if (term.state == term_state::running)
        t = "terminal - " + term.addr + ", " + std::to_string(term.screen.w) + "x"
          + std::to_string(term.screen.h);
    SetConsoleTitleA((t + "   (Ctrl+D disconnects)").c_str());
}

/*! Draws the list of computers in place of a screen. */
inline void show_list() {
    std::string page = "\x1b[0m\x1b[2J\x1b[H";
    if (term.list.empty()) {
        page += "No computer is connected to the relay. Run octerm on one.\r\n";
    } else {
        page += "Computers connected to the relay; press a number to use one:\r\n\r\n";
        for (size_t i = 0; i < term.list.size() && i < 9; i++)
            page += "  " + std::to_string(i + 1) + ")  " + term.list[i] + "\r\n";
    }
    page += "\r\nCtrl+D disconnects.";
    con_write(page);
    term_title();
}

inline void attach(const std::string &addr) {
    term.state = term_state::attaching;
    term.addr = addr;
    post(term.out, enc_attach(addr));
}

/*! Picks the computer a command runs on: the only one, or the one its prefix names. */
inline void choose_for_command() {
    std::vector<std::string> hits;
    for (const std::string &a : term.list)
        if (a.rfind(term.prefix, 0) == 0)
            hits.push_back(a);
    if (hits.size() == 1) {
        attach(hits[0]);
        return;
    }
    term.goodbye = hits.empty() ? "no computer matches" : "several computers match; give the "
                   "start of an address:";
    for (const std::string &a : term.list)
        term.goodbye += "\n  " + a;
}

/*! Takes a list from the relay; returns false while it has not all arrived. */
inline bool take_list(reader_t &r) {
    reader_t start = r;
    r.u(1);
    if (!r.has(1)) {
        r = start;
        return false;
    }
    std::vector<std::string> list(r.u(1));
    for (std::string &a : list)
        if (!r.str(a)) {
            r = start;
            return false;
        }
    term.list = list;
    if (term.state == term_state::attaching)
        return true;        /* the answer to the attach is on its way; a second would be data */
    if (!term.command.empty())
        choose_for_command();
    else if (list.size() == 1)
        attach(list[0]);
    else
        show_list();
    return true;
}

/*! Starts the channel's conversation once attached: the command, or opening the zone from the
 * computer's cache. */
inline void attached() {
    term.state = term_state::opening;
    if (term.command == "zones")
        post(term.out, enc_zones_ask());
    else if (term.command == "kill")
        post(term.out, enc_terminate(term.argument));
    else
        post(term.out, enc_open("terminal", term.hash, nullptr));
}

/*! Takes the loader's answer to opening the zone. Returns false when it failed. */
inline bool take_opened(int status, const std::string &msg) {
    if (status == 1) {
        post(term.out, enc_open("terminal", term.hash, &term.code));    /* a cache miss */
        return true;
    }
    if (status != 0) {
        term.goodbye = "the computer could not open the terminal: " + msg;
        return false;
    }
    term.state = term_state::running;
    term_title();
    post(term.out, enc_zone_data(enc_window(term.win_w, term.win_h)));
    return true;
}

/*! Draws what changed, within the window: never below or right of it. */
inline void draw() {
    con_write(term.screen.render(term.win_w, term.win_h));
}

/*! Notices the window being resized: the zone is told, so the computer's screen follows it, and
 * everything is drawn again. term.lua waits for the first size before its shell starts, so
 * OpenOS lays out its banner at the right width. */
inline colib::task_t watch_window() {
    while (true) {
        int w, h;
        if (con_size(w, h) && (w != term.win_w || h != term.win_h)) {
            term.win_w = w;
            term.win_h = h;
            if (term.state == term_state::running)
                post(term.out, enc_zone_data(enc_window(w, h)));
            term.screen.redraw();
            draw();
        }
        co_await colib::sleep_ms(300);
    }
    co_return 0;
}

/*! Applies the terminal zone's bytes: screen frames, which may arrive cut anywhere. */
inline bool take_zone_bytes(const std::string &bytes) {
    term.zone_buf += bytes;
    const uint8_t *begin = reinterpret_cast<const uint8_t *>(term.zone_buf.data());
    reader_t r = {begin, begin + term.zone_buf.size()};
    int w = term.screen.w, h = term.screen.h, rc;
    while ((rc = apply_frame(term.screen, r)) == 1) {}
    term.zone_buf.erase(0, size_t(r.p - begin));
    draw();
    if (w != term.screen.w || h != term.screen.h)
        term_title();
    if (rc == -1)
        term.goodbye = "the terminal zone sent something that is not a screen frame";
    return rc != -1;
}

/*! Takes one frame of the channel, the loader's side of it. Returns 0 when it has not all
 * arrived, 1 when handled, and -1 when the terminal is to end. */
inline int take_channel_frame(reader_t &r) {
    reader_t start = r;
    char type = char(r.u(1));
    if (type == 'P') {
        std::string msg;
        if (!r.has(2)) {
            r = start;
            return 0;
        }
        int status = int(r.u(1));
        r.u(1);                                                 /* from the cache or not */
        if (!r.str(msg, 2)) {
            r = start;
            return 0;
        }
        return take_opened(status, msg) ? 1 : -1;
    }
    std::string text;
    if (type == 'd' || type == 'x') {
        if (!r.str(text, 2)) {
            r = start;
            return 0;
        }
        if (type == 'd')
            return take_zone_bytes(text) ? 1 : -1;
        term.goodbye = "the terminal zone ended: " + text;
        return -1;
    }
    if (type == 'z') {
        if (!r.has(1)) {
            r = start;
            return 0;
        }
        std::vector<std::string> names(r.u(1));
        for (std::string &n : names)
            if (!r.str(n)) {
                r = start;
                return 0;
            }
        term.goodbye = "zones on " + term.addr + ":";
        for (const std::string &n : names)
            term.goodbye += " " + n;
        if (names.empty())
            term.goodbye += " none";
        return -1;
    }
    term.goodbye = "the computer sent something that is not a frame";
    return -1;
}

/*! Handles the relay's whole frames at the front of `buf` and drops them. Returns false when the
 * terminal is to end, with the reason in term.goodbye. */
inline bool take_relay_bytes(std::string &buf) {
    const uint8_t *begin = reinterpret_cast<const uint8_t *>(buf.data());
    reader_t r = {begin, begin + buf.size()};
    bool ok = true;
    while (ok && r.has(1)) {
        if (term.state == term_state::choosing || term.state == term_state::attaching) {
            if (*r.p == 'L') {
                if (!take_list(r))
                    break;
            } else if (*r.p == 'Y' && term.state == term_state::attaching) {
                r.u(1);
                attached();
            } else if (*r.p == 'N' && term.state == term_state::attaching) {
                r.u(1);                 /* that computer left; the list that follows decides */
                term.state = term_state::choosing;
            } else {
                term.goodbye = "the relay sent something that is not a frame";
                ok = false;
            }
            ok = ok && term.goodbye.empty();
            continue;
        }
        int rc = take_channel_frame(r);
        if (rc == 0)
            break;
        ok = rc == 1;
    }
    buf.erase(0, size_t(r.p - begin));
    return ok;
}

inline colib::task_t relay_session(SOCKET s) {
    std::string buf;
    std::vector<char> chunk(16384);
    while (true) {
        SSIZE_T n = co_await colib::read((HANDLE)s, chunk.data(), chunk.size());
        if (n <= 0) {
            if (term.goodbye.empty())
                term.goodbye = term.state == term_state::running
                    ? "the computer or the relay went away" : "the relay closed the connection";
            break;
        }
        buf.append(chunk.data(), size_t(n));
        if (!take_relay_bytes(buf))
            break;
    }
    co_await colib::force_stop(0);
    co_return 0;
}

/*! Reads the console window: keys go to the zone once it runs, a number picks a computer before,
 * and Ctrl+D ends the terminal. */
inline colib::task_t term_input() {
    key_decoder_t decoder;
    char chunk[256];
    while (true) {
        SSIZE_T n = co_await colib::read(con.in, chunk, sizeof(chunk));
        if (n < 0)
            break;
        std::vector<oc_key_t> keys = decoder.feed(chunk, size_t(n));
        if (decoder.quit) {
            term.goodbye = "disconnected; the terminal zone has ended";
            break;
        }
        if (term.state == term_state::running) {
            std::string frames;
            for (const oc_key_t &k : keys)
                frames += key_frame(k);
            if (!frames.empty())
                post(term.out, enc_zone_data(frames));
        } else if (term.state == term_state::choosing) {
            for (const oc_key_t &k : keys)
                if (k.down && k.ch >= '1' && k.ch <= '9' && size_t(k.ch - '1') < term.list.size())
                    attach(term.list[k.ch - '1']);
        }
    }
    co_await colib::force_stop(0);
    co_return 0;
}
