/*! claude-oc.cpp - claude-oc's program: Claude for the `claude` program on the base's
 * computers, and the mail between them.
 *
 *     claude-oc.exe [address]        serve only the computers whose address starts so
 *     ... --model <model>            claude's model; the user's default without it
 *     ... --port <n>                 the relay's connector port, default 7778, at relay_host()
 *     ... --mcp-port <n>             where claude reaches the tools, default 7779, on 127.0.0.1
 *
 * Its window is every session's other end: it shows each computer attached, each prompt
 * (game> from the computer, pc> from here), each tool used and each answer, and a line typed
 * in it is a prompt in the session of the computer shown before its `> ` (Ctrl+Left and
 * Ctrl+Right step through them; `@<address start> text` picks one). Beside claude-oc.exe:
 * claude-oc.lua (the zone), claude.lua (the `claude` program) and system.md (claude's system
 * prompt); work/ is made there for claude to run in, and keeps the sessions and the mailboxes.
 * See claude-oc.h.
 *
 * @date 2026-10-01 */

#define COLIB_ENABLE_LOGGING false
#define _WIN32_WINNT 0x0A00
#include "colib.h"

#include "claude-oc.h"

static colib::task_t cloc_start(SOCKET mcp_listener) {
    cloc.arrived = co_await colib::create_sem(0);
    co_await colib::sched(mcp_accept(cloc.mcp, mcp_listener));
    co_await colib::sched(window_input());
    co_await colib::sched(serve_arrivals());
    co_await colib::sched(watch_link());
    co_return 0;
}

int main(int argc, char const *argv[]) {
    setvbuf(stdout, NULL, _IONBF, 0);
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "--port" && i + 1 < argc)
            cloc.port = uint16_t(atoi(argv[++i]));
        else if (a == "--mcp-port" && i + 1 < argc)
            cloc.mcp_port = uint16_t(atoi(argv[++i]));
        else if (a == "--model" && i + 1 < argc)
            cloc.model = argv[++i];
        else
            cloc.prefix = a;
    }
    std::string dir = exe_folder();
    cloc.work = dir + "work\\";
    cloc.system_file = dir + "system.md";
    zone_link_t payload;
    std::string system_text;
    if (!load_payload(payload, "claude-oc.lua") || !read_file(dir + "claude.lua", cloc.program)
            || !read_file(cloc.system_file, system_text)) {
        fprintf(stderr, "claude-oc: claude-oc.lua, claude.lua and system.md must be beside it\n");
        return 1;
    }
    cloc.code = payload.code;
    cloc.hash = payload.hash;
    CreateDirectoryA(cloc.work.c_str(), NULL);
    cloc_init();

    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
    uint16_t bound = cloc.mcp_port;
    SOCKET l = listen_on(INADDR_LOOPBACK, bound);
    if (l == INVALID_SOCKET) {
        fprintf(stderr, "claude-oc: cannot listen on 127.0.0.1:%d; is another claude-oc.exe "
                "running?\n", cloc.mcp_port);
        return 1;
    }
    SetConsoleTitleA("claude-oc - Claude for the computers; type here to join in");
    SetConsoleOutputCP(CP_UTF8);        /* answers are UTF-8 */
    say("claude-oc: tools on 127.0.0.1:" + std::to_string(cloc.mcp_port) + ", relay on "
        + relay_host() + ":" + std::to_string(cloc.port) + (cloc.model.empty() ? std::string()
                                                    : ", model " + cloc.model)
        + (cloc.prefix.empty() ? std::string() : ", computers " + cloc.prefix + "..."));
    say("Ctrl+Left / Ctrl+Right: the computer this window talks to; @<address start> text: "
        "to that one");

    colib::pool_p pool = colib::create_pool();
    pool->sched(cloc_start(l));
    pool->run();
    window_close();
    return 0;
}
