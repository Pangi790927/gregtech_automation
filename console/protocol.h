/*! protocol.h - the frames between octerm.lua (the loader on a computer), the relay, and the
 * connectors (term.exe, and later tools).
 *
 * Three layers. The relay sits between computers and connectors and understands only the outer
 * one; what a connector says to its zone, it passes on untouched.
 *
 *   computer <-> relay
 *     oc -> relay   'H' version:u8 n:u8 address[n] n:u8 hash[n]
 *                                                      first: who this computer is, and the
 *                                                      hash of the extension it has cached
 *     relay -> oc   'E' n:u8 hash[n] has:u8 [len:u32 code[len]]
 *                                                      the extension to run (octerm_ext.lua);
 *                                                      without the code, the cached one
 *     relay -> oc   'D' channel:u8 n:u16 bytes[n]      a connector's bytes, on its channel
 *     oc -> relay   'D' channel:u8 n:u16 bytes[n]      bytes for that channel's connector
 *     relay -> oc   'G' channel:u8                     that connector is gone
 *   connector <-> relay
 *     relay -> conn 'L' count:u8 { n:u8 address[n] }   the computers there are
 *     conn -> relay 'A' n:u8 address[n]                attach to one; answered by 'Y', or by
 *     relay -> conn 'Y' / 'N'                          'N' and a new 'L' when it is not there.
 *                                                      After 'Y' the connection is the channel,
 *                                                      both ways.
 *   connector <-> loader, inside a channel
 *     conn -> oc    'O' n:u8 name[n] n:u8 hash[n] has:u8 [len:u32 code[len]]
 *                                                      open a zone running that code; without
 *                                                      it, the copy cached under that hash
 *     oc -> conn    'P' status:u8 hit:u8 n:u16 msg[n]  0 open, 1 cache miss (send the code),
 *                                                      2 failed (msg says why); hit: from cache
 *     conn -> oc    'Z'                                list the zones; answered by
 *     oc -> conn    'z' count:u8 { n:u8 name[n] }
 *     conn -> oc    'T' n:u8 name[n]                   terminate that zone; answered by 'z'
 *     both          'd' n:u16 bytes[n]                 the zone's own conversation
 *     oc -> conn    'x' n:u16 why[n]                   the zone has ended
 *
 *   the terminal zone's own conversation (term.lua), inside 'd'
 *     oc -> term    'R' w:u16 h:u16                                         the screen is w x h
 *                   'S' x:i16 y:i16 fg:u24 bg:u24 vertical:u8 n:u16 utf8[n] gpu.set
 *                   'F' x:i16 y:i16 w:i16 h:i16 fg:u24 bg:u24 n:u8 utf8[n]  gpu.fill
 *                   'C' x:i16 y:i16 w:i16 h:i16 tx:i16 ty:i16               gpu.copy
 *     term -> oc    'K' down:u8 char:u32 code:u16                           a key signal
 *                   'W' w:u16 h:u16                     the window is w x h; the screen follows
 *
 * Big-endian throughout, built by hand on the Lua side, so octerm runs on both of
 * OpenComputers' Lua architectures: 5.2 has no string.pack. Coordinates are signed, since a
 * program may draw text that starts off the left edge. The address is the computer's own
 * (computer.address()): every computer reaches the PC from the Minecraft server's IP.
 *
 * @date 2026-09-30 */

#pragma once

#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

#include "screen.h"

/*! The loader protocol this PC side speaks; a computer saying another is refused. 1 was the
 * single-file octerm.lua, 2 the two stages: octerm.lua and the extension the relay sends. */
constexpr int PROTOCOL_VERSION = 2;

/*! One key signal for the computer: what OpenComputers' keyboard puts in key_down and key_up. */
struct oc_key_t {
    bool down;
    uint32_t ch;    /*!< the character typed, 0 for keys that type none (arrows, F-keys) */
    uint16_t code;  /*!< the key's scancode, as in OpenOS's keyboard.keys */
};

/*! Reads big-endian numbers off a byte range; has() says whether n more bytes are there. */
struct reader_t {
    const uint8_t *p;
    const uint8_t *end;

    bool has(size_t n) const { return size_t(end - p) >= n; }
    uint32_t u(int bytes) {
        uint32_t v = 0;
        while (bytes--)
            v = (v << 8) | *p++;
        return v;
    }
    int i16() { return int16_t(u(2)); }

    /*! Reads a string prefixed by its length, of `len_bytes` bytes, into `out`; false (and
     * nothing read) if it has not all arrived. */
    bool str(std::string &out, int len_bytes = 1) {
        if (!has(size_t(len_bytes)))
            return false;
        reader_t peek = *this;
        size_t n = peek.u(len_bytes);
        if (!peek.has(n))
            return false;
        out.assign(reinterpret_cast<const char *>(peek.p), n);
        p = peek.p + n;
        return true;
    }
};

/*! Applies the screen frame (R, S, F or C) at the front of `r` and moves `r` past it. Returns 1
 * when a frame was applied, 0 when the bytes for a whole one have not all arrived (`r` is left
 * where it was), and -1 when the bytes are not a screen frame. */
inline int apply_frame(screen_t &s, reader_t &r) {
    reader_t start = r;
    if (!r.has(1))
        return 0;
    switch (r.u(1)) {
    case 'R': {
        if (!r.has(4))
            break;
        int w = r.u(2), h = r.u(2);
        if (w > 1024 || h > 1024)
            return -1;
        s.resize(w, h);
        return 1;
    }
    case 'S': {
        if (!r.has(13))
            break;
        int x = r.i16(), y = r.i16();
        uint32_t fg = r.u(3), bg = r.u(3);
        bool vertical = r.u(1) != 0;
        size_t n = r.u(2);
        if (!r.has(n))
            break;
        s.set(x, y, fg, bg, vertical, utf8_decode(r.p, n));
        r.p += n;
        return 1;
    }
    case 'F': {
        if (!r.has(15))
            break;
        int x = r.i16(), y = r.i16(), w = r.i16(), h = r.i16();
        uint32_t fg = r.u(3), bg = r.u(3);
        size_t n = r.u(1);
        if (!r.has(n))
            break;
        std::u32string ch = utf8_decode(r.p, n);
        s.fill(x, y, w, h, fg, bg, ch.empty() ? U' ' : ch[0]);
        r.p += n;
        return 1;
    }
    case 'C': {
        if (!r.has(12))
            break;
        int x = r.i16(), y = r.i16(), w = r.i16(), h = r.i16(), tx = r.i16(), ty = r.i16();
        s.copy(x, y, w, h, tx, ty);
        return 1;
    }
    default:
        r = start;
        return -1;
    }
    r = start;
    return 0;
}

/* ENCODERS, the same bytes octerm.lua and term.lua build
=================================================================================================*/

inline std::string be(uint32_t v, int bytes) {
    std::string s;
    for (int i = bytes - 1; i >= 0; i--)
        s += char((v >> (8 * i)) & 0xFF);
    return s;
}
inline std::string str8(const std::string &s) { return be(uint32_t(s.size()), 1) + s; }
inline std::string str16(const std::string &s) { return be(uint32_t(s.size()), 2) + s; }

/* computer <-> relay, and connector <-> relay */
inline std::string enc_hello(const std::string &addr, const std::string &cached = "",
                             int version = PROTOCOL_VERSION) {
    return "H" + be(version, 1) + str8(addr) + str8(cached);
}
inline std::string enc_ext(const std::string &hash, const std::string *code) {
    std::string f = "E" + str8(hash) + be(code ? 1 : 0, 1);
    if (code)
        f += be(uint32_t(code->size()), 4) + *code;
    return f;
}
inline std::string enc_data(int ch, const std::string &bytes) {
    return "D" + be(ch, 1) + str16(bytes);
}
inline std::string enc_gone(int ch) { return "G" + be(ch, 1); }
inline std::string enc_attach(const std::string &addr) { return "A" + str8(addr); }
inline std::string enc_list(const std::vector<std::string> &addrs) {
    std::string f = "L" + be(uint32_t(addrs.size()), 1);
    for (const std::string &a : addrs)
        f += str8(a);
    return f;
}

/* connector <-> loader */
inline std::string enc_open(const std::string &name, const std::string &hash,
                            const std::string *code) {
    std::string f = "O" + str8(name) + str8(hash) + be(code ? 1 : 0, 1);
    if (code)
        f += be(uint32_t(code->size()), 4) + *code;
    return f;
}
inline std::string enc_opened(int status, bool hit, const std::string &msg) {
    return "P" + be(status, 1) + be(hit ? 1 : 0, 1) + str16(msg);
}
inline std::string enc_zone_data(const std::string &bytes) { return "d" + str16(bytes); }
inline std::string enc_zone_end(const std::string &why) { return "x" + str16(why); }
inline std::string enc_zones_ask() { return "Z"; }
inline std::string enc_terminate(const std::string &name) { return "T" + str8(name); }
inline std::string enc_zones(const std::vector<std::string> &names) {
    std::string f = "z" + be(uint32_t(names.size()), 1);
    for (const std::string &n : names)
        f += str8(n);
    return f;
}

/* the terminal zone */
inline std::string enc_resize(int w, int h) { return "R" + be(w, 2) + be(h, 2); }
inline std::string enc_set(int x, int y, uint32_t fg, uint32_t bg, bool v, const std::string &t) {
    return "S" + be(uint16_t(x), 2) + be(uint16_t(y), 2) + be(fg, 3) + be(bg, 3) + be(v, 1)
         + be(uint32_t(t.size()), 2) + t;
}
inline std::string enc_fill(int x, int y, int w, int h, uint32_t fg, uint32_t bg,
                            const std::string &ch) {
    return "F" + be(uint16_t(x), 2) + be(uint16_t(y), 2) + be(uint16_t(w), 2)
         + be(uint16_t(h), 2) + be(fg, 3) + be(bg, 3) + str8(ch);
}
inline std::string enc_copy(int x, int y, int w, int h, int tx, int ty) {
    return "C" + be(uint16_t(x), 2) + be(uint16_t(y), 2) + be(uint16_t(w), 2)
         + be(uint16_t(h), 2) + be(uint16_t(tx), 2) + be(uint16_t(ty), 2);
}

inline std::string enc_window(int w, int h) { return "W" + be(w, 2) + be(h, 2); }

/*! Returns the 'K' frame that carries one key signal to the computer. */
inline std::string key_frame(const oc_key_t &k) {
    return "K" + be(k.down ? 1 : 0, 1) + be(k.ch, 4) + be(k.code, 2);
}

/*! Returns FNV-1a 64 of `bytes` as 16 hex digits: the name a payload is cached under. The
 * computer never computes it, only files the code under it, so Lua's lack of 64-bit integers on
 * the 5.2 architecture does not matter. */
inline std::string payload_hash(const std::string &bytes) {
    uint64_t h = 0xcbf29ce484222325ull;
    for (unsigned char c : bytes) {
        h ^= c;
        h *= 0x100000001b3ull;
    }
    char hex[17];
    snprintf(hex, sizeof(hex), "%016llx", (unsigned long long)h);
    return hex;
}
