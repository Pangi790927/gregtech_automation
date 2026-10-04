/*! ocscp.h - ocscp: copies one file between the PC and a computer, the way scp copies one
 * between two machines (the user's "mini scp").
 *
 * A connector (connector.h) with no window: it opens the "ocscp" zone (ocscp.lua, the payload
 * beside it) on the only computer, or the one whose address starts as asked, and the zone
 * copies one file each time it opens. `get` asks for a file and takes it in pieces, then writes
 * it to a local file or, with none given, to stdout, which is how Claude reads a file the user
 * names. `put` sends a local file in pieces, which the zone writes as they come; a computer has
 * a few MB of memory, so neither side holds a whole file there. The copy is binary, byte for
 * byte. Paths on the computer that do not start with / are under /home.
 *
 * Needs colib.h included first.
 *
 * @date 2026-10-01 */

#pragma once

#include <cstdio>
#include <string>

#include "connector.h"

/*! A piece of a file, sent as one 'B' frame: small enough for the computer to take in one. */
constexpr size_t SCP_PIECE = 32768;

struct scp_t {
    zone_link_t conn;
    bool get = true;                    /*!< get: computer to PC; put: PC to computer */
    std::string oc_path;
    std::string local_path;             /*!< for get, "" is stdout */
    std::string data;                   /*!< put: the file sent; get: what has arrived */
    bool opened = false;                /*!< get: the computer said it can read the file */
    uint32_t size = 0;                  /*!< get: the size the computer said */
    bool done = false;                  /*!< the file was copied */
    std::string zone_buf;               /*!< the zone's bytes that are not a whole frame yet */
};
inline scp_t scp;

/*! Takes a new list of computers: picks one, or ends when there is none to pick. */
inline void scp_list() {
    zone_link_t &c = scp.conn;
    pick_computer(c);
    if (c.state == conn_state::choosing && c.goodbye.empty())
        c.goodbye = c.list.empty() ? "no computer is connected to the relay"
                                   : "no computer's address starts with " + c.prefix;
}

/*! Starts the copy once the zone is open: asks for the file, or sends it whole, in pieces. */
inline bool scp_opened() {
    if (scp.get) {
        zone_send(scp.conn, enc_get(scp.oc_path));
        return true;
    }
    std::string frames = enc_put(scp.oc_path);
    for (size_t at = 0; at < scp.data.size(); at += SCP_PIECE)
        frames += enc_piece(scp.data.substr(at, SCP_PIECE));
    zone_send(scp.conn, frames + enc_file_end());
    return true;
}

/*! Writes what `get` took to the local file, or to stdout; false when it cannot. */
inline bool scp_save() {
    if (scp.local_path.empty())
        return fwrite(scp.data.data(), 1, scp.data.size(), stdout) == scp.data.size()
            && fflush(stdout) == 0;
    FILE *f = fopen(scp.local_path.c_str(), "wb");
    if (!f)
        return false;
    bool ok = fwrite(scp.data.data(), 1, scp.data.size(), f) == scp.data.size();
    return fclose(f) == 0 && ok;
}

/*! Ends the copy, saying how it went; returns -1, the frame result that ends the connector. */
inline int scp_finish(bool ok, const std::string &msg) {
    scp.done = ok;
    scp.conn.goodbye = msg;
    return -1;
}

/*! Takes one frame the zone sent, at the front of `r`. Returns 1 when taken, 0 when it has not
 * all arrived (`r` is left where it was), and -1 when the copy is to end (scp.conn.goodbye
 * says why). */
inline int take_scp_frame(reader_t &r) {
    reader_t start = r;
    char type = char(r.u(1));
    std::string text;
    if (type == 'O' || type == 'K') {
        if (!r.has(type == 'O' ? 5 : 1)) {
            r = start;
            return 0;
        }
        bool ok = r.u(1) != 0;
        uint32_t size = type == 'O' ? r.u(4) : 0;
        if (!r.str(text, 2)) {
            r = start;
            return 0;
        }
        std::string where = scp.conn.addr + ":" + scp.oc_path;
        if (type == 'K')
            return scp_finish(ok, ok ? text : "cannot write " + where + ": " + text);
        if (!ok)
            return scp_finish(false, "cannot read " + where + ": " + text);
        scp.opened = true;
        scp.size = size;
        return 1;
    }
    if (type == 'B') {
        if (!r.str(text, 2)) {
            r = start;
            return 0;
        }
        scp.data += text;
        return 1;
    }
    if (type == 'E' && scp.opened) {
        std::string from = scp.conn.addr + ":" + scp.oc_path;
        if (scp.data.size() != scp.size)
            return scp_finish(false, "got " + std::to_string(scp.data.size()) + " of "
                              + std::to_string(scp.size) + " bytes of " + from);
        std::string to = scp.local_path.empty() ? "stdout" : scp.local_path;
        if (!scp_save())
            return scp_finish(false, "cannot write " + to);
        return scp_finish(true, std::to_string(scp.size) + " bytes from " + from + " to "
                          + to);
    }
    r = start;
    scp.conn.goodbye = "the ocscp zone sent something that is not its frame";
    return -1;
}

/*! Takes the zone's bytes, cut anywhere; false once the copy has ended. */
inline bool take_scp_bytes(const std::string &bytes) {
    scp.zone_buf += bytes;
    const uint8_t *begin = reinterpret_cast<const uint8_t *>(scp.zone_buf.data());
    reader_t r = {begin, begin + scp.zone_buf.size()};
    int rc = 1;
    while (r.has(1) && (rc = take_scp_frame(r)) == 1) {}
    scp.zone_buf.erase(0, size_t(r.p - begin));
    return rc != -1;
}

/*! Gives the connector ocscp's own parts. */
inline void scp_init() {
    zone_link_t &c = scp.conn;
    c.zone = "ocscp";
    c.on_list = scp_list;
    c.on_opened = scp_opened;
    c.on_zone_bytes = take_scp_bytes;
}

/*! Runs the relay's side of the copy; its end ends the program. */
inline colib::task_t scp_session(SOCKET s) {
    co_await conn_session(scp.conn, s);
    co_await colib::force_stop(0);
    co_return 0;
}
