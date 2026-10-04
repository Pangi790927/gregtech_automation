/*! connector.h - what every connector does around its zone: it reaches the relay (relay_host),
 * picks a computer, attaches to it, and opens its zone there, from the computer's cache or with
 * the code; then it hands the zone's bytes to the connector's own part and notices the zone
 * ending.
 *
 * A connector holds one zone_link_t, whose own parts are functions: what it does with a list of
 * computers, once attached, once its zone runs, with the zone's bytes, and with a list of zones.
 * term/term.h and claude-oc/claude-oc.h are the two. Picking a computer by default takes the
 * only one, or the one whose address starts with `prefix`; with none there, it waits for the
 * relay's next list, which comes whenever a computer arrives or leaves.
 *
 * Needs colib.h included first.
 *
 * @date 2026-09-30 */

#pragma once

#include <fstream>
#include <functional>
#include <sstream>
#include <string>
#include <vector>

#include "net.h"
#include "protocol.h"

enum class conn_state { choosing, attaching, opening, running };

struct zone_link_t {
    sender_p out;
    conn_state state = conn_state::choosing;
    std::string zone;                   /*!< the zone's name, as the computer lists it */
    std::string code, hash;             /*!< the zone's payload, and the hash it is cached under */
    std::string addr;                   /*!< the computer attached to */
    std::string prefix;                 /*!< the computer to pick, by the start of its address */
    std::vector<std::string> list;      /*!< the computers the relay last listed */
    std::string goodbye;                /*!< why the connector ended; set means it is ending */

    /*! Takes a new list while choosing; unset, pick_computer() decides. */
    std::function<void()> on_list;
    /*! Starts the channel's conversation once attached; unset, the zone is opened. */
    std::function<void()> on_attached;
    /*! Runs once the zone is open; returns false to end. */
    std::function<bool()> on_opened;
    /*! Takes the zone's bytes, cut anywhere; returns false to end. */
    std::function<bool(const std::string &)> on_zone_bytes;
    /*! Takes the loader's list of zones, the answer to 'Z' or 'T'; returns false to end. */
    std::function<bool(const std::vector<std::string> &)> on_zones;
};

/*! Returns the folder the running exe is in, with its trailing backslash. */
inline std::string exe_folder() {
    char path[MAX_PATH];
    DWORD n = GetModuleFileNameA(NULL, path, MAX_PATH);
    std::string dir(path, n);
    return dir.substr(0, dir.find_last_of("\\/") + 1);
}

/*! Reads a file whole into `out`; false when it cannot be read. */
inline bool read_file(const std::string &path, std::string &out) {
    std::ifstream f(path, std::ios::binary);
    if (!f)
        return false;
    std::stringstream ss;
    ss << f.rdbuf();
    out = ss.str();
    return true;
}

/*! Returns the relay's address: `relay` in the repo's config.ini, found by looking up from the
 * exe's folder, or 127.0.0.1 when the file or the line is not there. The relay can run on the
 * Minecraft server, and its address there is this PC's own setting, kept out of git
 * (config-example.ini). Read once. */
inline const std::string &relay_host() {
    static std::string host = [] {
        std::string dir = exe_folder(), text;
        for (int up = 0; up < 4 && !read_file(dir + "config.ini", text); up++)
            dir += "..\\";
        std::istringstream lines(text);
        std::string line;
        while (std::getline(lines, line)) {
            size_t eq = line.find('=');
            if (line.empty() || line[0] == '#' || eq == std::string::npos)
                continue;
            auto trim = [](std::string s) {
                s.erase(0, s.find_first_not_of(" \t\r"));
                s.erase(s.find_last_not_of(" \t\r") + 1);
                return s;
            };
            if (trim(line.substr(0, eq)) == "relay")
                return trim(line.substr(eq + 1));
        }
        return std::string("127.0.0.1");
    }();
    return host;
}

/*! Connects to the relay's connector port at relay_host(); returns INVALID_SOCKET when no relay
 * listens there. */
inline colib::task<SOCKET> connect_relay(uint16_t port) {
    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    sockaddr_in a = {};
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    if (inet_pton(AF_INET, relay_host().c_str(), &a.sin_addr) != 1
            || co_await colib::connect(s, (sockaddr *)&a, sizeof(a)) != colib::ERROR_OK) {
        closesocket(s);
        co_return INVALID_SOCKET;
    }
    co_return s;
}

/*! Reads the zone's payload from beside the exe, and hashes it; false when it is not there. */
inline bool load_payload(zone_link_t &c, const std::string &file) {
    if (!read_file(exe_folder() + file, c.code))
        return false;
    c.hash = payload_hash(c.code);
    return true;
}

inline void attach(zone_link_t &c, const std::string &addr) {
    c.state = conn_state::attaching;
    c.addr = addr;
    post(c.out, enc_attach(addr));
}

/*! Picks a computer from the list: the only one matching the prefix. With none it waits for the
 * next list; with several it ends, naming them. */
inline void pick_computer(zone_link_t &c) {
    std::vector<std::string> hits;
    for (const std::string &a : c.list)
        if (a.rfind(c.prefix, 0) == 0)
            hits.push_back(a);
    if (hits.size() == 1) {
        attach(c, hits[0]);
        return;
    }
    if (hits.empty())
        return;
    c.goodbye = "several computers match; give the start of an address:";
    for (const std::string &a : hits)
        c.goodbye += "\n  " + a;
}

/*! Takes a list from the relay; returns false while it has not all arrived. */
inline bool take_list(zone_link_t &c, reader_t &r) {
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
    c.list = list;
    if (c.state == conn_state::attaching)
        return true;        /* the answer to the attach is on its way; a second would be data */
    if (c.on_list)
        c.on_list();
    else
        pick_computer(c);
    return true;
}

/*! Sends bytes to the zone, in as many 'd' frames as their length needs: one holds 65535. */
inline void zone_send(zone_link_t &c, const std::string &bytes) {
    for (size_t i = 0; i < bytes.size(); i += 65535)
        post(c.out, enc_zone_data(bytes.substr(i, 65535)));
}

inline void open_zone(zone_link_t &c, bool with_code) {
    post(c.out, enc_open(c.zone, c.hash, with_code ? &c.code : nullptr));
}

/*! Takes the loader's answer to opening the zone: a cache miss sends the code. Returns false
 * when the zone did not open. */
inline bool take_opened(zone_link_t &c, int status, const std::string &msg) {
    if (status == 1) {
        open_zone(c, true);
        return true;
    }
    if (status != 0) {
        c.goodbye = "the computer could not open the " + c.zone + " zone: " + msg;
        return false;
    }
    c.state = conn_state::running;
    return c.on_opened ? c.on_opened() : true;
}

/*! Takes one frame of the channel, the loader's side of it. Returns 0 when it has not all
 * arrived, 1 when handled, and -1 when the connector is to end. */
inline int take_channel_frame(zone_link_t &c, reader_t &r) {
    reader_t start = r;
    char type = char(r.u(1));
    std::string text;
    if (type == 'P') {
        if (!r.has(2)) {
            r = start;
            return 0;
        }
        int status = int(r.u(1));
        r.u(1);                                                 /* from the cache or not */
        if (!r.str(text, 2)) {
            r = start;
            return 0;
        }
        return take_opened(c, status, text) ? 1 : -1;
    }
    if (type == 'd' || type == 'x') {
        if (!r.str(text, 2)) {
            r = start;
            return 0;
        }
        if (type == 'x') {
            c.goodbye = "the " + c.zone + " zone ended: " + text;
            return -1;
        }
        return !c.on_zone_bytes || c.on_zone_bytes(text) ? 1 : -1;
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
        return c.on_zones && c.on_zones(names) ? 1 : -1;
    }
    c.goodbye = "the computer sent something that is not a frame";
    return -1;
}

/*! Handles the relay's whole frames at the front of `buf` and drops them. Returns false when the
 * connector is to end, with the reason in c.goodbye. */
inline bool take_relay_bytes(zone_link_t &c, std::string &buf) {
    const uint8_t *begin = reinterpret_cast<const uint8_t *>(buf.data());
    reader_t r = {begin, begin + buf.size()};
    bool ok = true;
    while (ok && r.has(1)) {
        if (c.state == conn_state::choosing || c.state == conn_state::attaching) {
            if (*r.p == 'L') {
                if (!take_list(c, r))
                    break;
            } else if (*r.p == 'Y' && c.state == conn_state::attaching) {
                r.u(1);
                c.state = conn_state::opening;
                if (c.on_attached)
                    c.on_attached();
                else
                    open_zone(c, false);
            } else if (*r.p == 'N' && c.state == conn_state::attaching) {
                r.u(1);                 /* that computer left; the list that follows decides */
                c.state = conn_state::choosing;
            } else {
                c.goodbye = "the relay sent something that is not a frame";
                ok = false;
            }
            ok = ok && c.goodbye.empty();
            continue;
        }
        int rc = take_channel_frame(c, r);
        if (rc == 0)
            break;
        ok = rc == 1;
    }
    buf.erase(0, size_t(r.p - begin));
    return ok;
}

/*! Moves the relay's bytes into the connector until it ends or the relay closes; then closes
 * the connection, with the reason in c.goodbye. The caller decides what ending means. */
inline colib::task_t conn_session(zone_link_t &c, SOCKET s) {
    std::string buf;
    std::vector<char> chunk(16384);
    while (true) {
        SSIZE_T n = co_await colib::read((HANDLE)s, chunk.data(), chunk.size());
        if (n <= 0) {
            if (c.goodbye.empty())
                c.goodbye = c.state == conn_state::running
                    ? "the computer or the relay went away" : "the relay closed the connection";
            break;
        }
        buf.append(chunk.data(), size_t(n));
        if (!take_relay_bytes(c, buf))
            break;
    }
    close_sender(c.out);
    closesocket(s);
    co_return 0;
}
