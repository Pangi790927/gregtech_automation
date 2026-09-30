/*! conhelp.cpp - lets Claude use term.exe: types into another process's console window, and reads
 * back what that window shows.
 *
 *     conhelp.exe keys <pid> <key>...          types keys, one per 100 ms, as a person would
 *     conhelp.exe read <pid> <rows> <cols> <file> [tail]
 *                                              writes the window's text to <file>, UTF-8; with
 *                                              tail, the rows that end at the cursor
 *
 * A key is one character, or one of ENTER, SPACE, TAB, ESC, UP, DEL, CTRL+C, CTRL+D, CTRL+S. It is
 * written into the console's input the way the keyboard puts it there, so term.exe reads it
 * through its usual path, VT translation included. It works on any console process, which is
 * also how the relay's log is read.
 *
 * It detaches from its own console to attach to the target's, so its output goes to <file> and
 * its exit code says what failed: 2 bad arguments, 3 no such console. console/term/DESIGN.md,
 * "Using it from Claude", has the whole recipe. A first version; the user means to replace it
 * with something more capable.
 *
 * @date 2026-09-30 */

#define NOMINMAX
#include <windows.h>

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

/*! Appends a key's press and release, as the keyboard would record them. */
static void add_key(std::vector<INPUT_RECORD> &v, wchar_t ch, WORD vk, WORD scan, DWORD ctrl) {
    for (int down = 1; down >= 0; down--) {
        INPUT_RECORD r = {};
        r.EventType = KEY_EVENT;
        r.Event.KeyEvent.bKeyDown = down;
        r.Event.KeyEvent.wRepeatCount = 1;
        r.Event.KeyEvent.uChar.UnicodeChar = ch;
        r.Event.KeyEvent.wVirtualKeyCode = vk;
        r.Event.KeyEvent.wVirtualScanCode = scan;
        r.Event.KeyEvent.dwControlKeyState = ctrl;
        v.push_back(r);
    }
}

/*! Appends the records for one named key or single character; false if it is neither. */
static bool name_key(std::vector<INPUT_RECORD> &v, const std::string &k) {
    if (k == "ENTER")       add_key(v, '\r', VK_RETURN, 0x1C, 0);
    else if (k == "SPACE")  add_key(v, ' ', VK_SPACE, 0x39, 0);
    else if (k == "TAB")    add_key(v, '\t', VK_TAB, 0x0F, 0);
    else if (k == "ESC")    add_key(v, 0x1B, VK_ESCAPE, 0x01, 0);
    else if (k == "UP")     add_key(v, 0, VK_UP, 0x48, ENHANCED_KEY);
    else if (k == "DEL")    add_key(v, 0, VK_DELETE, 0x53, ENHANCED_KEY);
    else if (k == "CTRL+C") add_key(v, 0x03, 'C', 0x2E, LEFT_CTRL_PRESSED);
    else if (k == "CTRL+D") add_key(v, 0x04, 'D', 0x20, LEFT_CTRL_PRESSED);
    else if (k == "CTRL+S") add_key(v, 0x13, 'S', 0x1F, LEFT_CTRL_PRESSED);
    else if (k.size() == 1) {
        SHORT vk = VkKeyScanW(wchar_t(k[0]));
        DWORD ctrl = (vk & 0x100) ? SHIFT_PRESSED : 0;
        add_key(v, wchar_t(k[0]), vk & 0xFF, WORD(MapVirtualKeyW(vk & 0xFF, MAPVK_VK_TO_VSC)),
                ctrl);
    } else {
        return false;
    }
    return true;
}

static int type_keys(int argc, char **argv) {
    HANDLE in = CreateFileW(L"CONIN$", GENERIC_READ | GENERIC_WRITE,
                            FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
    for (int i = 3; i < argc; i++) {
        std::vector<INPUT_RECORD> v;
        if (!name_key(v, argv[i]))
            return 2;
        DWORD n = 0;
        WriteConsoleInputW(in, v.data(), DWORD(v.size()), &n);
        Sleep(100);
    }
    return 0;
}

static int read_text(int argc, char **argv) {
    if (argc < 6)
        return 2;
    HANDLE out = CreateFileW(L"CONOUT$", GENERIC_READ | GENERIC_WRITE,
                             FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
    int rows = atoi(argv[3]), cols = atoi(argv[4]), first = 0;
    if (argc > 6 && !strcmp(argv[6], "tail")) {
        CONSOLE_SCREEN_BUFFER_INFO info;
        GetConsoleScreenBufferInfo(out, &info);
        first = std::max(0, info.dwCursorPosition.Y + 1 - rows);
    }
    FILE *f = fopen(argv[5], "wb");
    if (!f)
        return 2;
    for (int y = first; y < first + rows; y++) {
        std::wstring line(cols, L' ');
        DWORD n = 0;
        ReadConsoleOutputCharacterW(out, line.data(), cols, {0, SHORT(y)}, &n);
        std::string utf8(size_t(cols) * 4, '\0');
        int len = WideCharToMultiByte(CP_UTF8, 0, line.data(), cols, utf8.data(),
                                      int(utf8.size()), NULL, NULL);
        fwrite(utf8.data(), 1, size_t(len), f);
        fputc('\n', f);
    }
    fclose(f);
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 3)
        return 2;
    FreeConsole();
    if (!AttachConsole(DWORD(atoi(argv[2]))))
        return 3;
    if (!strcmp(argv[1], "keys"))
        return type_keys(argc, argv);
    if (!strcmp(argv[1], "read"))
        return read_text(argc, argv);
    return 2;
}
