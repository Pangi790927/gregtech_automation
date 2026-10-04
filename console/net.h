/*! net.h - the socket helpers the relay and the terminal share: opening a listener, and a queue
 * that gives each socket exactly one writer.
 *
 * The one-writer rule is the reason for sender_t. In the relay, a computer's frames, the list of
 * computers and a new terminal's first screen can all be headed for the same terminal from
 * different coroutines. write_sz loops until everything is written and suspends between partial
 * writes, so two of them on one socket could interleave their bytes and corrupt the stream. A
 * sender_t queues instead, and one coroutine writes.
 *
 * It is also the one place that knows the relay builds for Linux too, to run on the Minecraft
 * server: there a socket is an int, its error is in errno, and colib takes the fd itself where
 * Windows takes a HANDLE. The sock_* functions hide that from relay.h. The connectors stay on
 * Windows.
 *
 * Needs colib.h included first.
 *
 * @date 2026-09-30 */

#pragma once

#include <memory>
#include <string>

#if COLIB_OS_LINUX
# include <arpa/inet.h>
# include <cerrno>
# include <fcntl.h>
# include <netinet/in.h>
# include <sys/socket.h>
# include <unistd.h>

using SOCKET = int;
constexpr SOCKET INVALID_SOCKET = -1;
constexpr int SOCKET_ERROR = -1;
constexpr int NET_ADDRINUSE = EADDRINUSE;
inline int closesocket(SOCKET s) { return close(s); }
inline int net_error() { return errno; }
inline void set_net_error(int err) { errno = err; }
#else
# include <ws2tcpip.h>

constexpr int NET_ADDRINUSE = WSAEADDRINUSE;
inline int net_error() { return WSAGetLastError(); }
inline void set_net_error(int err) { WSASetLastError(err); }
#endif

/*! Reads what the socket has, once there is something: the count, 0 when the peer closed, below
 * 0 on an error or when sock_stop woke it. */
inline colib::task<int64_t> sock_read(SOCKET s, void *buf, size_t len) {
#if COLIB_OS_LINUX
    co_return co_await colib::read(s, buf, len);
#else
    co_return co_await colib::read((HANDLE)s, buf, len);
#endif
}

/*! Writes all of `len`, or fails. */
inline colib::task_t sock_write_sz(SOCKET s, const void *buf, size_t len) {
#if COLIB_OS_LINUX
    co_return co_await colib::write_sz(s, buf, len);
#else
    co_return co_await colib::write_sz((HANDLE)s, buf, len);
#endif
}

/*! Takes the socket out of colib, waking whatever waits on it, before it is closed. */
inline colib::task_t sock_stop(SOCKET s) {
#if COLIB_OS_LINUX
    co_return co_await colib::stop_fd(s);
#else
    co_return co_await colib::stop_handle((HANDLE)s);
#endif
}

/*! Waits for a connection on `listener`; INVALID_SOCKET when accepting failed. On Linux the new
 * socket is made non-blocking: colib writes once there is some room in the send buffer, and a
 * big write on a blocking socket would wait in the system call, stopping every other session
 * (colib.h, write). */
inline colib::task<SOCKET> sock_accept(SOCKET listener, sockaddr_in &addr) {
#if COLIB_OS_LINUX
    socklen_t len = sizeof(addr);
    int s = co_await colib::accept(listener, (sockaddr *)&addr, &len);
    if (s < 0)
        co_return INVALID_SOCKET;
    int flags = fcntl(s, F_GETFL, 0);
    if (flags < 0 || fcntl(s, F_SETFL, flags | O_NONBLOCK) < 0) {
        close(s);
        co_return INVALID_SOCKET;
    }
    co_return s;
#else
    uint32_t len = sizeof(addr);
    co_return co_await colib::accept(listener, (sockaddr *)&addr, &len);
#endif
}

/*! Opens a TCP listener on `ip`:`port`; port 0 lets the system pick one, which `port` is then set
 * to. Returns INVALID_SOCKET on failure, with the error in net_error(). On Linux the address can
 * be taken again at once after the relay stops, rather than after the minute or so that closed
 * connections linger; Windows' SO_REUSEADDR would instead let two relays share the port, so it
 * is not set there. */
inline SOCKET listen_on(uint32_t ip, uint16_t &port) {
    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    sockaddr_in a = {};
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(ip);
    a.sin_port = htons(port);
#if COLIB_OS_LINUX
    socklen_t len = sizeof(a);
    int on = 1;
    if (s != INVALID_SOCKET)
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
#else
    int len = sizeof(a);
#endif
    if (s == INVALID_SOCKET || bind(s, (sockaddr *)&a, sizeof(a)) == SOCKET_ERROR
            || listen(s, 4) == SOCKET_ERROR || getsockname(s, (sockaddr *)&a, &len)) {
        int err = net_error();      /* closesocket would clear it, and the caller reports it */
        if (s != INVALID_SOCKET)
            closesocket(s);
        set_net_error(err);
        return INVALID_SOCKET;
    }
    port = ntohs(a.sin_port);
    return s;
}

/*! A socket's outgoing queue, drained by its own sender_loop. */
struct sender_t {
    SOCKET s = INVALID_SOCKET;
    std::string queued;
    colib::sem_p ready;     /*!< signalled when there is something to write, or on closing */
    bool closing = false;
};
using sender_p = std::shared_ptr<sender_t>;

/*! Queues bytes for the socket; they go out in order, after everything queued before them. */
inline void post(const sender_p &snd, const std::string &bytes) {
    if (!snd || snd->closing || bytes.empty())
        return;
    snd->queued += bytes;
    snd->ready->signal();
}

/*! Writes what is posted until close_sender() or a failed write. */
inline colib::task_t sender_loop(sender_p snd) {
    while (true) {
        co_await snd->ready->wait();
        if (snd->closing)
            break;
        if (snd->queued.empty())
            continue;
        std::string data;
        data.swap(snd->queued);
        if (co_await sock_write_sz(snd->s, data.data(), data.size()) != colib::ERROR_OK)
            break;
    }
    snd->closing = true;
    co_return 0;
}

/*! Returns a sender for `s`, with its writer already scheduled. */
inline colib::task<sender_p> open_sender(SOCKET s) {
    sender_p snd = std::make_shared<sender_t>();
    snd->s = s;
    snd->ready = co_await colib::create_sem(0);
    co_await colib::sched(sender_loop(snd));
    co_return snd;
}

/*! Stops the sender's writer; what was still queued is dropped. */
inline void close_sender(const sender_p &snd) {
    if (!snd || snd->closing)
        return;
    snd->closing = true;
    snd->ready->signal();
}
