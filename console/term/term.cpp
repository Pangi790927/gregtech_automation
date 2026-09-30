/*! term.cpp - the terminal's program: a console window onto a computer, through the relay.
 *
 *     term.exe                       the terminal; Ctrl+D disconnects, ending its zone
 *     term.exe zones [address]       lists the zones open on the computer
 *     term.exe kill <zone> [address] terminates one
 *     ... --port <n>                 the relay's connector port, default 7778, on 127.0.0.1
 *
 * [address] is the start of a computer's address, needed only when several are connected. The
 * terminal's payload, term.lua, is read from beside term.exe. See term.h.
 *
 * @date 2026-09-30 */

/* colib's log goes to stdout, and stdout is the screen being shown. */
#define COLIB_ENABLE_LOGGING false
#define _WIN32_WINNT 0x0A00
#include "colib.h"

#include <fstream>
#include <sstream>

#include "term.h"

/*! Connects to the relay on 127.0.0.1; returns INVALID_SOCKET when it is not running. */
static colib::task<SOCKET> connect_relay(uint16_t port) {
    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    sockaddr_in a = {};
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a.sin_port = htons(port);
    if (co_await colib::connect(s, (sockaddr *)&a, sizeof(a)) != colib::ERROR_OK) {
        closesocket(s);
        co_return INVALID_SOCKET;
    }
    co_return s;
}

static colib::task_t term_main(uint16_t port, bool window) {
    SOCKET s = co_await connect_relay(port);
    if (s == INVALID_SOCKET) {
        term.goodbye = "no relay on 127.0.0.1:" + std::to_string(port) + "; start relay.exe first";
        co_await colib::force_stop(0);
        co_return 0;
    }
    term.out = co_await open_sender(s);
    co_await colib::sched(relay_session(s));
    if (window) {
        co_await colib::sched(term_input());
        co_await colib::sched(watch_window());
    }
    co_return 0;
}

/*! Reads term.lua from the folder term.exe is in; false when it is not there. */
static bool load_payload() {
    char path[MAX_PATH];
    DWORD n = GetModuleFileNameA(NULL, path, MAX_PATH);
    std::string dir(path, n);
    dir = dir.substr(0, dir.find_last_of("\\/") + 1);
    std::ifstream f(dir + "term.lua", std::ios::binary);
    if (!f)
        return false;
    std::stringstream ss;
    ss << f.rdbuf();
    term.code = ss.str();
    term.hash = payload_hash(term.code);
    return true;
}

int main(int argc, char const *argv[]) {
    uint16_t port = 7778;
    std::vector<std::string> args;
    for (int i = 1; i < argc; i++) {
        if (std::string(argv[i]) == "--port" && i + 1 < argc)
            port = uint16_t(atoi(argv[++i]));
        else
            args.push_back(argv[i]);
    }
    if (!args.empty() && (args[0] == "zones" || args[0] == "kill")) {
        term.command = args[0];
        size_t at = 1;
        if (term.command == "kill") {
            if (args.size() < 2) {
                fprintf(stderr, "term: kill needs the zone's name\n");
                return 1;
            }
            term.argument = args[at++];
        }
        term.prefix = args.size() > at ? args[at] : "";
    }
    bool window = term.command.empty();
    if (window && !load_payload()) {
        fprintf(stderr, "term: term.lua is not beside term.exe\n");
        return 1;
    }

    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
    if (window) {
        if (!console_open()) {
            fprintf(stderr, "term: this needs a console window to run in\n");
            return 1;
        }
        SetConsoleCtrlHandler(on_console_event, TRUE);
        con_write("connecting to the relay...");
    }

    colib::pool_p pool = colib::create_pool();
    pool->sched(term_main(port, window));
    pool->run();

    console_close();
    printf("term: %s\n", term.goodbye.c_str());
    return 0;
}
