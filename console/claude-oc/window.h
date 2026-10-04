/*! window.h - claude-oc.exe's console window: a log that scrolls, with the prompt being typed
 * kept on its last row.
 *
 * The keys are read raw (no echo, no line editing by Windows) and as VT sequences, so the arrows
 * arrive too, and term.exe's decoder (keys.h) turns them into OpenOS's key codes; Ctrl+C stays
 * Windows' own, so it ends the program as in the relay's window. The console is read like any
 * handle, CONIN$ opened overlapped, as term.exe reads its window. The prompt's open row is drawn
 * as "<label>> text" with the console's cursor where the next letter goes; what is printed goes
 * above it, and it is drawn again below. Letters go in at the cursor; Backspace and Delete take
 * out the character before and at it; Left, Right, Home and End move it; Enter sends the
 * prompt, or after a `\` starts a new row of it (as in Claude Code's own prompt); Backspace at
 * a row's start joins it to the one above; Ctrl+Left and Ctrl+Right are the owner's (claude-oc
 * switches computers with them). The modes are put back on the way out, Ctrl+C and closing
 * included.
 *
 * Needs colib.h included first.
 *
 * @date 2026-10-01 */

#pragma once

#include <cstdio>
#include <ctime>
#include <functional>
#include <string>
#include <vector>

#include "keys.h"

struct window_t {
    HANDLE in = INVALID_HANDLE_VALUE;
    HANDLE out = INVALID_HANDLE_VALUE;
    DWORD in_mode = 0, out_mode = 0;    /*!< the modes it had, to put back */
    bool raw = false;                   /*!< its keys are read here, and the line drawn */
    bool quiet = false;                 /*!< nothing printed: the tests' */
    key_decoder_t keys;
    bool ctrl = false;                  /*!< Ctrl is down, as the decoder's keys say */
    std::vector<std::string> rows;      /*!< the prompt's rows ended by `\` Enter, as UTF-8 */
    std::u32string row;                 /*!< its open row */
    size_t pos = 0;                     /*!< the cursor, in characters into the open row */
    std::function<void(const std::string &)> on_line;   /*!< a prompt was sent */
    std::function<void(int)> on_switch;                 /*!< Ctrl+Left -1, Ctrl+Right +1 */
    std::function<std::string()> label;                 /*!< what the first row starts with */
};
inline window_t win;

inline int window_width() {
    CONSOLE_SCREEN_BUFFER_INFO info;
    if (!GetConsoleScreenBufferInfo(win.out, &info))
        return 80;
    return info.srWindow.Right - info.srWindow.Left + 1;
}

inline std::string to_utf8(const std::u32string &s) {
    std::string out;
    for (char32_t c : s)
        utf8_encode(out, c);
    return out;
}

/*! Returns what an open row is drawn after: "<label>> " on a prompt's first row, ". " on the
 * rest. */
inline std::string row_mark() {
    return win.rows.empty() ? (win.label ? win.label() : std::string()) + "> " : ". ";
}

/*! Draws the open row over the last row of the window, the part around the cursor when it is
 * wider, and puts the console's cursor where the next letter goes. */
inline void draw_typed() {
    if (!win.raw || win.quiet)
        return;
    std::string mark = row_mark();
    size_t room = size_t(std::max(10, window_width() - 1 - int(mark.size())));
    size_t start = win.pos >= room ? win.pos - room + 1 : 0;
    std::u32string shown = win.row.substr(start, room);
    size_t after = shown.size() - (win.pos - start);
    printf("\r\x1b[2K%s%s", mark.c_str(), to_utf8(shown).c_str());
    if (after)
        printf("\x1b[%zuD", after);
}

/*! Prints text (ending in a newline) above the line being typed. */
inline void window_print(const std::string &text) {
    if (win.quiet)
        return;
    if (win.raw)
        fputs("\r\x1b[2K", stdout);
    fputs(text.c_str(), stdout);
    draw_typed();
}

/*! Writes a line to the window, after the time. */
inline void say(const std::string &line) {
    time_t now = time(NULL);
    char stamp[16];
    strftime(stamp, sizeof(stamp), "%H:%M:%S", localtime(&now));
    window_print(std::string(stamp) + "  " + line + "\n");
}

/*! Ends the open row, which stays printed, and opens the next: `\` then Enter. */
inline void new_row() {
    win.row.pop_back();
    if (win.raw && !win.quiet)
        printf("\r\x1b[2K%s%s\n", row_mark().c_str(), to_utf8(win.row).c_str());
    win.rows.push_back(to_utf8(win.row));
    win.row.clear();
    win.pos = 0;
}

/*! Sends the prompt typed, its rows joined by newlines, and starts an empty one. */
inline void send_typed() {
    std::string text;
    for (const std::string &r : win.rows)
        text += r + "\n";
    text += to_utf8(win.row);
    win.rows.clear();
    win.row.clear();
    win.pos = 0;
    while (!text.empty() && (text.back() == ' ' || text.back() == '\n'))
        text.pop_back();
    if (!text.empty() && win.on_line)
        win.on_line(text);
}

/*! Takes one key, as the window's header says. */
inline void take_key(const oc_key_t &k) {
    using namespace oc_keys;
    std::u32string &row = win.row;
    if (k.code == K_LCONTROL) {
        win.ctrl = k.down;
        return;
    }
    if (!k.down)
        return;
    if ((k.code == K_LEFT || k.code == K_RIGHT) && win.ctrl) {
        if (win.on_switch)
            win.on_switch(k.code == K_LEFT ? -1 : 1);
    } else if (k.code == K_ENTER && !row.empty() && row.back() == U'\\') {
        new_row();
    } else if (k.code == K_ENTER) {
        send_typed();
    } else if (k.code == K_BACK && win.pos > 0) {
        row.erase(--win.pos, 1);
    } else if (k.code == K_BACK && !win.rows.empty()) {
        std::string above = win.rows.back();
        win.rows.pop_back();
        std::u32string joined = utf8_decode(reinterpret_cast<const uint8_t *>(above.data()),
                                            above.size());
        win.pos = joined.size();
        row = joined + row;
    } else if (k.code == K_DELETE) {
        if (win.pos < row.size())
            row.erase(win.pos, 1);
    } else if (k.code == K_LEFT) {
        win.pos -= win.pos > 0;
    } else if (k.code == K_RIGHT) {
        win.pos += win.pos < row.size();
    } else if (k.code == K_HOME) {
        win.pos = 0;
    } else if (k.code == K_END) {
        win.pos = row.size();
    } else if (k.ch >= 32 && k.ch != 127) {
        row.insert(win.pos++, 1, char32_t(k.ch));
    }
}

/*! Takes what one read of the window returned, through term.exe's key decoder. */
inline void take_typed(const std::string &typed) {
    for (const oc_key_t &k : win.keys.feed(typed.data(), typed.size()))
        take_key(k);
    win.keys.quit = false;              /* Ctrl+D is term.exe's own key; here it types nothing */
    draw_typed();
}

/*! Returns text read from the console, in its input code page, as UTF-8. */
inline std::string console_to_utf8(const char *bytes, size_t n) {
    UINT cp = GetConsoleCP();
    int wn = MultiByteToWideChar(cp, 0, bytes, int(n), NULL, 0);
    std::wstring w(size_t(wn), L'\0');
    MultiByteToWideChar(cp, 0, bytes, int(n), w.data(), wn);
    int un = WideCharToMultiByte(CP_UTF8, 0, w.data(), wn, NULL, 0, NULL, NULL);
    std::string u(size_t(un), '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.data(), wn, u.data(), un, NULL, NULL);
    return u;
}

/*! Gives the window its modes back. Safe to call twice. */
inline void window_close() {
    if (!win.raw)
        return;
    win.raw = false;
    fputs("\r\x1b[2K", stdout);
    SetConsoleMode(win.in, win.in_mode);
    SetConsoleMode(win.out, win.out_mode);
}

/*! Puts the window back when Ctrl+C or closing ends the program, then lets Windows end it. */
inline BOOL WINAPI window_event(DWORD) {
    window_close();
    return FALSE;
}

/*! Takes the window's keys, as the header says; false when there is no console to take. */
inline bool window_open() {
    win.out = GetStdHandle(STD_OUTPUT_HANDLE);
    win.in = CreateFileW(L"CONIN$", GENERIC_READ | GENERIC_WRITE,
                         FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING,
                         FILE_FLAG_OVERLAPPED, NULL);
    if (win.in == INVALID_HANDLE_VALUE || !GetConsoleMode(win.in, &win.in_mode)
            || !GetConsoleMode(win.out, &win.out_mode))
        return false;
    SetConsoleMode(win.in, ENABLE_PROCESSED_INPUT | ENABLE_VIRTUAL_TERMINAL_INPUT);
    SetConsoleMode(win.out, win.out_mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
    SetConsoleCtrlHandler(window_event, TRUE);
    win.raw = true;
    return true;
}

/*! Reads the keys typed in the window until it has none to give. */
inline colib::task_t window_input() {
    if (!window_open()) {
        say("this window cannot be typed into; prompts come from the computers only");
        co_return 0;
    }
    draw_typed();
    char chunk[256];
    while (true) {
        SSIZE_T n = co_await colib::read(win.in, chunk, sizeof(chunk));
        if (n <= 0)
            break;
        take_typed(console_to_utf8(chunk, size_t(n)));
    }
    window_close();
    co_return 0;
}
