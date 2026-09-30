/*! net.h - the socket helpers the relay and the terminal share: opening a listener, and a queue
 * that gives each socket exactly one writer.
 *
 * The one-writer rule is the reason for sender_t. In the relay, a computer's frames, the list of
 * computers and a new terminal's first screen can all be headed for the same terminal from
 * different coroutines. write_sz loops until everything is written and suspends between partial
 * writes, so two of them on one socket could interleave their bytes and corrupt the stream. A
 * sender_t queues instead, and one coroutine writes.
 *
 * Needs colib.h included first.
 *
 * @date 2026-09-30 */

#pragma once

#include <memory>
#include <string>

/*! Opens a TCP listener on `ip`:`port`; port 0 lets Windows pick one, which `port` is then set
 * to. Returns INVALID_SOCKET on failure. */
inline SOCKET listen_on(uint32_t ip, uint16_t &port) {
    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    sockaddr_in a = {};
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(ip);
    a.sin_port = htons(port);
    int len = sizeof(a);
    if (s == INVALID_SOCKET || bind(s, (sockaddr *)&a, sizeof(a)) == SOCKET_ERROR
            || listen(s, 4) == SOCKET_ERROR || getsockname(s, (sockaddr *)&a, &len)) {
        int err = WSAGetLastError();    /* closesocket would clear it, and the caller reports it */
        if (s != INVALID_SOCKET)
            closesocket(s);
        WSASetLastError(err);
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
        if (co_await colib::write_sz((HANDLE)snd->s, data.data(), data.size()) != colib::ERROR_OK)
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
