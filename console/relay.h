/*! relay.h - the relay: keeps every computer's connection, and forwards between computers and
 * the connectors attached to them.
 *
 * Computers connect on the computer port (7777), and connectors (term.exe, tools) on the
 * connector port (7778): on the PC, from anywhere the firewall lets through and from 127.0.0.1;
 * on the Minecraft server, on 127.0.0.2 and from the PC's address alone (relay.cpp). A computer's
 * first frame gives its address, which is all the relay learns about it, and the hash of the
 * extension it has cached; the relay answers with octerm_ext.lua, the rest of octerm, read anew
 * for every hello and sent only when that hash differs. A connector is told the
 * addresses, attaches to one, and gets a channel on that computer: from then on the relay wraps
 * what the connector sends into 'D' frames on that channel and unwraps what comes back, without
 * looking inside. Several connectors may use one computer at once, each on its own channel.
 *
 * A connector leaving is told to the computer ('G'), which ends that connector's zone: a
 * session does not outlive its connector. A computer leaving closes its connectors. Stopping the
 * relay (Ctrl+C) drops everything.
 *
 * Needs colib.h included first.
 *
 * @date 2026-09-30 */

#pragma once

#include <algorithm>
#include <cstdio>
#include <ctime>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <vector>

#include "net.h"
#include "protocol.h"

struct connector_t;
using connector_p = std::shared_ptr<connector_t>;

struct computer_t {
    SOCKET s = INVALID_SOCKET;
    std::string addr;                       /*!< the computer's own address, from its hello */
    std::string ip;
    sender_p out;
    std::map<int, connector_p> channels;    /*!< the connectors attached, by channel */
};
using computer_p = std::shared_ptr<computer_t>;

struct connector_t {
    SOCKET s = INVALID_SOCKET;
    sender_p out;
    computer_p computer;                    /*!< the computer attached to, if any */
    int ch = -1;
};

struct relay_t {
    std::vector<computer_p> computers;      /*!< those that said hello, in the order they came */
    std::set<connector_p> connectors;
    std::vector<SOCKET> to_end;             /*!< sessions to end, by waking their reads */
    std::string ext_file;                   /*!< octerm_ext.lua, beside relay.exe */
    uint32_t connectors_from = 0;           /*!< the one address connectors may come from, in
                                                 host order; 0 lets any in */
    bool quiet = false;                     /*!< no log lines: the self-tests */
};
inline relay_t relay;

/*! Reads octerm's extension; false when the file is not there. It is read again for every
 * computer that says hello, so an edited extension needs no restart of the relay. */
inline bool read_ext(std::string &code) {
    FILE *f = fopen(relay.ext_file.c_str(), "rb");
    if (!f)
        return false;
    char chunk[4096];
    size_t n;
    code.clear();
    while ((n = fread(chunk, 1, sizeof(chunk), f)) > 0)
        code.append(chunk, n);
    fclose(f);
    return true;
}

/*! Ends the sessions queued in relay.to_end. shutdown() alone is not enough: a session's own
 * pending read ends only when the other side closes too, and a computer that rebooted, or a
 * connector that hangs, never does. sock_stop wakes that read, and the session closes up. */
inline colib::task_t end_queued() {
    std::vector<SOCKET> sockets;
    sockets.swap(relay.to_end);
    for (SOCKET s : sockets)
        co_await sock_stop(s);
    co_return 0;
}

/*! Shows the counts in the window's title; on Linux the relay runs in screen, with no title. */
inline void relay_title() {
#if COLIB_OS_WINDOWS
    if (relay.quiet)
        return;
    SetConsoleTitleA(("relay - " + std::to_string(relay.computers.size()) + " computer(s), "
            + std::to_string(relay.connectors.size()) + " connector(s)").c_str());
#endif
}

/*! Prints one line to the relay's window, with the time. */
inline void relay_log(const std::string &line) {
    if (relay.quiet)
        return;
    time_t now = time(nullptr);
    char stamp[16];
    strftime(stamp, sizeof(stamp), "%H:%M:%S", localtime(&now));
    printf("%s  %s\n", stamp, line.c_str());
    fflush(stdout);
    relay_title();
}

/*! Returns a byte as a log line shows it: the character, and its code in hex. */
inline std::string show_byte(uint8_t b) {
    char text[24];
    if (b >= 0x20 && b < 0x7F)
        snprintf(text, sizeof(text), "'%c' (0x%02X)", b, b);
    else
        snprintf(text, sizeof(text), "0x%02X", b);
    return text;
}

inline computer_p find_computer(const std::string &addr) {
    for (const computer_p &c : relay.computers)
        if (c->addr == addr)
            return c;
    return nullptr;
}

/*! Tells every connector not attached yet which computers there are. */
inline void send_lists() {
    std::vector<std::string> addrs;
    for (const computer_p &c : relay.computers)
        addrs.push_back(c->addr);
    for (const connector_p &k : relay.connectors)
        if (!k->computer)
            post(k->out, enc_list(addrs));
}

/*! Takes a computer's hello and answers it with the extension to run: the code, unless the
 * computer's cache already has it under the same hash. One already connected with that address
 * is the same computer after a reboot: its old connection is dropped, and with it the connectors
 * attached there. Returns false, with the reason in `why`, when there is no extension to send. */
inline bool computer_hello(const computer_p &c, const std::string &addr,
                           const std::string &cached, std::string &why) {
    std::string code;
    if (!read_ext(code)) {
        why = "there is no " + relay.ext_file + " to send it";
        return false;
    }
    std::string hash = payload_hash(code);
    post(c->out, enc_ext(hash, cached == hash ? nullptr : &code));
    c->addr = addr;
    if (computer_p old = find_computer(addr)) {
        relay.computers.erase(std::find(relay.computers.begin(), relay.computers.end(), old));
        relay.to_end.push_back(old->s);
    }
    relay.computers.push_back(c);
    relay_log("computer " + addr + " connected, from " + c->ip + "; extension " + hash
            + (cached == hash ? " (its cached copy)" : " (sent)"));
    send_lists();
    return true;
}

/*! Takes a computer's leaving: its connectors are closed, the others told. */
inline void computer_left(const computer_p &c, const std::string &why) {
    if (c->addr.empty()) {
        relay_log("a connection from " + c->ip + " ended before saying hello: " + why);
        return;
    }
    for (auto &[ch, k] : c->channels) {
        k->computer = nullptr;
        relay.to_end.push_back(k->s);
    }
    c->channels.clear();
    auto it = std::find(relay.computers.begin(), relay.computers.end(), c);
    if (it == relay.computers.end())
        return;                             /* replaced by a newer connection of its own */
    relay.computers.erase(it);
    relay_log("computer " + c->addr + " left: " + why);
    send_lists();
}

/*! Handles the computer's whole frames at the front of `buf` and drops them. Returns false when
 * the stream is not frames, and says why in `why`. */
inline bool take_computer_bytes(const computer_p &c, std::string &buf, std::string &why) {
    const uint8_t *begin = reinterpret_cast<const uint8_t *>(buf.data());
    reader_t r = {begin, begin + buf.size()};
    while (r.has(1)) {
        reader_t frame = r;
        uint8_t type = uint8_t(r.u(1));
        if (c->addr.empty() && type != 'H') {
            why = "it sent " + show_byte(type) + " instead of a hello (an old octerm?)";
            return false;
        }
        if (type == 'H') {
            std::string addr, cached;
            if (!r.has(1)) {
                r = frame;
                break;
            }
            /* the version first: an older octerm's hello has another shape after it */
            int version = int(r.u(1));
            if (version != PROTOCOL_VERSION) {
                why = "it speaks protocol " + std::to_string(version) + ", this relay "
                    + std::to_string(PROTOCOL_VERSION) + " (octerm.lua and the relay differ)";
                return false;
            }
            if (!r.str(addr) || !r.str(cached)) {
                r = frame;
                break;
            }
            if (!computer_hello(c, addr, cached, why))
                return false;
        } else if (type == 'D') {
            if (!r.has(1)) {
                r = frame;
                break;
            }
            int ch = int(r.u(1));
            std::string bytes;
            if (!r.str(bytes, 2)) {
                r = frame;
                break;
            }
            auto it = c->channels.find(ch);
            if (it != c->channels.end())
                post(it->second->out, bytes);
        } else {
            why = "it sent " + show_byte(type) + ", which starts no frame";
            return false;
        }
    }
    buf.erase(0, size_t(r.p - begin));
    return true;
}

inline colib::task_t computer_session(SOCKET s, std::string ip) {
    computer_p c = std::make_shared<computer_t>();
    c->s = s;
    c->ip = ip;
    c->out = co_await open_sender(s);
    std::string buf, why;
    std::vector<char> chunk(16384);
    while (true) {
        int64_t n = co_await sock_read(s, chunk.data(), chunk.size());
        if (n <= 0) {
            why = n == 0 ? "it closed the connection" : "the connection broke";
            break;
        }
        buf.append(chunk.data(), size_t(n));
        bool ok = take_computer_bytes(c, buf, why);
        co_await end_queued();
        if (!ok)
            break;
    }
    computer_left(c, why);
    co_await end_queued();
    close_sender(c->out);
    co_await sock_stop(s);
    closesocket(s);
    co_return 0;
}

/*! Gives the connector a free channel on the computer; false when all 255 are taken. */
inline bool attach(const connector_p &k, const computer_p &c) {
    for (int ch = 0; ch < 255; ch++)
        if (!c->channels.count(ch)) {
            c->channels[ch] = k;
            k->computer = c;
            k->ch = ch;
            post(k->out, "Y");
            relay_log("a connector attached to " + c->addr + ", channel " + std::to_string(ch));
            return true;
        }
    return false;
}

/*! Handles what a connector sent: before attaching, its 'A' frames; after, everything is its
 * channel's, passed to the computer in pieces a 'D' frame can carry. Returns false when a
 * connector not attached yet sends something that is not an 'A'. */
inline bool take_connector_bytes(const connector_p &k, std::string &buf) {
    if (!k->computer) {
        const uint8_t *begin = reinterpret_cast<const uint8_t *>(buf.data());
        reader_t r = {begin, begin + buf.size()};
        std::string addr;
        if (!r.has(1))
            return true;
        if (*r.p != 'A')
            return false;
        r.u(1);
        if (!r.str(addr))
            return true;
        buf.erase(0, size_t(r.p - begin));
        computer_p c = find_computer(addr);
        if (!c || !attach(k, c)) {
            post(k->out, "N");
            send_lists();
            return true;
        }
    }
    for (size_t i = 0; i < buf.size(); i += 65535)
        post(k->computer->out, enc_data(k->ch, buf.substr(i, 65535)));
    buf.clear();
    return true;
}

inline colib::task_t connector_session(SOCKET s) {
    connector_p k = std::make_shared<connector_t>();
    k->s = s;
    k->out = co_await open_sender(s);
    relay.connectors.insert(k);
    relay_title();
    send_lists();
    std::string buf;
    std::vector<char> chunk(16384);
    while (true) {
        int64_t n = co_await sock_read(s, chunk.data(), chunk.size());
        if (n <= 0)
            break;
        buf.append(chunk.data(), size_t(n));
        if (!take_connector_bytes(k, buf))
            break;
    }
    if (computer_p c = k->computer) {
        c->channels.erase(k->ch);
        post(c->out, enc_gone(k->ch));
        relay_log("a connector left " + c->addr + ", channel " + std::to_string(k->ch));
    }
    relay.connectors.erase(k);
    relay_title();
    close_sender(k->out);
    co_await sock_stop(s);
    closesocket(s);
    co_return 0;
}

/*! Takes connections on `listener`; each gets a computer or a connector session. On the server
 * the connector port faces the LAN, and a connector can make a computer run anything, so with
 * relay.connectors_from set, a connector from any other address is closed unread. */
inline colib::task_t relay_accept(SOCKET listener, bool connectors) {
    while (true) {
        sockaddr_in addr = {};
        SOCKET s = co_await sock_accept(listener, addr);
        if (s == INVALID_SOCKET) {
            co_await colib::sleep_ms(500);
            continue;
        }
        char ip[INET_ADDRSTRLEN] = "?";
        inet_ntop(AF_INET, &addr.sin_addr, ip, sizeof(ip));
        if (connectors && relay.connectors_from
                && ntohl(addr.sin_addr.s_addr) != relay.connectors_from) {
            relay_log(std::string("refused a connector from ") + ip
                    + ": connectors may come only from the PC");
            closesocket(s);
            continue;
        }
        if (connectors)
            co_await colib::sched(connector_session(s));
        else
            co_await colib::sched(computer_session(s, ip));
    }
    co_return 0;
}
