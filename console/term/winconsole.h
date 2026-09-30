/*! winconsole.h - taking over the Windows console window for the terminal, and giving it back.
 *
 * The window is read the way colib reads any handle: CONIN$ opened with FILE_FLAG_OVERLAPPED
 * attaches to the pool's IOCP and its overlapped ReadFile completes there, which was tried in a
 * scratch program before it was relied on. No thread of its own is needed.
 *
 * Needs colib.h included first, for the Windows headers.
 *
 * @date 2026-09-30 */

#pragma once

#include <string>

/*! The console window: its handles, and the modes it had, to put back on the way out. */
struct console_t {
    HANDLE in = INVALID_HANDLE_VALUE;
    HANDLE out = INVALID_HANDLE_VALUE;
    DWORD in_mode = 0;
    DWORD out_mode = 0;
    UINT in_cp = 0;
    UINT out_cp = 0;
    bool open = false;
};
inline console_t con;

/*! Writes to the console window, when it has been taken over. */
inline void con_write(const std::string &s) {
    if (!con.open || s.empty())
        return;
    DWORD n = 0;
    WriteFile(con.out, s.data(), DWORD(s.size()), &n, NULL);
}

/*! Returns the visible size of the console window, in cells; false when there is no window. */
inline bool con_size(int &w, int &h) {
    CONSOLE_SCREEN_BUFFER_INFO info;
    if (!con.open || !GetConsoleScreenBufferInfo(con.out, &info))
        return false;
    w = info.srWindow.Right - info.srWindow.Left + 1;
    h = info.srWindow.Bottom - info.srWindow.Top + 1;
    return true;
}

/*! Takes over the console window: raw VT input with no echo and no line editing, so every key
 * arrives as typed (Ctrl+C included, as a character), VT output in UTF-8, the alternate screen so
 * the shell's own text comes back untouched afterwards, no cursor (the computer draws its own),
 * and no wrapping, so a screen wider than the window is cut rather than folded. Returns false
 * when there is no console to take. */
inline bool console_open() {
    con.out = GetStdHandle(STD_OUTPUT_HANDLE);
    con.in = CreateFileW(L"CONIN$", GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, NULL);
    if (con.in == INVALID_HANDLE_VALUE || !GetConsoleMode(con.in, &con.in_mode)
            || !GetConsoleMode(con.out, &con.out_mode))
        return false;
    con.in_cp = GetConsoleCP();
    con.out_cp = GetConsoleOutputCP();
    SetConsoleMode(con.in, ENABLE_VIRTUAL_TERMINAL_INPUT);
    SetConsoleMode(con.out, ENABLE_PROCESSED_OUTPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING
            | DISABLE_NEWLINE_AUTO_RETURN);
    SetConsoleCP(CP_UTF8);
    SetConsoleOutputCP(CP_UTF8);
    con.open = true;
    con_write("\x1b[?1049h\x1b[?25l\x1b[?7l\x1b[0m\x1b[2J\x1b[H");
    return true;
}

/*! Gives the console window back as it was found. Safe to call twice. */
inline void console_close() {
    if (!con.open)
        return;
    con_write("\x1b[0m\x1b[?7h\x1b[?25h\x1b[?1049l");
    con.open = false;
    SetConsoleMode(con.in, con.in_mode);
    SetConsoleMode(con.out, con.out_mode);
    SetConsoleCP(con.in_cp);
    SetConsoleOutputCP(con.out_cp);
}

/*! Puts the console back when the window is closed or Ctrl+Break is pressed, then lets Windows
 * end the process as it would have. */
inline BOOL WINAPI on_console_event(DWORD) {
    console_close();
    return FALSE;
}
