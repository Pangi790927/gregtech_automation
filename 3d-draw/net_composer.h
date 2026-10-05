#ifndef NET_COMPOSER_H
#define NET_COMPOSER_H
/*! net_composer.h - TCP for 3d-draw's Lua: connect, send, receive, close, and a sleep, each a colib
 * task a Lua coroutine waits on (virt_composer_coroutines.h: a registered function answering
 * co::task<T> suspends the script that calls it while the pool goes on).
 *
 * Core: the C++ is only the socket. What is said over it - the relay's frames, the zones, the
 * robot's commands, polling, reconnecting - is Lua (3d-draw/scripts/relay.lua, robots.lua), so a
 * change there needs no rebuild and no restart of the program (the user, 2026-10-05: "the
 * connection logic put in lua, this way less shutdowns are needed"). The pool is the program's main
 * loop (main.cpp: "simply redesign it to be pool centric"), so a wait here holds up nothing.
 *
 *     vc.net_connect(host, port)  a handle, or -1 when nothing listens there      (waits)
 *     vc.net_send(h, bytes)       how many bytes went, or -1                       (waits)
 *     vc.net_recv(h)              what arrived, up to 64 KiB; "" when it closed    (waits)
 *     vc.net_close(h)             0
 *     vc.net_listen(port)         a listening handle on 127.0.0.1:port, or -1; local only
 *     vc.net_accept(h)            the next connection's handle, or -1              (waits)
 *     vc.net_sleep_ms(ms)         0, after ms milliseconds                         (waits)
 *
 * Bytes are Lua strings, zeros and all (virt_composer passes std::string with its size).
 * Windows only for now, as the console's connector.h, whose colib calls this follows.
 *
 * @date 2026-10-05 */

#include <map>
#include <string>
#include <vector>

#include "virt_composer.h"
#include "virt_composer_coroutines.h"
#include "debug.h"

#if defined(_WIN32)
# include <winsock2.h>
# include <ws2tcpip.h>
# pragma comment(lib, "ws2_32.lib")
#endif

namespace net_composer {

namespace vc = virt_composer;

/* The sockets Lua holds, by the number it was given. @date 2026-10-05 */
inline std::map<int, SOCKET> g_socks;
inline int g_next = 1;

inline SOCKET sock_of(int h) {
    auto it = g_socks.find(h);
    return it == g_socks.end() ? INVALID_SOCKET : it->second;
}

/*! Connects to host:port (a dotted address); a handle, or -1. @date 2026-10-05 */
inline co::task<double> net_connect(std::string host, int64_t port) {
    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID_SOCKET)
        co_return -1;
    sockaddr_in a = {};
    a.sin_family = AF_INET;
    a.sin_port = htons((u_short)port);
    if (inet_pton(AF_INET, host.c_str(), &a.sin_addr) != 1
            || co_await co::connect(s, (sockaddr *)&a, sizeof(a)) != co::ERROR_OK) {
        closesocket(s);
        co_return -1;
    }
    int h = g_next++;
    g_socks[h] = s;
    co_return (double)h;
}

/*! Sends every byte; how many, or -1 when the socket is gone. @date 2026-10-05 */
inline co::task<double> net_send(int64_t h, std::string bytes) {
    SOCKET s = sock_of((int)h);
    if (s == INVALID_SOCKET)
        co_return -1;
    if (bytes.empty())
        co_return 0;
    if (co_await co::write_sz((HANDLE)s, bytes.data(), bytes.size()) != co::ERROR_OK)
        co_return -1;
    co_return (double)bytes.size();
}

/*! What arrived, up to 64 KiB, once something has; "" when the peer closed or it failed.
 * @date 2026-10-05 */
inline co::task<std::string> net_recv(int64_t h) {
    SOCKET s = sock_of((int)h);
    if (s == INVALID_SOCKET)
        co_return std::string();
    std::vector<char> chunk(65536);
    SSIZE_T n = co_await co::read((HANDLE)s, chunk.data(), chunk.size());
    if (n <= 0)
        co_return std::string();
    co_return std::string(chunk.data(), (size_t)n);
}

/*! Closes a socket; a read waiting on it ends with "". @date 2026-10-05 */
inline int net_close(int64_t h) {
    SOCKET s = sock_of((int)h);
    if (s == INVALID_SOCKET)
        return 0;
    g_socks.erase((int)h);
    closesocket(s);
    return 0;
}

/*! Listens on 127.0.0.1:port and nowhere else - the program's control port, for Claude to talk
 * to the robots through the running program (the user, 2026-10-05: "can't you start talking with
 * the robots and ask them things"). As the console's listen_on (net.h). @date 2026-10-05 */
inline double net_listen(int64_t port) {
    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    sockaddr_in a = {};
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a.sin_port = htons((u_short)port);
    if (s == INVALID_SOCKET || bind(s, (sockaddr *)&a, sizeof(a)) == SOCKET_ERROR
            || listen(s, 4) == SOCKET_ERROR) {
        if (s != INVALID_SOCKET)
            closesocket(s);
        return -1;
    }
    int h = g_next++;
    g_socks[h] = s;
    return (double)h;
}

/*! The next connection on a listening handle; -1 when accepting failed. @date 2026-10-05 */
inline co::task<double> net_accept(int64_t h) {
    SOCKET l = sock_of((int)h);
    if (l == INVALID_SOCKET)
        co_return -1;
    sockaddr_in addr = {};
    uint32_t len = sizeof(addr);
    SOCKET s = co_await co::accept(l, (sockaddr *)&addr, &len);
    if (s == INVALID_SOCKET)
        co_return -1;
    int c = g_next++;
    g_socks[c] = s;
    co_return (double)c;
}

/*! Suspends the calling script for ms milliseconds. @date 2026-10-05 */
inline co::task_t net_sleep_ms(int64_t ms) {
    co_await co::sleep_ms(ms < 0 ? 0 : (uint64_t)ms);
    co_return 0;
}

inline int register_meta(vc::virt_state_t *vs) {
    DBG_SCOPE();
#if defined(_WIN32)
    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
#endif
    std::vector<luaL_Reg> funcs = {
        {"net_connect",  vc::luaw_function_wrapper<net_connect, std::string, int64_t>},
        {"net_send",     vc::luaw_function_wrapper<net_send, int64_t, std::string>},
        {"net_recv",     vc::luaw_function_wrapper<net_recv, int64_t>},
        {"net_close",    vc::luaw_function_wrapper<net_close, int64_t>},
        {"net_sleep_ms", vc::luaw_function_wrapper<net_sleep_ms, int64_t>},
        {"net_listen",   vc::luaw_function_wrapper<net_listen, int64_t>},
        {"net_accept",   vc::luaw_function_wrapper<net_accept, int64_t>},
    };
    ASSERT_FN(vc::add_lua_tab_funcs(vs, funcs));
    return 0;
}

}; /* namespace net_composer */

#endif /* NET_COMPOSER_H */
