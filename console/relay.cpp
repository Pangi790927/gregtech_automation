/*! relay.cpp - the relay's program: stays up, keeps the computers connected, and forwards between
 * them and the connectors. It builds as relay.exe for the PC and as relay for Linux, to run on
 * the Minecraft server beside the computers (docs/install.md).
 *
 *     relay [options] [computer port [connector port]]     ports default to 7777 and 7778
 *       --computers <ip>     where the computer port listens; default every address
 *       --connectors <ip>    where the connector port listens; default 127.0.0.1
 *       --allow <ip>         the only address connectors may come from; default any
 *
 * On the server: relay --computers 127.0.0.2 --connectors <server> --allow <pc>.
 *
 * Ctrl+C stops it, and every connection with it. See relay.h.
 *
 * @date 2026-09-30 */

/* colib's log goes to stdout, which is the relay's own log here. */
#define COLIB_ENABLE_LOGGING false
/* Vista or later, so ws2tcpip.h declares inet_ntop: colib sets this only around its own
includes. */
#define _WIN32_WINNT 0x0A00
#include "colib.h"

#include "relay.h"

#if COLIB_OS_LINUX
# include <csignal>
# include <climits>
#endif

/*! Returns the folder the relay's program is in, with its trailing separator. */
static std::string exe_dir() {
#if COLIB_OS_LINUX
    char path[PATH_MAX];
    ssize_t n = readlink("/proc/self/exe", path, sizeof(path));
    std::string dir(path, n > 0 ? size_t(n) : 0);
#else
    char path[MAX_PATH];
    DWORD n = GetModuleFileNameA(NULL, path, MAX_PATH);
    std::string dir(path, n);
#endif
    return dir.substr(0, dir.find_last_of("\\/") + 1);
}

/*! Reads a dotted IPv4 address into host order; false when it is not one. */
static bool parse_ip(const char *text, uint32_t &ip) {
    in_addr a;
    if (inet_pton(AF_INET, text, &a) != 1)
        return false;
    ip = ntohl(a.s_addr);
    return true;
}

static std::string show_ip(uint32_t ip) {
    in_addr a;
    a.s_addr = htonl(ip);
    char text[INET_ADDRSTRLEN] = "?";
    inet_ntop(AF_INET, &a, text, sizeof(text));
    return text;
}

static int usage() {
    fprintf(stderr, "usage: relay [--computers <ip>] [--connectors <ip>] [--allow <ip>] "
            "[computer port [connector port]]\n");
    return 2;
}

int main(int argc, char const *argv[]) {
    uint16_t computer_port = 7777, connector_port = 7778;
    uint32_t computer_ip = INADDR_ANY, connector_ip = INADDR_LOOPBACK;
    int ports = 0;
    for (int i = 1; i < argc; i++) {
        std::string arg = argv[i];
        uint32_t *ip = arg == "--computers" ? &computer_ip : arg == "--connectors" ? &connector_ip
                : arg == "--allow" ? &relay.connectors_from : nullptr;
        if (ip) {
            if (i + 1 >= argc || !parse_ip(argv[++i], *ip)) {
                fprintf(stderr, "relay: %s takes an IPv4 address\n", arg.c_str());
                return usage();
            }
        } else if (arg.size() && arg[0] != '-' && ports < 2) {
            (ports++ ? connector_port : computer_port) = uint16_t(atoi(arg.c_str()));
        } else {
            return usage();
        }
    }
    relay.ext_file = exe_dir() + "octerm_ext.lua";
    std::string ext;
    if (!read_ext(ext))
        fprintf(stderr, "relay: warning: %s is missing; computers will be refused until it is "
                "there\n", relay.ext_file.c_str());
#if COLIB_OS_LINUX
    /* a write to a computer that has just gone would otherwise end the relay */
    signal(SIGPIPE, SIG_IGN);
#else
    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
#endif
    std::string computers_at = show_ip(computer_ip) + ":" + std::to_string(computer_port);
    SOCKET computers = listen_on(computer_ip, computer_port);
    if (computers == INVALID_SOCKET) {
        int err = net_error();
        fprintf(stderr, "relay: cannot listen on %s (error %d%s)\n", computers_at.c_str(), err,
                err == NET_ADDRINUSE
                ? ": something else is using it, maybe another relay or the old console" : "");
        return 1;
    }
    computers_at = show_ip(computer_ip) + ":" + std::to_string(computer_port);
    std::string connectors_at = show_ip(connector_ip) + ":" + std::to_string(connector_port);
    SOCKET connectors = listen_on(connector_ip, connector_port);
    if (connectors == INVALID_SOCKET) {
        int err = net_error();
        fprintf(stderr, "relay: cannot listen on %s (error %d%s)\n", connectors_at.c_str(), err,
                err == NET_ADDRINUSE ? ": something else is using it" : "");
        return 1;
    }
    connectors_at = show_ip(connector_ip) + ":" + std::to_string(connector_port);
    relay_log("relay: computers on " + computers_at + ", connectors on " + connectors_at
            + (relay.connectors_from ? " from " + show_ip(relay.connectors_from) + " only"
            : std::string()) + ", protocol " + std::to_string(PROTOCOL_VERSION)
            + ". Ctrl+C stops it.");

    colib::pool_p pool = colib::create_pool();
    pool->sched(relay_accept(computers, false));
    pool->sched(relay_accept(connectors, true));
    pool->run();
    return 0;
}
