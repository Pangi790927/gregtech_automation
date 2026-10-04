/*! ocscp.cpp - ocscp's program: copies one file between the PC and a computer on the relay.
 *
 *     ocscp.exe get <path on the computer> [local path]   without a local path, to stdout
 *     ocscp.exe put <local path> <path on the computer>
 *     ... --computer <address start>     the computer, when several are on the relay
 *     ... --port <n>                     the relay's connector port, default 7778, at relay_host()
 *
 * What happened goes to stderr, so stdout carries the file alone; the exit code is 0 when the
 * file was copied. Its payload, ocscp.lua, is read from beside it. See ocscp.h.
 *
 * @date 2026-10-01 */

#define COLIB_ENABLE_LOGGING false
#define _WIN32_WINNT 0x0A00
#include "colib.h"

#include <fcntl.h>
#include <io.h>

#include "ocscp.h"

static colib::task_t scp_main(uint16_t port) {
    SOCKET s = co_await connect_relay(port);
    if (s == INVALID_SOCKET) {
        scp.conn.goodbye = "no relay on " + relay_host() + ":" + std::to_string(port)
                         + "; start the relay first";
        co_await colib::force_stop(0);
        co_return 0;
    }
    scp.conn.out = co_await open_sender(s);
    co_await colib::sched(scp_session(s));
    co_return 0;
}

static int usage() {
    fprintf(stderr, "usage: ocscp.exe get <path on the computer> [local path]\n"
                    "       ocscp.exe put <local path> <path on the computer>\n"
                    "       ... --computer <address start>  --port <relay's connector port>\n");
    return 2;
}

int main(int argc, char const *argv[]) {
    uint16_t port = 7778;
    std::vector<std::string> args;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "--port" && i + 1 < argc)
            port = uint16_t(atoi(argv[++i]));
        else if (a == "--computer" && i + 1 < argc)
            scp.conn.prefix = argv[++i];
        else
            args.push_back(a);
    }
    if (args.size() >= 2 && args.size() <= 3 && args[0] == "get") {
        scp.oc_path = args[1];
        scp.local_path = args.size() == 3 ? args[2] : "";
    } else if (args.size() == 3 && args[0] == "put") {
        scp.get = false;
        scp.local_path = args[1];
        scp.oc_path = args[2];
        if (!read_file(scp.local_path, scp.data)) {
            fprintf(stderr, "ocscp: cannot read %s\n", scp.local_path.c_str());
            return 1;
        }
    } else {
        return usage();
    }
    scp_init();
    if (!load_payload(scp.conn, "ocscp.lua")) {
        fprintf(stderr, "ocscp: ocscp.lua is not beside ocscp.exe\n");
        return 1;
    }
    _setmode(_fileno(stdout), _O_BINARY);      /* the file's bytes, not text with \r added */

    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
    colib::pool_p pool = colib::create_pool();
    pool->sched(scp_main(port));
    pool->run();
    fprintf(stderr, "ocscp: %s\n", scp.conn.goodbye.c_str());
    return scp.done ? 0 : 1;
}
