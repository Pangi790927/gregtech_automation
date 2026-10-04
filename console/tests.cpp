/*! tests.cpp - tests.exe: checks the screen, the frames, the keys, claude-oc's MCP server and
 * zone frames, the relay with real sockets, and the terminal against a stand-in loader; prints
 * one line per check, and exits with the number that failed.
 *
 * The relay tests run relay.h's own accept loops and sessions on 127.0.0.1, on ports Windows
 * picks, never 7777 or 7778: a relay the user has running must not be touched. Computers and
 * connectors in them are plain sockets sending the bytes octerm.lua and term.exe send. The
 * terminal test runs term.h's own session through that relay, with a stand-in for octerm.lua
 * answering it. The console window is the one thing none of this reaches; that is checked by
 * running term.exe and typing into it (term/DESIGN.md, "Using it from Claude").
 *
 * @date 2026-09-30 */

#define COLIB_ENABLE_LOGGING false
#define _WIN32_WINNT 0x0A00
#include "colib.h"

#include "relay.h"
#include "term.h"
#include "claude-oc.h"
#include "ocscp.h"

static int failures = 0;

static void check(bool ok, const std::string &name, const std::string &detail = "") {
    printf("%s %s%s%s\n", ok ? "ok  " : "FAIL", name.c_str(), detail.empty() ? "" : ": ",
           detail.c_str());
    if (!ok)
        failures++;
}

/*! Returns row `y` (1-based) of the screen as UTF-8. */
static std::string row(screen_t &s, int y) {
    std::string out;
    for (int x = 1; x <= s.w; x++)
        utf8_encode(out, s.at(x, y)->ch);
    return out;
}

/*! Applies frames to `s`; returns false on anything that is not one. */
static bool apply_all(screen_t &s, const std::string &bytes) {
    const uint8_t *b = reinterpret_cast<const uint8_t *>(bytes.data());
    reader_t r = {b, b + bytes.size()};
    while (r.has(1))
        if (apply_frame(s, r) != 1)
            return false;
    return true;
}

static void test_screen() {
    screen_t s;
    s.resize(10, 3);
    s.set(1, 1, 0xFF0000, 0x0000FF, false, U"hello");
    check(row(s, 1) == "hello     ", "set writes from (x, y)", row(s, 1));
    check(s.at(1, 1)->fg == 0xFF0000 && s.at(1, 1)->bg == 0x0000FF, "set keeps both colours");
    s.set(-1, 2, 0xFFFFFF, 0, false, U"abcd");
    check(row(s, 2) == "cd        ", "set starting off the left edge is cut", row(s, 2));
    s.set(10, 1, 0xFFFFFF, 0, true, U"xyz");
    check(s.at(10, 1)->ch == U'x' && s.at(10, 3)->ch == U'z', "vertical set goes down");
    s.fill(2, 3, 3, 1, 0xFFFFFF, 0, U'#');
    check(row(s, 3) == " ###     z", "fill covers the rectangle", row(s, 3));
    s.copy(1, 2, 10, 2, 0, -1);
    check(row(s, 1) == "cd       y" && row(s, 2) == " ###     z", "copy scrolls up",
          row(s, 1) + "|" + row(s, 2));
    s.resize(4, 1);
    check(row(s, 1) == "cd  ", "resize keeps what both sizes share", row(s, 1));
    std::string drawn = s.render();
    check(drawn.find("cd") != std::string::npos && s.render().empty(),
          "render draws dirty rows once");
}

static void test_frames() {
    std::string stream = enc_resize(8, 2) + enc_set(1, 1, 0xFFFFFF, 0, false, "h\xC3\xA9llo")
                       + enc_fill(1, 2, 8, 1, 0, 0xFFFFFF, "=") + enc_copy(1, 1, 3, 1, 5, 1);
    std::string detail;
    bool all = true;
    for (size_t cut = 0; cut <= stream.size() && all; cut++) {
        screen_t s;
        std::string first = stream.substr(0, cut), buf;
        const uint8_t *b = reinterpret_cast<const uint8_t *>(first.data());
        reader_t r = {b, b + first.size()};
        while (apply_frame(s, r) == 1) {}
        buf = first.substr(size_t(r.p - b)) + stream.substr(cut);
        bool ok = apply_all(s, buf);
        std::string got = s.w ? row(s, 1) + "|" + row(s, 2) : "";
        if (!ok || got != "h\xC3\xA9llo   |=====h\xC3\xA9l") {
            all = false;
            detail = "cut at " + std::to_string(cut) + ": " + got;
        }
    }
    check(all, "frames apply the same however the stream is cut", detail);
    check(payload_hash("") == "cbf29ce484222325" && payload_hash("a") == "af63dc4c8601ec8c",
          "the payload hash is FNV-1a 64", payload_hash("a"));
}

/*! Returns the keys for `in` as "d/u char code," items. */
static std::string decode(const std::string &in, bool *quit = nullptr) {
    key_decoder_t d;
    std::string out;
    for (const oc_key_t &k : d.feed(in.data(), in.size())) {
        char item[40];
        snprintf(item, sizeof(item), "%c %u %02X,", k.down ? 'd' : 'u', k.ch, k.code);
        out += item;
    }
    if (quit)
        *quit = d.quit;
    return out;
}

static void test_keys() {
    auto expect = [](const std::string &in, const std::string &want, const std::string &name) {
        std::string got = decode(in);
        check(got == want, name, got);
    };
    expect("a", "d 97 1E,u 97 1E,", "a letter carries its character and scancode");
    expect("A", "d 65 1E,u 65 1E,", "a capital has the same key as its letter");
    expect("\r", "d 13 1C,u 13 1C,", "Enter");
    expect("\x7F", "d 8 0E,u 8 0E,", "Backspace");
    expect("\x1b[A", "d 0 C8,u 0 C8,", "Up is 0xC8, as full_keyboard.lua has it");
    expect("\x1b[3~", "d 0 D3,u 0 D3,", "Delete");
    expect("\x1b[15~", "d 0 3F,u 0 3F,", "F5");
    expect("\x1bOP", "d 0 3B,u 0 3B,", "F1");
    expect("\x13", "d 0 1D,d 19 1F,u 19 1F,u 0 1D,", "Ctrl+S is S inside Ctrl's own down/up");
    expect("\x03", "d 0 1D,d 3 2E,u 3 2E,u 0 1D,", "Ctrl+C goes to the computer, char 3");
    expect("\x1b[1;5C", "d 0 1D,d 0 CD,u 0 CD,u 0 1D,", "Ctrl+Right");
    expect("\x1b", "d 27 01,u 27 01,", "Escape alone");
    expect("\x1bx", "d 0 38,d 120 2D,u 120 2D,u 0 38,", "Alt+x");
    expect("\xC3\xA9", "d 233 00,u 233 00,", "a character with no key is sent without one");
    bool quit = false;
    std::string got = decode("a\x04" "b", &quit);
    check(quit && got == "d 97 1E,u 97 1E,", "Ctrl+D disconnects and is not sent", got);
}

/* THE RELAY AND THE TERMINAL, over real sockets
=================================================================================================*/

struct peer_t {
    SOCKET s = INVALID_SOCKET;
    std::string got;
    bool closed = false;
};

/*! Collects everything that arrives on the peer's socket until it closes. */
static colib::task_t pump(peer_t *p) {
    std::vector<char> chunk(16384);
    while (true) {
        SSIZE_T n = co_await colib::read((HANDLE)p->s, chunk.data(), chunk.size());
        if (n <= 0)
            break;
        p->got.append(chunk.data(), size_t(n));
    }
    p->closed = true;
    co_return 0;
}

/*! Connects `p` to 127.0.0.1:`port`; with `collect`, starts collecting what it receives. */
static colib::task_t dial(peer_t *p, uint16_t port, bool collect = true) {
    p->s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    sockaddr_in a = {};
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a.sin_port = htons(port);
    co_await colib::connect(p->s, (sockaddr *)&a, sizeof(a));
    if (collect)
        co_await colib::sched(pump(p));
    co_return 0;
}

static colib::task_t say(peer_t *p, std::string bytes) {
    co_return co_await colib::write_sz((HANDLE)p->s, bytes.data(), bytes.size());
}

/*! Closes the peer's end, as a computer or connector going away does. Not shutdown(): colib's
 * connect does not set SO_UPDATE_CONNECT_CONTEXT, and without it shutdown fails. */
static colib::task_t hang_up(peer_t *p) {
    co_await colib::stop_handle((HANDLE)p->s);
    closesocket(p->s);
    co_return 0;
}

/*! Waits up to 3 s for `done`; returns whether it came true. */
template <typename F>
static colib::task<bool> until(F done) {
    for (int i = 0; i < 300; i++) {
        if (done())
            co_return true;
        co_await colib::sleep_ms(10);
    }
    co_return done();
}

/*! Returns whether `got` ends with `tail`. */
static bool ends(const std::string &got, const std::string &tail) {
    return got.size() >= tail.size()
        && got.compare(got.size() - tail.size(), tail.size(), tail) == 0;
}

static std::string test_ext = "-- a stand-in for octerm_ext.lua";

static colib::task_t relay_story(uint16_t cport, uint16_t kport) {
    peer_t a, b, b2, c, k1, k2, k3;
    std::string hash = payload_hash(test_ext);
    co_await dial(&a, cport);
    co_await say(&a, enc_hello("aaaa"));
    co_await dial(&b, cport);
    co_await say(&b, enc_hello("bbbb", hash));
    check(co_await until([&] { return relay.computers.size() == 2; }),
          "two computers say hello and are both kept");
    check(co_await until([&] { return a.got == enc_ext(hash, &test_ext); }),
          "a computer with no extension cached is sent octerm_ext.lua");
    check(co_await until([&] { return b.got == enc_ext(hash, nullptr); }),
          "one that has it cached under the same hash is told to use that");

    co_await dial(&k1, kport);
    std::string list2 = enc_list({"aaaa", "bbbb"});
    check(co_await until([&] { return k1.got == list2; }), "a connector is told both addresses");
    co_await say(&k1, enc_attach("aaaa"));
    check(co_await until([&] { return k1.got == list2 + "Y"; }), "attaching is answered Y");
    co_await say(&k1, "anything at all");
    check(co_await until([&] { return ends(a.got, enc_data(0, "anything at all")); }),
          "after Y, what a connector sends reaches its computer on its channel, untouched");
    co_await say(&a, enc_data(0, "back"));
    check(co_await until([&] { return ends(k1.got, "back"); }), "and what comes back reaches it");

    co_await dial(&k2, kport);
    co_await until([&] { return !k2.got.empty(); });
    co_await say(&k2, enc_attach("aaaa"));
    co_await until([&] { return ends(k2.got, "Y"); });
    co_await say(&k2, "two");
    co_await say(&a, enc_data(1, "for two"));
    check(co_await until([&] { return ends(a.got, enc_data(1, "two")) && ends(k2.got, "for two"); })
          && ends(k1.got, "back"), "a second connector on the same computer gets channel 1, apart");

    co_await dial(&k3, kport);
    co_await until([&] { return !k3.got.empty(); });
    size_t before = k3.got.size();
    co_await say(&k3, enc_attach("zzzz"));
    check(co_await until([&] { return k3.got.substr(before) == "N" + list2; }),
          "attaching to a computer that is not there is answered N and the list");

    co_await hang_up(&k1);
    check(co_await until([&] { return ends(a.got, enc_gone(0)); }),
          "a connector leaving is told to its computer as G");

    co_await dial(&c, cport);
    co_await say(&c, "H\x01\x04" "cccc");     /* protocol 1's hello: no hash after the address */
    check(co_await until([&] { return c.closed; }) && relay.computers.size() == 2,
          "a computer speaking another protocol version is refused");

    co_await hang_up(&a);
    check(co_await until([&] { return k2.closed; }), "a computer leaving closes its connectors");

    co_await dial(&b2, cport);
    co_await say(&b2, enc_hello("bbbb"));
    check(co_await until([&] { return b.closed; }) && relay.computers.size() == 1,
          "a computer connecting again replaces its old connection");

    peer_t k4;
    size_t connectors = relay.connectors.size();
    relay.connectors_from = 0x7F000009;     /* 127.0.0.9: the connectors here come from .1 */
    co_await dial(&k4, kport);
    check(co_await until([&] { return k4.closed; }) && k4.got.empty()
          && relay.connectors.size() == connectors,
          "with --allow, a connector from another address is closed unanswered");
    relay.connectors_from = 0;

    co_await hang_up(&k3);
    co_await hang_up(&b2);
    /* Every socket closed before the next story: a pool must not be left with reads pending
    into buffers that are gone, and all of this shares one pool for that reason. */
    bool empty = co_await until([&] {
        return relay.computers.empty() && relay.connectors.empty(); });
    std::string left;
    for (const computer_p &x : relay.computers)
        left += " computer " + x->addr;
    for (const connector_p &x : relay.connectors)
        left += " connector on " + (x->computer ? x->computer->addr : std::string("nothing"))
              + " ch " + std::to_string(x->ch);
    check(empty, "everyone gone, the relay holds nothing", left);
    co_return 0;
}

/*! Plays octerm.lua for the terminal test: misses the cache once, takes the code, opens the zone,
 * draws, and waits for a key. */
static colib::task_t stand_in_loader(peer_t *oc, std::string *seen_key) {
    co_await say(oc, enc_hello("dddd"));
    std::string ask = enc_ext(payload_hash(test_ext), &test_ext)
                    + enc_data(0, enc_open("terminal", term.conn.hash, nullptr));
    co_await until([&] { return oc->got == ask; });
    co_await say(oc, enc_data(0, enc_opened(1, false, "not cached")));
    std::string with_code = ask + enc_data(0, enc_open("terminal", term.conn.hash,
                                                       &term.conn.code));
    co_await until([&] { return oc->got == with_code; });
    co_await say(oc, enc_data(0, enc_opened(0, false, "")));
    co_await say(oc, enc_data(0, enc_zone_data(enc_resize(12, 2)
                                             + enc_set(1, 1, 0xFFFFFF, 0, false, "from zone"))));
    std::string key = enc_data(0, enc_zone_data(key_frame({true, 'a', 0x1E})));
    co_await until([&] { return ends(oc->got, key); });
    *seen_key = ends(oc->got, key) ? "yes" : "no";
    co_await say(oc, enc_data(0, enc_zone_end("it returned")));
    co_return 0;
}

/*! Stands in for term_input: once the zone runs, types one key, as the window would. */
static colib::task_t type_a_key() {
    co_await until([&] { return term.conn.state == conn_state::running && term.screen.w == 12; });
    post(term.conn.out, enc_zone_data(key_frame({true, 'a', 0x1E})));
    co_return 0;
}

static colib::task_t term_story(uint16_t cport, uint16_t kport, std::string *seen_key) {
    static peer_t oc, k;    /* outlive this coroutine: the stand-in loader keeps using `oc` */
    co_await dial(&oc, cport);
    co_await colib::sched(stand_in_loader(&oc, seen_key));
    co_await until([&] { return relay.computers.size() == 1; });
    co_await dial(&k, kport, false);
    term.conn.out = co_await open_sender(k.s);
    co_await colib::sched(type_a_key());
    co_await colib::sched(relay_session(k.s));      /* ends the pool when the zone ends */
    co_return 0;
}

/*! Checks that HTTP requests come out whole however the bytes are cut, two in a row. */
static void test_http() {
    std::string one = "POST /mcp HTTP/1.1\r\nHost: x\r\ncontent-length: 7\r\n\r\n{\"a\":1}";
    std::string two = "GET /mcp HTTP/1.1\r\nAccept: text/event-stream\r\n\r\n";
    std::string stream = one + two, detail;
    bool all = true;
    for (size_t cut = 0; cut <= stream.size() && all; cut++) {
        std::string buf = stream.substr(0, cut), got;
        http_req_t req;
        int rc = 0;
        for (int part = 0; part < 2; part++) {
            while ((rc = take_http_request(buf, req)) == 1)
                got += req.method + " " + req.path + " [" + req.body + "] ";
            buf += part == 0 ? stream.substr(cut) : "";
        }
        if (rc < 0 || got != "POST /mcp [{\"a\":1}] GET /mcp [] ") {
            all = false;
            detail = "cut at " + std::to_string(cut) + ": " + got;
        }
    }
    check(all, "HTTP requests come out whole however they are cut", detail);
}

/*! Stands in for claude-oc's call_tool: answers from the arguments alone. */
static colib::task<tool_answer_t> echo_tool(std::string path, std::string name, json args) {
    co_return tool_answer_t{true, name + " got " + args.value("command", "") + " at " + path};
}

/*! Checks the MCP answers. */
static colib::task_t mcp_story() {
    mcp_server_t mcp;
    mcp.tools = tool_list();
    mcp.call = echo_tool;
    json init = json::parse(co_await mcp_answer(mcp, "/mcp/x", R"({"jsonrpc":"2.0","id":0,
        "method":"initialize","params":{"protocolVersion":"2025-11-25"}})"));
    check(init["result"]["protocolVersion"] == "2025-11-25", "initialize answers in the "
          "client's protocol version", init.dump());
    std::string note = co_await mcp_answer(mcp, "/mcp/x", R"({"jsonrpc":"2.0",
        "method":"notifications/initialized"})");
    check(note.empty(), "a notification gets no answer", note);
    json list = json::parse(co_await mcp_answer(mcp, "/mcp/x", R"({"jsonrpc":"2.0","id":1,
        "method":"tools/list"})"));
    check(list["result"]["tools"].size() == 6 && list["result"]["tools"][0]["name"] == "oc_run"
          && list["result"]["tools"][4]["name"] == "oc_send", "tools/list gives the six tools",
          list.dump().substr(0, 80));
    json call = json::parse(co_await mcp_answer(mcp, "/mcp/abc", R"({"jsonrpc":"2.0","id":2,
        "method":"tools/call","params":{"name":"oc_run","arguments":{"command":"ls /"}}})"));
    check(call["result"]["content"][0]["text"] == "oc_run got ls / at /mcp/abc"
          && call["result"]["isError"] == false, "tools/call answers with the tool's text, "
          "told the path it came to", call.dump());
    json nope = json::parse(co_await mcp_answer(mcp, "/mcp/x", R"({"jsonrpc":"2.0","id":"p",
        "method":"server/discover"})"));
    check(nope["error"]["code"] == -32601 && nope["id"] == "p", "an unknown method is an "
          "error, which Claude Code's discovery probe expects", nope.dump());
    co_return 0;
}

/*! Returns a node for a test computer, attached and with a session, sending nowhere. */
static colib::task<node_p> test_node(std::string addr) {
    node_p n = make_node(addr);
    n->prompt_ready = co_await colib::create_sem(0);
    n->conn.state = conn_state::running;        /* its sender is unset: nothing goes out */
    n->has_session = true;
    co_return n;
}

/*! Checks a computer's zone frames however they are cut. */
static colib::task_t frames_story(node_p n) {
    std::string stream = enc_reset() + enc_begin("/home/lua") + enc_dir("/home/lua/x")
                       + enc_prompt(7, "what is here?") + enc_result(3, true, "ok");
    std::string detail;
    bool all = true;
    for (size_t cut = 0; cut <= stream.size() && all; cut++) {
        auto w = std::make_shared<tool_wait_t>();
        w->done = co_await colib::create_sem(0);
        n->waiting = {{3, w}};
        n->prompts.clear();
        n->zone_buf.clear();
        n->has_session = true;
        n->session = "old";
        n->cwd = "/old";
        bool ok = take_cloc_bytes(*n, stream.substr(0, cut))
               && take_cloc_bytes(*n, stream.substr(cut));
        if (!ok || !n->has_session || n->session != "" || n->cwd != "/home/lua/x"
                || n->prompts.size() != 1 || n->prompts[0].id != 7
                || n->prompts[0].text != "what is here?" || !w->finished
                || w->answer.text != "ok" || !n->zone_buf.empty()) {
            all = false;
            detail = "cut at " + std::to_string(cut) + ", session '" + n->session + "' in "
                   + n->cwd;
        }
    }
    n->waiting.clear();
    n->prompts.clear();
    check(all, "claude-oc takes a computer's frames however they are cut: a session ended, a "
          "new one begun in its directory, the directory moved, a prompt, a tool's result",
          detail);
    co_return 0;
}

static std::string first_prompt(node_p n) {
    std::string text = n->prompts.empty() ? "(none)" : n->prompts[0].text;
    n->prompts.clear();
    return text;
}

/*! Checks the window: prompts typed, its cursor, and choosing the computer it talks to. */
static void window_story(node_p a, node_p b) {
    cloc.target = a->addr;
    take_typed("abx\x08 \\\rcd\r");
    bool from_pc = !a->prompts.empty() && a->prompts[0].from_pc;
    std::string sent = first_prompt(a);
    check(sent == "ab \ncd" && from_pc && win.row.empty() && win.rows.empty(), "a line typed "
          "in claude-oc's window is a prompt: Backspace takes a letter back, \\ and Enter start "
          "a new row", sent);
    /* "xac", Home, Delete, End, Left, "b", Right, "d", Enter: "abcd" */
    take_typed("xac\x1b[H\x1b[3~\x1b[F\x1b[Db\x1b[Cd\r");
    sent = first_prompt(a);
    check(sent == "abcd", "the window's cursor moves with Left, Right, Home and End, and Delete "
          "takes out the letter at it", sent);
    std::string seen;
    for (const char *key : {"\x1b[1;5C", "\x1b[1;5C", "\x1b[1;5D"}) {
        take_typed(key);
        seen += short_addr(cloc.target) + " ";
    }
    check(seen == "bbbb2222 aaaa1111 bbbb2222 ", "Ctrl+Right and Ctrl+Left step the window "
          "through the computers, round", seen);
    take_typed("@aaaa hello there\r");
    sent = first_prompt(a);
    check(sent == "hello there" && cloc.target == a->addr, "@<address start> sends a line to "
          "that computer, which the window then keeps", sent + " to " + cloc.target);
}

/*! Checks the mail: sent by the start of an address, kept, given to Claude once, listed. */
static void mail_story(node_p a, node_p b) {
    char tmp[MAX_PATH];
    GetTempPathA(MAX_PATH, tmp);
    cloc.work = std::string(tmp) + "claude_oc_mail_test\\";
    CreateDirectoryA(cloc.work.c_str(), NULL);
    DeleteFileA(mailbox_file(b->addr).c_str());
    std::string msg;
    bool sent = send_mail(a->addr, "bbbb", "the fusion list is ready", msg);
    check(sent && msg == "sent to " + b->addr, "mail goes to the one computer whose address "
          "starts as given", msg);
    take_cloc_bytes(*a, enc_mail_send(5, "bbbb2222", "second letter"));
    std::string unseen = take_unseen_mail(b->addr);
    check(unseen.find("from " + a->addr + ":\nthe fusion list is ready") != std::string::npos
          && unseen.find("second letter") != std::string::npos
          && take_unseen_mail(b->addr).empty(), "a computer's Claude is given its new mail "
          "once, with the senders' addresses, `claude send`'s too", unseen);
    std::string first = list_mail(b->addr), again = list_mail(b->addr);
    check(first.find("(new)") != std::string::npos && again.find("(new)") == std::string::npos,
          "`claude mail` lists the mailbox, marking what it had not shown before", first);
    check(!send_mail(a->addr, "cc", "x", msg) && msg.find("no computer") != std::string::npos,
          "mail to an address no computer has is refused, saying why", msg);
    DeleteFileA(mailbox_file(MAIN_SRV).c_str());
    DeleteFileA(mailbox_file(a->addr).c_str());
    bool asked = send_mail(a->addr, "main-srv", "the Neutronium fusion recipe?", msg);
    std::string questions = main_srv_tool("oc_mail", json::object()).text;
    tool_answer_t reply = main_srv_tool("oc_send", {{"to", "aaaa1111"}, {"text", "Americium "
                                        "+ Naquadria"}});
    std::string answer = take_unseen_mail(a->addr);
    check(asked && questions.find("Neutronium fusion") != std::string::npos && reply.ok
          && answer.find("from main-srv:\nAmericium + Naquadria") != std::string::npos,
          "main-srv takes a computer's question by its name, and its answer goes back as mail "
          "from main-srv", answer);
    DeleteFileA(mailbox_file(MAIN_SRV).c_str());
    DeleteFileA(mailbox_file(a->addr).c_str());
    DeleteFileA(mailbox_file(b->addr).c_str());
    RemoveDirectoryA(cloc.work.c_str());
    cloc.work.clear();
}

/*! Runs claude-oc's checks; the computers are two made up, never on a relay. */
static colib::task_t claude_oc_story() {
    co_await mcp_story();
    node_p a = co_await test_node("aaaa1111-0000-0000-0000-000000000000");
    node_p b = co_await test_node("bbbb2222-0000-0000-0000-000000000000");
    co_await frames_story(a);
    window_story(a, b);
    mail_story(a, b);
    cloc.nodes.clear();
    cloc.target.clear();
    co_return 0;
}

/*! Checks ocscp's side of a copy: a file taken in pieces however the zone's bytes are cut, and
 * the answer to one sent. */
static void test_ocscp() {
    char tmp[MAX_PATH];
    GetTempPathA(MAX_PATH, tmp);
    std::string file(70000, 'x');                   /* three pieces: 32768, 32768, 4464 */
    file[0] = '\0';
    file[40000] = '\n';
    std::string stream = enc_file_open(true, uint32_t(file.size()), "");
    for (size_t at = 0; at < file.size(); at += SCP_PIECE)
        stream += enc_piece(file.substr(at, SCP_PIECE));
    stream += enc_file_end();
    std::string detail;
    bool all = true;
    for (size_t cut = 0; cut <= stream.size() && all; cut += 997) {
        scp = scp_t{};
        scp.oc_path = "/home/f";
        scp.local_path = std::string(tmp) + "ocscp_test.bin";
        take_scp_bytes(stream.substr(0, cut)) && take_scp_bytes(stream.substr(cut));
        std::string saved;
        read_file(scp.local_path, saved);
        if (!scp.done || saved != file) {
            all = false;
            detail = "cut at " + std::to_string(cut) + ": " + scp.conn.goodbye;
        }
    }
    DeleteFileA((std::string(tmp) + "ocscp_test.bin").c_str());
    check(all, "ocscp takes a file in pieces, byte for byte, however the stream is cut", detail);
    scp = scp_t{};
    take_scp_bytes(enc_written(false, "no such directory"));
    check(!scp.done && scp.conn.goodbye.find("no such directory") != std::string::npos,
          "ocscp says why a file could not be written", scp.conn.goodbye);
    scp = scp_t{};
    take_scp_bytes(enc_file_open(false, 0, "no such file"));
    check(!scp.done && scp.conn.goodbye.find("cannot read") != std::string::npos,
          "ocscp says why a file could not be read", scp.conn.goodbye);
}

static void test_claude_oc() {
    win.quiet = true;
    cloc_init();
    test_http();
    colib::pool_p pool = colib::create_pool();
    pool->sched(claude_oc_story());
    pool->run();
}

static colib::task_t watchdog() {
    co_await colib::sleep_ms(15000);
    check(false, "the socket tests finished in time");
    co_await colib::force_stop(0);
    co_return 0;
}

/*! The relay's story, then the terminal's, on one relay; the terminal's ends the pool. */
static colib::task_t stories(uint16_t cport, uint16_t kport, std::string *seen_key) {
    co_await relay_story(cport, kport);
    co_await term_story(cport, kport, seen_key);
    co_return 0;
}

/*! Runs both socket stories against one relay, on two ports Windows picks. */
static void test_sockets() {
    relay.quiet = true;
    char tmp[MAX_PATH];
    GetTempPathA(MAX_PATH, tmp);
    relay.ext_file = std::string(tmp) + "octerm_ext_test.lua";     /* never the real one */
    FILE *f = fopen(relay.ext_file.c_str(), "wb");
    fwrite(test_ext.data(), 1, test_ext.size(), f);
    fclose(f);
    term_init();
    term.conn.code = "local zone = ... -- a stand-in payload";
    term.conn.hash = payload_hash(term.conn.code);
    std::string seen_key;
    uint16_t cport = 0, kport = 0;
    SOCKET cl = listen_on(INADDR_LOOPBACK, cport), kl = listen_on(INADDR_LOOPBACK, kport);
    colib::pool_p pool = colib::create_pool();
    pool->sched(relay_accept(cl, false));
    pool->sched(relay_accept(kl, true));
    pool->sched(stories(cport, kport, &seen_key));
    pool->sched(watchdog());
    pool->run();
    check(row(term.screen, 1) == "from zone   ",
          "term.exe opens the zone (a cache miss, then the code) and shows what it draws",
          row(term.screen, 1));
    check(seen_key == "yes", "its keys reach the zone");
    check(term.conn.goodbye == "the terminal zone ended: it returned",
          "the zone ending ends the terminal, saying why", term.conn.goodbye);
}

int main() {
    setvbuf(stdout, NULL, _IONBF, 0);   /* so a crash still shows how far the checks got */
    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
    test_screen();
    test_frames();
    test_keys();
    test_claude_oc();
    test_ocscp();
    test_sockets();
    printf("%d failed\n", failures);
    return failures;
}
