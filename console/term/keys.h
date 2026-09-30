/*! keys.h - turns what the Windows console reads into the key signals OpenComputers' keyboard
 * would have sent.
 *
 * The console is read the way colib reads anything, an overlapped ReadFile completing on its IOCP,
 * and in that mode Windows hands over characters and VT sequences (ESC [ A for Up), not scancodes.
 * Programs on the computer tell keys apart by scancode: bin/edit.lua matches its keymap with
 * `code == keyboard.keys[key]`, and lib/core/cursor.lua leaves `lua` on Ctrl plus `code ==
 * keys.d`. So every key is given the scancode of OpenOS's lib/core/full_keyboard.lua (PC set 1,
 * extended keys with 0x80 added), a US layout is assumed for printable characters, and a key
 * pressed with Ctrl, Alt or Shift is sent inside that modifier's own down and up, because
 * keyboard.isControlDown() reads the modifier's pressed state rather than the character.
 *
 * Ctrl+D is the terminal's own key: it never goes to the computer, it disconnects the terminal.
 * Ctrl+C is not special here; it goes to the computer like any key, to the program in its shell.
 * octerm itself ends only on `octerm stop`.
 *
 * @date 2026-09-30 */

#pragma once

#include <cstdint>
#include <cstdlib>
#include <string>
#include <vector>

#include "protocol.h"

/* Prefixed: winnt.h defines DELETE as a macro. */
namespace oc_keys {
constexpr uint16_t K_ESCAPE = 0x01, K_BACK = 0x0E, K_TAB = 0x0F, K_ENTER = 0x1C;
constexpr uint16_t K_LCONTROL = 0x1D, K_LSHIFT = 0x2A, K_LMENU = 0x38;
constexpr uint16_t K_UP = 0xC8, K_DOWN = 0xD0, K_LEFT = 0xCB, K_RIGHT = 0xCD;
constexpr uint16_t K_HOME = 0xC7, K_END = 0xCF;
constexpr uint16_t K_PAGE_UP = 0xC9, K_PAGE_DOWN = 0xD1, K_INSERT = 0xD2, K_DELETE = 0xD3;
constexpr uint16_t K_F1 = 0x3B, K_F11 = 0x57, K_F12 = 0x58;
constexpr char K_QUIT = 0x04;     /* Ctrl+D */
}

/*! Returns the scancode of the key that types printable ASCII `c` on a US keyboard, or 0. */
inline uint16_t ascii_scancode(char c) {
    struct entry_t { const char *chars; uint16_t code; };
    static const entry_t table[] = {
        {"1!", 0x02}, {"2@", 0x03}, {"3#", 0x04}, {"4$", 0x05}, {"5%", 0x06}, {"6^", 0x07},
        {"7&", 0x08}, {"8*", 0x09}, {"9(", 0x0A}, {"0)", 0x0B}, {"-_", 0x0C}, {"=+", 0x0D},
        {"qQ", 0x10}, {"wW", 0x11}, {"eE", 0x12}, {"rR", 0x13}, {"tT", 0x14}, {"yY", 0x15},
        {"uU", 0x16}, {"iI", 0x17}, {"oO", 0x18}, {"pP", 0x19}, {"[{", 0x1A}, {"]}", 0x1B},
        {"aA", 0x1E}, {"sS", 0x1F}, {"dD", 0x20}, {"fF", 0x21}, {"gG", 0x22}, {"hH", 0x23},
        {"jJ", 0x24}, {"kK", 0x25}, {"lL", 0x26}, {";:", 0x27}, {"'\"", 0x28}, {"`~", 0x29},
        {"\\|", 0x2B}, {"zZ", 0x2C}, {"xX", 0x2D}, {"cC", 0x2E}, {"vV", 0x2F}, {"bB", 0x30},
        {"nN", 0x31}, {"mM", 0x32}, {",<", 0x33}, {".>", 0x34}, {"/?", 0x35}, {" ", 0x39},
    };
    for (const entry_t &e : table)
        for (const char *p = e.chars; *p; p++)
            if (*p == c)
                return e.code;
    return 0;
}

/*! Returns the scancode a CSI sequence ending in `final` with first parameter `num` stands for,
 * or 0 for one that names no key OpenComputers knows. */
inline uint16_t csi_scancode(char final, int num) {
    using namespace oc_keys;
    switch (final) {
    case 'A': return K_UP;
    case 'B': return K_DOWN;
    case 'C': return K_RIGHT;
    case 'D': return K_LEFT;
    case 'H': return K_HOME;
    case 'F': return K_END;
    case 'P': case 'Q': case 'R': case 'S': return uint16_t(K_F1 + (final - 'P'));
    case '~': break;
    default: return 0;
    }
    switch (num) {
    case 1: case 7: return K_HOME;
    case 2: return K_INSERT;
    case 3: return K_DELETE;
    case 4: case 8: return K_END;
    case 5: return K_PAGE_UP;
    case 6: return K_PAGE_DOWN;
    case 11: case 12: case 13: case 14: return uint16_t(K_F1 + (num - 11));
    case 15: return 0x3F;
    case 17: case 18: case 19: case 20: case 21: return uint16_t(0x40 + (num - 17));
    case 23: return K_F11;
    case 24: return K_F12;
    default: return 0;
    }
}

struct key_decoder_t {
    bool quit = false;  /*!< set once Ctrl+D has been read */

    /*! Returns the key signals for the bytes one console read returned. A read returns whole
     * sequences, so an ESC that ends it is the Escape key itself rather than a sequence cut in
     * two. */
    std::vector<oc_key_t> feed(const char *p, size_t n) {
        out.clear();
        for (size_t i = 0; i < n && !quit;)
            i += p[i] == 0x1B ? escape(p + i, n - i) : single(p + i, n - i);
        return out;
    }

private:
    std::vector<oc_key_t> out;

    void press(uint32_t ch, uint16_t code, uint16_t mod = 0) {
        if (mod)
            out.push_back({true, 0, mod});
        out.push_back({true, ch, code});
        out.push_back({false, ch, code});
        if (mod)
            out.push_back({false, 0, mod});
    }

    /*! Decodes one key that does not start with ESC; returns the bytes it used. */
    size_t single(const char *p, size_t n) {
        using namespace oc_keys;
        uint8_t b = uint8_t(p[0]);
        if (b == K_QUIT)
            quit = true;
        else if (b == '\r' || b == '\n')
            press('\r', K_ENTER);
        else if (b == '\t')
            press('\t', K_TAB);
        else if (b == 0x7F || b == 0x08)
            press(0x08, K_BACK);
        else if (b >= 0x01 && b <= 0x1A)
            press(b, ascii_scancode(char('a' + b - 1)), K_LCONTROL);
        else if (b >= 0x20 && b < 0x7F)
            press(b, ascii_scancode(char(b)));
        else if (b >= 0x80)
            return utf8(p, n, 0);
        return 1;
    }

    /*! Decodes a non-ASCII character typed as UTF-8, sent with no scancode, as OpenComputers does
     * for characters its keyboard has no key for. Returns the bytes it used. */
    size_t utf8(const char *p, size_t n, uint16_t mod) {
        uint8_t b = uint8_t(p[0]);
        size_t len = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : b >= 0xC0 ? 2 : 1;
        len = std::min(len, n);
        std::u32string cp = utf8_decode(reinterpret_cast<const uint8_t *>(p), len);
        if (!cp.empty())
            press(uint32_t(cp[0]), 0, mod);
        return len;
    }

    /*! Decodes a key that starts with ESC: a CSI or SS3 sequence, Alt plus a key, or Escape
     * alone. Returns the bytes it used. */
    size_t escape(const char *p, size_t n) {
        using namespace oc_keys;
        if (n == 1) {
            press(0x1B, K_ESCAPE);
            return 1;
        }
        if (p[1] == 'O' && n >= 3) {
            if (uint16_t code = csi_scancode(p[2], 1))
                press(0, code);
            return 3;
        }
        if (p[1] != '[') {
            size_t used = uint8_t(p[1]) >= 0x80 ? utf8(p + 1, n - 1, K_LMENU) : alt(p[1]);
            return 1 + used;
        }
        size_t i = 2;
        while (i < n && p[i] >= 0x30 && p[i] <= 0x3F)
            i++;
        if (i >= n)
            return n;   /* cut short: nothing a key could be read from */
        std::string params(p + 2, p + i);
        int num = std::atoi(params.c_str());
        size_t semi = params.find(';');
        int mods = semi == std::string::npos ? 1 : std::atoi(params.c_str() + semi + 1);
        if (p[i] == 'Z')
            press('\t', K_TAB, K_LSHIFT);
        else if (uint16_t code = csi_scancode(p[i], num))
            press(0, code, modifier(mods));
        return i + 1;
    }

    /*! Presses the ASCII key `c` inside Alt; returns the bytes used, which is one. */
    size_t alt(char c) {
        press(uint8_t(c), ascii_scancode(c), oc_keys::K_LMENU);
        return 1;
    }

    /*! Returns the modifier key for xterm's parameter (1 + shift 1, alt 2, ctrl 4), or 0. Only one
     * is sent: Ctrl wins, then Alt, then Shift. */
    static uint16_t modifier(int mods) {
        int bits = mods - 1;
        if (bits & 4)
            return oc_keys::K_LCONTROL;
        if (bits & 2)
            return oc_keys::K_LMENU;
        if (bits & 1)
            return oc_keys::K_LSHIFT;
        return 0;
    }
};
