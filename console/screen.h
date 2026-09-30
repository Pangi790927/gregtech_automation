/*! screen.h - the computer's screen as the console keeps it: a grid of cells that the computer's
 * frames change, drawn onto the Windows console with VT sequences.
 *
 * The grid is the computer's own, not a log that scrolls. OpenComputers draws a fixed grid and a
 * program repaints only the cells it changes (simulator/CLAUDE.md records what treating a screen
 * as a scrolling log cost), so every operation lands on exact cells and only the rows it touched
 * are drawn again. There is no cursor either: OpenOS draws one by swapping a cell's two colours,
 * and that arrives here as an ordinary set.
 *
 * Coordinates in the public functions are OpenComputers' own: 1-based, and allowed to start off
 * the grid, since a program may draw text that begins left of the first column.
 *
 * @date 2026-09-30 */

#pragma once

#include <algorithm>
#include <cstdint>
#include <string>
#include <vector>

/*! One character cell, with its two colours as 0xRRGGBB. */
struct cell_t {
    char32_t ch = U' ';
    uint32_t fg = 0xFFFFFF;
    uint32_t bg = 0x000000;
};

/*! Decodes UTF-8 into code points; a malformed byte becomes U+FFFD rather than stopping. */
inline std::u32string utf8_decode(const uint8_t *p, size_t n) {
    std::u32string out;
    for (size_t i = 0; i < n;) {
        uint8_t b = p[i];
        int extra = b < 0x80 ? 0 : b >= 0xF0 ? 3 : b >= 0xE0 ? 2 : b >= 0xC0 ? 1 : -1;
        if (extra < 0 || i + extra >= n) {
            out += U'�';
            i++;
            continue;
        }
        char32_t cp = extra == 0 ? b : b & (0x3F >> extra);
        for (int k = 1; k <= extra; k++)
            cp = (cp << 6) | (p[i + k] & 0x3F);
        out += cp;
        i += extra + 1;
    }
    return out;
}

/*! Appends one code point to `out` as UTF-8. */
inline void utf8_encode(std::string &out, char32_t cp) {
    if (cp < 0x80) {
        out += char(cp);
    } else if (cp < 0x800) {
        out += char(0xC0 | (cp >> 6));
        out += char(0x80 | (cp & 0x3F));
    } else if (cp < 0x10000) {
        out += char(0xE0 | (cp >> 12));
        out += char(0x80 | ((cp >> 6) & 0x3F));
        out += char(0x80 | (cp & 0x3F));
    } else {
        out += char(0xF0 | (cp >> 18));
        out += char(0x80 | ((cp >> 12) & 0x3F));
        out += char(0x80 | ((cp >> 6) & 0x3F));
        out += char(0x80 | (cp & 0x3F));
    }
}

struct screen_t {
    int w = 0;
    int h = 0;
    std::vector<cell_t> cells;
    std::vector<bool> dirty;    /*!< one per row: drawn again by the next render() */
    bool cleared = true;        /*!< the whole console is wiped before the next render() */

    /*! Changes the size, keeping the cells both sizes share, and has everything drawn again. */
    void resize(int nw, int nh) {
        std::vector<cell_t> next(size_t(nw) * nh);
        for (int y = 0; y < std::min(h, nh); y++)
            for (int x = 0; x < std::min(w, nw); x++)
                next[size_t(y) * nw + x] = cells[size_t(y) * w + x];
        w = nw;
        h = nh;
        cells.swap(next);
        dirty.assign(h, true);
        cleared = true;
    }

    /*! Returns the cell at OpenComputers' (x, y), or null when it is off the grid. */
    cell_t *at(int x, int y) {
        if (x < 1 || y < 1 || x > w || y > h)
            return nullptr;
        return &cells[size_t(y - 1) * w + (x - 1)];
    }

    /*! Writes `text` from (x, y) rightwards, or downwards when `vertical`, as gpu.set does. */
    void set(int x, int y, uint32_t fg, uint32_t bg, bool vertical, const std::u32string &text) {
        for (char32_t ch : text) {
            put(x, y, {ch, fg, bg});
            (vertical ? y : x)++;
        }
    }

    /*! Fills a rectangle with one character, as gpu.fill does. */
    void fill(int x, int y, int fw, int fh, uint32_t fg, uint32_t bg, char32_t ch) {
        for (int j = 0; j < fh; j++)
            for (int i = 0; i < fw; i++)
                put(x + i, y + j, {ch, fg, bg});
    }

    /*! Copies a rectangle to (x + tx, y + ty), as gpu.copy does: the source is read whole first,
     * so a copy onto itself (scrolling) sees the old cells, not ones it already moved. */
    void copy(int x, int y, int cw, int ch, int tx, int ty) {
        if (cw <= 0 || ch <= 0)
            return;
        std::vector<cell_t> src(size_t(cw) * ch);
        std::vector<bool> valid(src.size(), false);
        for (int j = 0; j < ch; j++)
            for (int i = 0; i < cw; i++)
                if (cell_t *c = at(x + i, y + j)) {
                    src[size_t(j) * cw + i] = *c;
                    valid[size_t(j) * cw + i] = true;
                }
        for (int j = 0; j < ch; j++)
            for (int i = 0; i < cw; i++)
                if (valid[size_t(j) * cw + i])
                    put(x + i + tx, y + j + ty, src[size_t(j) * cw + i]);
    }

    /*! Returns the VT sequences that bring a console of `max_w` x `max_h` up to date, and marks it
     * so. Nothing is drawn outside that: a row below the window's bottom lands on its last row and
     * scrolls the whole window, which once pushed OpenOS's banner off the top and scattered copies
     * of the prompt. */
    std::string render(int max_w = 1 << 16, int max_h = 1 << 16) {
        std::string out;
        if (cleared)
            out += "\x1b[0m\x1b[2J";
        cleared = false;
        for (int y = 0; y < h; y++) {
            if (!dirty[y])
                continue;
            dirty[y] = false;
            if (y >= max_h)
                continue;
            out += "\x1b[" + std::to_string(y + 1) + ";1H";
            uint32_t fg = ~0u, bg = ~0u;
            for (int x = 0; x < std::min(w, max_w); x++) {
                const cell_t &c = cells[size_t(y) * w + x];
                if (c.fg != fg)
                    out += sgr(38, fg = c.fg);
                if (c.bg != bg)
                    out += sgr(48, bg = c.bg);
                utf8_encode(out, c.ch < 0x20 || c.ch == 0x7F ? U' ' : c.ch);
            }
        }
        return out;
    }

    /*! Has the next render() draw everything again, from a cleared console. */
    void redraw() {
        dirty.assign(h, true);
        cleared = true;
    }

private:
    void put(int x, int y, cell_t c) {
        if (cell_t *dst = at(x, y)) {
            *dst = c;
            dirty[y - 1] = true;
        }
    }

    /*! Returns the SGR sequence for a 24-bit colour; `which` is 38 (text) or 48 (background). */
    static std::string sgr(int which, uint32_t rgb) {
        return "\x1b[" + std::to_string(which) + ";2;" + std::to_string((rgb >> 16) & 0xFF) + ";" +
               std::to_string((rgb >> 8) & 0xFF) + ";" + std::to_string(rgb & 0xFF) + "m";
    }
};
