/*! relay.cpp - the relay's program: stays up on the PC, keeps the computers connected, and
 * forwards between them and the connectors.
 *
 *     relay.exe [computer port [connector port]]      defaults 7777 and 7778
 *
 * Ctrl+C in its window stops it, and every connection with it. See relay.h.
 *
 * @date 2026-09-30 */

/* colib's log goes to stdout, which is the relay's own log here. */
#define COLIB_ENABLE_LOGGING false
/* Vista or later, so ws2tcpip.h declares inet_ntop: colib sets this only around its own
includes. */
#define _WIN32_WINNT 0x0A00
#include "colib.h"

#include "relay.h"

/*! Returns the folder relay.exe is in, with its trailing separator. */
static std::string exe_dir() {
    char path[MAX_PATH];
    DWORD n = GetModuleFileNameA(NULL, path, MAX_PATH);
    std::string dir(path, n);
    return dir.substr(0, dir.find_last_of("\\/") + 1);
}

int main(int argc, char const *argv[]) {
    uint16_t computer_port = argc > 1 ? uint16_t(atoi(argv[1])) : 7777;
    uint16_t connector_port = argc > 2 ? uint16_t(atoi(argv[2])) : 7778;
    relay.ext_file = exe_dir() + "octerm_ext.lua";
    std::string ext;
    if (!read_ext(ext))
        fprintf(stderr, "relay: warning: %s is missing; computers will be refused until it is "
                "there\n", relay.ext_file.c_str());
    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
    SOCKET computers = listen_on(INADDR_ANY, computer_port);
    if (computers == INVALID_SOCKET) {
        fprintf(stderr, "relay: cannot listen on port %d (error %d%s)\n", computer_port,
                WSAGetLastError(), WSAGetLastError() == WSAEADDRINUSE
                ? ": something else is using it, maybe another relay or the old console" : "");
        return 1;
    }
    SOCKET connectors = listen_on(INADDR_LOOPBACK, connector_port);
    if (connectors == INVALID_SOCKET) {
        fprintf(stderr, "relay: cannot listen on 127.0.0.1:%d (error %d%s)\n", connector_port,
                WSAGetLastError(), WSAGetLastError() == WSAEADDRINUSE
                ? ": something else is using it" : "");
        return 1;
    }
    relay_log("relay: computers on port " + std::to_string(computer_port) + ", connectors on "
            + "127.0.0.1:" + std::to_string(connector_port) + ", protocol "
            + std::to_string(PROTOCOL_VERSION) + ". Ctrl+C stops it.");

    colib::pool_p pool = colib::create_pool();
    pool->sched(relay_accept(computers, false));
    pool->sched(relay_accept(connectors, true));
    pool->run();
    return 0;
}
