/*! term.h - the terminal: a connector that opens a "terminal" zone on a computer, shows its
 * screen in a console window, and types into it.
 *
 * On connecting, the relay says which computers there are. With exactly one, the terminal
 * attaches at once; with several, it lists their addresses and a number key picks one. Attached,
 * it opens the zone running term.lua, the payload beside term.exe (connector.h does the choosing,
 * attaching and opening). Then the window is that zone's screen and every key goes to it, Ctrl+C
 * and Ctrl+Alt+C included; the zone keeps them from octerm itself. Ctrl+D is the terminal's own:
 * it disconnects, which ends the zone.
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

#include "connector.h"
#include "keys.h"
#include "screen.h"
#include "winconsole.h"

struct term_t {
    zone_link_t conn;
    std::string command;                /*!< "" for the terminal, or "zones" / "kill" */
    std::string argument;               /*!< the zone `kill` terminates */
    screen_t screen;
    int win_w = 0, win_h = 0;           /*!< the console window's size, last told to the zone */
    std::string zone_buf;               /*!< the zone's bytes that are not a whole frame yet */
};
inline term_t term;

inline void term_title() {
    std::string t = "terminal - choosing a computer";
    if (term.conn.state == conn_state::running)
        t = "terminal - " + term.conn.addr + ", " + std::to_string(term.screen.w) + "x"
          + std::to_string(term.screen.h);
    SetConsoleTitleA((t + "   (Ctrl+D disconnects)").c_str());
}

/*! Draws the list of computers in place of a screen. */
inline void show_list() {
    std::string page = "\x1b[0m\x1b[2J\x1b[H";
    if (term.conn.list.empty()) {
        page += "No computer is connected to the relay. Run octerm on one.\r\n";
    } else {
        page += "Computers connected to the relay; press a number to use one:\r\n\r\n";
        for (size_t i = 0; i < term.conn.list.size() && i < 9; i++)
            page += "  " + std::to_string(i + 1) + ")  " + term.conn.list[i] + "\r\n";
    }
    page += "\r\nCtrl+D disconnects.";
    con_write(page);
    term_title();
}

/*! Takes a new list of computers: a command picks by its prefix and ends when none matches; the
 * window attaches to the only one, or shows the list to pick from. */
inline void term_list() {
    zone_link_t &c = term.conn;
    if (!term.command.empty()) {
        pick_computer(c);
        if (c.state == conn_state::choosing && c.goodbye.empty())
            c.goodbye = "no computer matches";
    } else if (c.list.size() == 1) {
        attach(c, c.list[0]);
    } else {
        show_list();
    }
}

/*! Starts the channel's conversation once attached: the command, or opening the zone. */
inline void term_attached() {
    if (term.command == "zones")
        post(term.conn.out, enc_zones_ask());
    else if (term.command == "kill")
        post(term.conn.out, enc_terminate(term.argument));
    else
        open_zone(term.conn, false);
}

/*! Tells the zone the window's size, which it waits for before starting its shell. */
inline bool term_opened() {
    term_title();
    post(term.conn.out, enc_zone_data(enc_window(term.win_w, term.win_h)));
    return true;
}

/*! Takes the answer to a command: the zones open on the computer. It ends the terminal. */
inline bool term_zones(const std::vector<std::string> &names) {
    std::string &bye = term.conn.goodbye;
    bye = "zones on " + term.conn.addr + ":";
    for (const std::string &n : names)
        bye += " " + n;
    if (names.empty())
        bye += " none";
    return false;
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
            if (term.conn.state == conn_state::running)
                post(term.conn.out, enc_zone_data(enc_window(w, h)));
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
        term.conn.goodbye = "the terminal zone sent something that is not a screen frame";
    return rc != -1;
}

/*! Gives the connector the terminal's own parts. */
inline void term_init() {
    zone_link_t &c = term.conn;
    c.zone = "terminal";
    c.on_list = term_list;
    c.on_attached = term_attached;
    c.on_opened = term_opened;
    c.on_zone_bytes = take_zone_bytes;
    c.on_zones = term_zones;
}

/*! Runs the relay's side of the terminal; its end ends the terminal. */
inline colib::task_t relay_session(SOCKET s) {
    co_await conn_session(term.conn, s);
    co_await colib::force_stop(0);
    co_return 0;
}

/*! Reads the console window: keys go to the zone once it runs, a number picks a computer before,
 * and Ctrl+D ends the terminal. */
inline colib::task_t term_input() {
    key_decoder_t decoder;
    char chunk[256];
    zone_link_t &c = term.conn;
    while (true) {
        SSIZE_T n = co_await colib::read(con.in, chunk, sizeof(chunk));
        if (n < 0)
            break;
        std::vector<oc_key_t> keys = decoder.feed(chunk, size_t(n));
        if (decoder.quit) {
            c.goodbye = "disconnected; the terminal zone has ended";
            break;
        }
        if (c.state == conn_state::running) {
            std::string frames;
            for (const oc_key_t &k : keys)
                frames += key_frame(k);
            if (!frames.empty())
                post(c.out, enc_zone_data(frames));
        } else if (c.state == conn_state::choosing) {
            for (const oc_key_t &k : keys)
                if (k.down && k.ch >= '1' && k.ch <= '9' && size_t(k.ch - '1') < c.list.size())
                    attach(c, c.list[k.ch - '1']);
        }
    }
    co_await colib::force_stop(0);
    co_return 0;
}
