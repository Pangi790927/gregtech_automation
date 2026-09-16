#ifndef OC_SCREEN_H
#define OC_SCREEN_H

/*! oc_screen.h - the character grid behind a `screen` component, and what a `gpu` draws into it.
 *
 * Core: an OpenComputers screen is a grid of characters, each with its own foreground and
 * background colour. The gpu does not own it - a gpu is bound to a screen and writes into whatever
 * it is bound to, which is why the buffer lives here and both components hold a reference to it.
 *
 * Text is stored per cell as a Unicode code point rather than as bytes, because the grid is
 * addressed in characters: `gpu.set(1, 1, "hello")` occupies five cells whatever those characters
 * encode to. Turning the grid back into strings for the interface is the one place UTF-8 is built.
 *
 * @date 2026-09-17 */

#include <cstdint>
#include <string>
#include <vector>

namespace oc_screen {

/*! One cell of the grid. @date 2026-09-17 */
struct cell_t {
    uint32_t ch = ' ';
    uint32_t fg = 0xffffff;
    uint32_t bg = 0x000000;
};

/*! A screen's contents, and the colours a gpu is currently drawing with.
 *
 * The pen - `fg` and `bg` - belongs here rather than on the gpu because in OpenComputers it
 * survives rebinding and is what `getForeground` answers; a caller sets a colour once and every
 * later write uses it.
 *
 * @date 2026-09-17 */
struct buffer_t {
    int w = 80;
    int h = 25;
    int max_w = 160;
    int max_h = 50;
    int depth = 8;
    std::vector<cell_t> cells;

    uint32_t fg = 0xffffff;
    uint32_t bg = 0x000000;
    bool on = true;

    buffer_t() { resize(w, h); }

    bool in_bounds(int x, int y) const { return x >= 1 && y >= 1 && x <= w && y <= h; }
    cell_t &at(int x, int y) { return cells[(size_t)(y - 1) * (size_t)w + (size_t)(x - 1)]; }
    const cell_t &at(int x, int y) const {
        return cells[(size_t)(y - 1) * (size_t)w + (size_t)(x - 1)];
    }

    /*! Changes the resolution, clearing the grid.
     *
     * Clearing is what the real component does: a resolution change is not a reflow, it is a new
     * screen. Anything drawn before it is gone, and OpenOS redraws.
     * @date 2026-09-17 */
    void resize(int nw, int nh) {
        if (nw < 1) nw = 1;
        if (nh < 1) nh = 1;
        if (nw > max_w) nw = max_w;
        if (nh > max_h) nh = max_h;
        w = nw;
        h = nh;
        cells.assign((size_t)w * (size_t)h, cell_t{' ', fg, bg});
    }

    /*! Writes a run of characters starting at (x, y), across or downwards.
     *
     * Anything falling outside the grid is dropped rather than wrapped. OpenComputers does not wrap
     * either - a caller that writes past the edge loses the overflow, and OpenOS relies on that
     * when it draws a line exactly as wide as the screen.
     * @date 2026-09-17 */
    void write(int x, int y, const std::vector<uint32_t> &chars, bool vertical) {
        for (size_t i = 0; i < chars.size(); i++) {
            int cx = vertical ? x : x + (int)i;
            int cy = vertical ? y + (int)i : y;
            if (!in_bounds(cx, cy))
                continue;
            cell_t &c = at(cx, cy);
            c.ch = chars[i];
            c.fg = fg;
            c.bg = bg;
        }
    }

    /*! Fills a rectangle with one character in the current colours. @date 2026-09-17 */
    void fill(int x, int y, int fw, int fh, uint32_t ch) {
        for (int j = 0; j < fh; j++)
            for (int i = 0; i < fw; i++) {
                if (!in_bounds(x + i, y + j))
                    continue;
                cell_t &c = at(x + i, y + j);
                c.ch = ch;
                c.fg = fg;
                c.bg = bg;
            }
    }

    /*! Moves a rectangle by an offset, colours and all.
     *
     * Through a copy of the source, so overlapping regions come out right - which they must,
     * because this is how a terminal scrolls: the whole screen is copied one line upwards onto
     * itself.
     * @date 2026-09-17 */
    void copy(int x, int y, int cw, int ch, int tx, int ty) {
        std::vector<cell_t> src;
        src.reserve((size_t)std::max(0, cw) * (size_t)std::max(0, ch));
        for (int j = 0; j < ch; j++)
            for (int i = 0; i < cw; i++)
                src.push_back(in_bounds(x + i, y + j) ? at(x + i, y + j) : cell_t{});

        for (int j = 0; j < ch; j++)
            for (int i = 0; i < cw; i++) {
                int dx = x + i + tx;
                int dy = y + j + ty;
                if (!in_bounds(dx, dy))
                    continue;
                at(dx, dy) = src[(size_t)j * (size_t)cw + (size_t)i];
            }
    }

    /*! One row, as UTF-8, with trailing blanks trimmed.
     *
     * Trimmed because the interface draws these as lines of text: a row padded to eighty spaces
     * would push everything after it around for no reason.
     * @date 2026-09-17 */
    std::string row_text(int y) const {
        if (y < 1 || y > h)
            return {};

        int last = 0;
        for (int x = 1; x <= w; x++)
            if (at(x, y).ch != ' ' && at(x, y).ch != 0)
                last = x;

        std::string out;
        for (int x = 1; x <= last; x++) {
            uint32_t cp = at(x, y).ch;
            if (cp == 0)
                cp = ' ';
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
        return out;
    }
};

} /* namespace oc_screen */

#endif /* OC_SCREEN_H */
