/*! claude-oc.h - claude-oc: the user's own Claude Code, answering the `claude` program on the
 * base's computers, each with that computer as its tools; and the mail between them.
 *
 * claude-oc.exe serves every computer on the relay (the "claude-oc network", the user's words),
 * or those whose address starts as given. A watcher connection sees each computer as it comes
 * and gives it a node: a connector (connector.h) of its own, which opens the "claude-oc" zone
 * (claude-oc.lua, the payload beside it) there, installs `claude` (/home/bin/claude.lua, which
 * OpenOS's PATH reaches), and keeps the link, connecting again every 5 s when the computer or
 * the relay goes. A player types prompts into `claude`; each one runs `claude -p` on this PC,
 * headless, on the user's own login: no API key, which is dropped from its environment so
 * nothing is billed by the token (the user will buy nothing else). Its only tools are this
 * program's, served over MCP on 127.0.0.1 (mcp.h) at /mcp/<address>, so each run's tools are
 * its own computer's: oc_run, oc_lua, oc_read and oc_write, carried out by that computer's zone
 * with anything its shell may do (the user's choice), and oc_send and oc_mail, the mail. It has
 * no tool of Claude Code's own (`--tools ""`), reads none of the user's settings, CLAUDE.md
 * files or other MCP servers (`--setting-sources ""`, `--strict-mcp-config`), runs in a folder
 * of its own (work/), and has system.md as its whole system prompt.
 *
 * One computer is one Claude session (the user's words: "An OC computer means a claude
 * session"). The first `claude` run on it makes the session, working in the directory it was
 * run in; every prompt after resumes it, whoever types it; and only `claude stop` ends it (the
 * user's choice). It is kept in work/<address>.json (its Claude Code session id and working
 * directory), so it outlives `claude` exiting, the computer losing power, octerm reconnecting
 * and this program restarting. One prompt at a time per computer; the computers' prompts run
 * side by side. Anyone at a computer may use it (the user's choice).
 *
 * The window (window.h) is every session's other end: it shows each computer's prompts,
 * tools and answers, and a line typed there is a prompt in the session of the window's
 * computer, which that computer's `claude` shows as "PC>" with its answer (the user's choice).
 * The window's computer shows before its `> `; Ctrl+Left and Ctrl+Right step through the
 * computers, and `@<address start> text` picks one for that line and after (the user's
 * choices). Mail (mail.h): `claude send <address start> <text>` on a computer, or oc_send from
 * its Claude, leaves a letter in the other computer's mailbox, sent with the sender's address;
 * it waits there, and nothing runs because it came (the user's choice).
 *
 * Needs colib.h included first.
 *
 * @date 2026-10-01 */

#pragma once

#include <algorithm>
#include <deque>
#include <map>
#include <memory>

#include "child.h"
#include "connector.h"
#include "mail.h"
#include "mcp.h"
#include "window.h"

/*! A prompt runs at most this long before its claude is ended. */
constexpr int PROMPT_LIMIT_S = 15 * 60;
/*! A tool's own time limit, which the zone keeps: the default, and the most Claude may ask. */
constexpr int TOOL_DEFAULT_S = 30, TOOL_MAX_S = 600;

/*! Variables a Claude Code session sets for what it starts: claude-oc.exe run from one (as Claude
 * tests it) must not hand them to its own claude. And the API key, which would bill by token. */
inline const std::vector<std::string> DROPPED_ENV = {
    "ANTHROPIC_API_KEY", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID",
    "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_MESSAGING_SOCKET",
    "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_EXECPATH", "CLAUDE_PID", "CLAUDE_EFFORT"};

struct tool_wait_t {
    colib::sem_p done;
    bool finished = false;
    tool_answer_t answer;
};

struct prompt_t {
    int id = 0;                         /*!< the computer's number for it; 0 for the PC's */
    std::string text;
    bool from_pc = false;               /*!< typed in claude-oc.exe's window */
};

/*! One computer: its link, its session, its prompts and the tools asked of it. */
struct node_t {
    std::string addr;
    zone_link_t conn;
    bool has_session = false;
    std::string session;                /*!< its Claude Code session id; "" before its first */
    std::string cwd;                    /*!< its working directory on the computer */
    int conversation = 0;               /*!< counts sessions begun and ended; a prompt still
                                             running from an ended one keeps nothing */
    std::string zone_buf;               /*!< the zone's bytes that are not a whole frame yet */
    std::deque<prompt_t> prompts;
    colib::sem_p prompt_ready;
    bool busy = false;                  /*!< a prompt is running */
    HANDLE running = NULL;              /*!< its claude, for the time limit */
    bool timed_out = false;             /*!< the time limit ended it */
    uint64_t prompt_count = 0;
    int next_tool = 0;
    std::map<int, std::shared_ptr<tool_wait_t>> waiting;     /*!< tools asked of the zone */
};
using node_p = std::shared_ptr<node_t>;

struct cloc_t {
    mcp_server_t mcp;
    uint16_t port = 7778;               /*!< the relay's connector port */
    uint16_t mcp_port = 7779;
    std::string prefix;                 /*!< serve only computers whose address starts so */
    std::string code, hash;             /*!< claude-oc.lua, the zone, and its hash */
    std::string program;                /*!< claude.lua, the `claude` installed on the computers */
    std::string work;                   /*!< the folder claude runs in, with its trailing '\' */
    std::string system_file;            /*!< system.md: claude's whole system prompt */
    std::string model;                  /*!< claude's --model; "" for the user's default */
    std::map<std::string, node_p> nodes;    /*!< every computer seen, by address */
    std::string target;                 /*!< the window's computer */
    zone_link_t watch;                  /*!< the connection that sees computers come */
    std::deque<std::string> arrivals;   /*!< computers seen that have no node yet */
    colib::sem_p arrived;
};
inline cloc_t cloc;

/*! Returns an address as the window shows it: its first 8 characters. */
inline std::string short_addr(const std::string &addr) {
    return addr.substr(0, 8);
}

/*! Writes a line about one computer to the window. */
inline void nsay(const node_t &n, const std::string &line) {
    say("[" + short_addr(n.addr) + "] " + line);
}

/*! Returns `s` on one line and at most `n` characters, for the window and for notes. */
inline std::string clip(std::string s, size_t n = 100) {
    for (char &ch : s)
        if (ch == '\n' || ch == '\r' || ch == '\t')
            ch = ' ';
    return s.size() > n ? s.substr(0, n - 3) + "..." : s;
}

inline void zone_out(node_t &n, const std::string &frames) {
    zone_send(n.conn, frames);
}

/* MAIL: the mailboxes, kept in work/
=================================================================================================*/

/*! The mailbox that is no computer's: the computers' Claudes and players send it questions
 * about Minecraft (recipes and the like), and a Claude Code session on the PC, told by the
 * user to watch it, answers them from the modpack's own files (the user's design, 2026-10-01).
 * It only answers: it sends first to no one. Its end is the tool port's /mcp/main-srv, which
 * has the mail tools only. */
inline const std::string MAIN_SRV = "main-srv";

inline std::string mailbox_file(const std::string &addr) {
    return cloc.work + addr + ".mail.json";
}

/*! Returns every address this program knows: main-srv, the computers seen on the relay, and
 * those with a session or a mailbox kept. */
inline std::vector<std::string> known_addresses() {
    std::vector<std::string> all = {MAIN_SRV};
    for (const auto &[addr, n] : cloc.nodes)
        all.push_back(addr);
    WIN32_FIND_DATAA fd;
    HANDLE h = cloc.work.empty() ? INVALID_HANDLE_VALUE
                                 : FindFirstFileA((cloc.work + "*.json").c_str(), &fd);
    if (h == INVALID_HANDLE_VALUE)
        return all;
    do {
        std::string name = fd.cFileName;
        for (const char *end : {".mail.json", ".json"}) {
            size_t n = strlen(end);
            if (name.size() > n && name.compare(name.size() - n, n, end) == 0) {
                std::string addr = name.substr(0, name.size() - n);
                if (addr.find('.') == std::string::npos && addr != "mcp"
                        && std::find(all.begin(), all.end(), addr) == all.end())
                    all.push_back(addr);
                break;
            }
        }
    } while (FindNextFileA(h, &fd));
    FindClose(h);
    return all;
}

/*! Picks the one address that starts with `start` (a whole address picks itself); "" and the
 * reason in `why` when none or several do. */
inline std::string pick_address(const std::vector<std::string> &all, const std::string &start,
                                std::string &why) {
    std::vector<std::string> hits;
    for (const std::string &a : all) {
        if (a == start)
            return a;
        if (!start.empty() && a.rfind(start, 0) == 0)
            hits.push_back(a);
    }
    if (hits.size() == 1)
        return hits[0];
    why = hits.empty() ? "no computer's address starts with " + start
                       : "several computers' addresses start with " + start + ":";
    for (const std::string &a : hits)
        why += " " + a;
    return "";
}

/*! Leaves a letter from `from` in the mailbox of the computer whose address starts `to`, and
 * tells that computer's `claude`, if one is open. Returns false, with why in `msg`, when there
 * is no one computer to send it to; otherwise says where it went. */
inline bool send_mail(const std::string &from, const std::string &to, const std::string &text,
                      std::string &msg) {
    std::string addr = pick_address(known_addresses(), to, msg);
    if (addr.empty())
        return false;
    std::vector<letter_t> box = read_mailbox(mailbox_file(addr));
    box.push_back({from, mail_time(), text});
    if (!cloc.work.empty() && !write_mailbox(mailbox_file(addr), box)) {
        msg = "cannot write " + mailbox_file(addr);
        return false;
    }
    auto it = cloc.nodes.find(addr);
    if (it != cloc.nodes.end() && it->second->conn.state == conn_state::running)
        zone_out(*it->second, enc_letter(from, text));
    say("[" + short_addr(from) + "] mail to " + short_addr(addr) + ": " + clip(text, 80));
    msg = "sent to " + addr;
    return true;
}

/*! Returns a computer's mailbox as text, and marks its letters shown. */
inline std::string list_mail(const std::string &addr) {
    std::vector<letter_t> box = read_mailbox(mailbox_file(addr));
    std::string text = mailbox_text(box);
    if (!cloc.work.empty())
        write_mailbox(mailbox_file(addr), box);
    return text;
}

/*! Returns the letters a computer's Claude has not been given, and marks them seen. */
inline std::string take_unseen_mail(const std::string &addr) {
    std::vector<letter_t> box = read_mailbox(mailbox_file(addr));
    std::string text = unseen_mail(box);
    if (!text.empty() && !cloc.work.empty())
        write_mailbox(mailbox_file(addr), box);
    return text;
}

/* TOOLS: asked of a computer's zone, which runs them there; the mail ones run here
=================================================================================================*/

/*! Ends a tool's wait with its answer, once: the zone's, or a failure. */
inline void finish_tool(node_t &n, int id, bool ok, const std::string &text) {
    auto it = n.waiting.find(id);
    if (it == n.waiting.end() || it->second->finished)
        return;
    it->second->finished = true;
    it->second->answer = {ok, text};
    it->second->done->signal();
}

/*! Fails every tool still waiting: the computer they were asked of has gone. */
inline void fail_waiting(node_t &n, const std::string &why) {
    std::vector<int> ids;
    for (const auto &[id, w] : n.waiting)
        ids.push_back(id);
    for (int id : ids)
        finish_tool(n, id, false, why);
}

/*! Fails a tool the zone has not answered well after its own time limit. */
inline colib::task_t tool_watchdog(node_p n, int id, int limit_s) {
    co_await colib::sleep_s(uint64_t(limit_s) + 60);
    finish_tool(*n, id, false, "the computer did not answer in time");
    co_return 0;
}

/*! Returns what a tool call is about, for the window and the player's screen. */
inline std::string tool_summary(const std::string &name, const json &args) {
    const char *key = name == "oc_run" ? "command" : name == "oc_lua" ? "code"
                    : name == "oc_send" ? "to" : "path";
    std::string what = args.contains(key) && args[key].is_string() ? args[key].get<std::string>()
                                                                   : std::string();
    return name + " " + clip(what, 70);
}

inline std::string text_arg(const json &args, const char *key) {
    return args.contains(key) && args[key].is_string() ? args[key].get<std::string>() : "";
}

/*! Runs a mail tool for main-srv: oc_mail lists its questions, marking them shown; oc_send
 * answers one. */
inline tool_answer_t main_srv_tool(const std::string &name, const json &args) {
    say("[" + MAIN_SRV + "] tool " + tool_summary(name, args));
    if (name == "oc_mail")
        return {true, list_mail(MAIN_SRV)};
    if (name != "oc_send")
        return {false, MAIN_SRV + " has the mail tools only"};
    std::string msg;
    bool ok = send_mail(MAIN_SRV, text_arg(args, "to"), text_arg(args, "text"), msg);
    return {ok, msg};
}

/*! Runs a tool for the computer the call's path names (/mcp/<address>): the mail ones here,
 * the rest by the computer's zone, waiting for its answer; or main-srv's mail. */
inline colib::task<tool_answer_t> call_tool(std::string path, std::string name, json args) {
    if (path == "/mcp/" + MAIN_SRV)
        co_return main_srv_tool(name, args);
    auto it = cloc.nodes.find(path.rfind("/mcp/", 0) == 0 ? path.substr(5) : "");
    if (it == cloc.nodes.end())
        co_return tool_answer_t{false, "no computer is served at " + path};
    node_p n = it->second;
    nsay(*n, "  tool " + tool_summary(name, args));
    if (name == "oc_send") {
        std::string msg;
        bool ok = send_mail(n->addr, text_arg(args, "to"), text_arg(args, "text"), msg);
        co_return tool_answer_t{ok, msg};
    }
    if (name == "oc_mail")
        co_return tool_answer_t{true, list_mail(n->addr)};
    if (n->conn.state != conn_state::running)
        co_return tool_answer_t{false, "the computer is not connected to claude-oc right now"};
    std::vector<std::pair<std::string, std::string>> kv;
    for (auto a = args.begin(); a != args.end(); ++a)
        kv.push_back({a.key(), a->is_string() ? a->get<std::string>() : a->dump()});
    int limit = TOOL_DEFAULT_S;
    if (args.contains("timeout") && args["timeout"].is_number())
        limit = std::clamp(args["timeout"].get<int>(), 1, TOOL_MAX_S);
    int id = n->next_tool = (n->next_tool + 1) % 65536;
    auto w = std::make_shared<tool_wait_t>();
    w->done = co_await colib::create_sem(0);
    n->waiting[id] = w;
    zone_out(*n, enc_note(tool_summary(name, args)) + enc_tool(id, name, kv));
    co_await colib::sched(tool_watchdog(n, id, limit));
    co_await w->done->wait();
    n->waiting.erase(id);
    co_return w->answer;
}

/*! Returns the tools, as tools/list gives them to Claude. */
inline json tool_list() {
    json timeout = {{"type", "number"}, {"description", "seconds before it is stopped; default "
                    + std::to_string(TOOL_DEFAULT_S) + ", at most " + std::to_string(TOOL_MAX_S)}};
    json str = {{"type", "string"}};
    auto tool = [](const char *name, const char *what, json props, json required) {
        return json{{"name", name}, {"description", what},
                    {"inputSchema", {{"type", "object"}, {"properties", props},
                                     {"required", required}}}};
    };
    return json::array({
        tool("oc_run", "Runs a command line in the computer's OpenOS shell, as typed at its "
             "prompt: programs on its PATH, pipes, redirections, `;`. The working directory "
             "persists through the session (cd works). stdin is empty, so a program that "
             "waits for keys gets nothing. Returns what it printed, stdout and stderr, cut at "
             "16000 characters, and its exit status.",
             {{"command", str}, {"timeout", timeout}}, {"command"}),
        tool("oc_lua", "Runs a chunk of Lua on the computer, with OpenOS's libraries at hand "
             "(component, sides, ... work as globals). Returns what it printed and the values "
             "it returned, serialized.",
             {{"code", str}, {"timeout", timeout}}, {"code"}),
        tool("oc_read", "Returns a file on the computer, whole, up to 60000 bytes. A relative "
             "path starts at the working directory.",
             {{"path", str}}, {"path"}),
        tool("oc_write", "Writes a file on the computer, replacing what was there, and makes "
             "its folder if needed. A relative path starts at the working directory.",
             {{"path", str}, {"content", str}}, {"path", "content"}),
        tool("oc_send", "Sends mail to another computer of the base, by the start of its "
             "address; it goes with this computer's address, and waits in that computer's "
             "mailbox. Send only when the player asks, or it plainly helps them.",
             {{"to", str}, {"text", str}}, {"to", "text"}),
        tool("oc_mail", "Returns this computer's mailbox: the mail other computers sent it, "
             "oldest first.", json::object(), json::array()),
    });
}

/* SESSIONS: one per computer, kept in work/
=================================================================================================*/

inline std::string session_file(const node_t &n) {
    return cloc.work + n.addr + ".json";
}

/*! Keeps the session on disk, or removes it once it has ended. Not in the tests: they have no
 * work folder. */
inline void save_session(node_t &n) {
    if (cloc.work.empty())
        return;
    if (!n.has_session) {
        DeleteFileA(session_file(n).c_str());
        return;
    }
    std::string text = json{{"session", n.session}, {"cwd", n.cwd}}.dump(2);
    FILE *f = fopen(session_file(n).c_str(), "wb");
    if (!f) {
        nsay(n, "cannot write " + session_file(n) + "; the session is kept only until this ends");
        return;
    }
    fwrite(text.data(), 1, text.size(), f);
    fclose(f);
}

/*! Takes up a computer's session from disk, if it has one. */
inline void load_session(node_t &n) {
    n.has_session = false;
    n.session.clear();
    n.cwd.clear();
    std::string text;
    if (cloc.work.empty() || !read_file(session_file(n), text))
        return;
    json j = json::parse(text, nullptr, false);
    if (!j.is_object())
        return;
    n.has_session = true;
    n.session = j.value("session", "");
    n.cwd = j.value("cwd", "/home");
}

/* PROMPTS: each one a run of claude -p
=================================================================================================*/

inline void no_answer(node_t &n, int id, const std::string &why) {
    nsay(n, "  no answer: " + clip(why));
    zone_out(n, enc_no_answer(id, why));
}

/*! Writes where a computer's claude finds its tools, and returns the file. */
inline std::string write_mcp_config(const node_t &n) {
    std::string file = cloc.work + n.addr + ".mcp.json";
    json cfg = {{"mcpServers", {{"oc", {{"type", "http"}, {"url", "http://127.0.0.1:"
                 + std::to_string(cloc.mcp_port) + "/mcp/" + n.addr}}}}}};
    std::string text = cfg.dump(2);
    if (FILE *f = fopen(file.c_str(), "wb")) {
        fwrite(text.data(), 1, text.size(), f);
        fclose(f);
    }
    return file;
}

/*! Returns claude's command line for a computer's next prompt; the prompt goes in on stdin. */
inline std::string claude_cmdline(const node_t &n) {
    std::string cmd = "claude -p --output-format json --tools \"\" --setting-sources \"\""
                      " --strict-mcp-config --mcp-config \"" + write_mcp_config(n) + "\""
                      " --allowedTools mcp__oc --system-prompt-file \"" + cloc.system_file + "\"";
    if (!cloc.model.empty())
        cmd += " --model " + cloc.model;
    if (!n.session.empty())
        cmd += " --resume " + n.session;
    return cmd;
}

/*! Ends a computer's running claude when it passes the time limit. */
inline colib::task_t prompt_watchdog(node_p n, uint64_t count) {
    co_await colib::sleep_s(PROMPT_LIMIT_S);
    if (n->prompt_count == count && n->running) {
        n->timed_out = true;
        TerminateProcess(n->running, 1);
    }
    co_return 0;
}

/*! Takes what claude printed (--output-format json: one object) and answers the prompt. */
inline void take_claude_output(node_t &n, int id, const std::string &out, DWORD code,
                               int conversation) {
    json j = json::parse(out, nullptr, false);
    if (j.is_discarded() || !j.is_object()) {
        std::string err;
        read_file(cloc.work + n.addr + ".stderr.txt", err);
        no_answer(n, id, n.timed_out ? "no answer within " + std::to_string(PROMPT_LIMIT_S / 60)
                                       + " minutes"
                                     : "claude gave no answer (exit code " + std::to_string(code)
                                       + "): " + clip(err.size() > 300 ? err.substr(err.size()
                                                                                    - 300)
                                                                       : err, 300));
        return;
    }
    if (conversation == n.conversation && n.has_session) {
        n.session = j.value("session_id", n.session);
        save_session(n);
    }
    std::string result = j.contains("result") && j["result"].is_string()
                       ? j["result"].get<std::string>() : std::string();
    if (j.value("is_error", false)) {
        no_answer(n, id, result.empty() ? "claude failed: " + j.value("subtype", "an error")
                                        : result);
        return;
    }
    nsay(n, "claude:");
    window_print(result + "\n\n");
    zone_out(n, enc_answer(id, result));
}

/*! Returns the prompt claude is given: the text, after the mail its computer's Claude has not
 * been given yet, which is marked seen. */
inline std::string with_mail(node_t &n, const std::string &text) {
    std::string mail = take_unseen_mail(n.addr);
    if (mail.empty())
        return text;
    nsay(n, "  with the new mail in the prompt");
    return "[New mail for this computer, from other computers of the base:]\n" + mail
         + "[The player's prompt:]\n" + text;
}

/*! Runs one prompt: claude -p, whose output is read here until it exits. */
inline colib::task_t run_prompt(node_p n, prompt_t p) {
    nsay(*n, (p.from_pc ? "pc> " : "game> ") + p.text);
    std::string in_file = cloc.work + n->addr + ".prompt.txt";
    std::string text = with_mail(*n, p.text);
    FILE *f = fopen(in_file.c_str(), "wb");
    if (f) {
        fwrite(text.data(), 1, text.size(), f);
        fclose(f);
    }
    child_t ch;
    std::string why;
    if (!f || !start_child(claude_cmdline(*n), cloc.work, in_file,
                           cloc.work + n->addr + ".stderr.txt", env_without(DROPPED_ENV), ch,
                           why)) {
        no_answer(*n, p.id, "claude did not start on the PC (" + (f ? why : "no prompt file")
                  + "); is Claude Code installed there?");
        co_return 0;
    }
    int conversation = n->conversation;
    uint64_t count = ++n->prompt_count;
    n->running = ch.proc;
    n->timed_out = false;
    co_await colib::sched(prompt_watchdog(n, count));
    std::string out;
    std::vector<char> chunk(16384);
    SSIZE_T got;
    while ((got = co_await colib::read(ch.out, chunk.data(), chunk.size())) > 0)
        out.append(chunk.data(), size_t(got));
    n->running = NULL;
    ++n->prompt_count;                  /* the watchdog, still asleep, finds nothing to end */
    DWORD code = end_child(ch);
    take_claude_output(*n, p.id, out, code, conversation);
    co_return 0;
}

/*! Runs a computer's prompts one after the other, as they come. */
inline colib::task_t prompt_loop(node_p n) {
    while (true) {
        co_await n->prompt_ready->wait();
        while (!n->prompts.empty()) {
            prompt_t p = n->prompts.front();
            n->prompts.pop_front();
            n->busy = true;
            co_await run_prompt(n, p);
            n->busy = false;
        }
    }
    co_return 0;
}

/* THE WINDOW'S PART: which computer it talks to, and its prompts
=================================================================================================*/

/*! Returns the computer an `@<address start>` names among those served; null, saying why,
 * when none or several do. */
inline node_p node_named(const std::string &start) {
    std::vector<std::string> served;
    for (const auto &[addr, n] : cloc.nodes)
        served.push_back(addr);
    std::string why, addr = pick_address(served, start, why);
    if (addr.empty()) {
        say(why);
        return nullptr;
    }
    return cloc.nodes[addr];
}

/*! Makes `n` the window's computer, and says so. */
inline void choose_target(const node_p &n) {
    cloc.target = n->addr;
    say("the window talks to " + n->addr + (n->has_session ? ", working in " + n->cwd
                                            : std::string(", which has no session yet")));
}

/*! Steps the window's computer through those served: Ctrl+Left back, Ctrl+Right on. */
inline void step_target(int by) {
    if (cloc.nodes.empty())
        return;
    auto it = cloc.nodes.find(cloc.target);
    if (it == cloc.nodes.end())
        it = cloc.nodes.begin();
    else if (by > 0)
        it = ++it == cloc.nodes.end() ? cloc.nodes.begin() : it;
    else
        it = it == cloc.nodes.begin() ? std::prev(cloc.nodes.end()) : std::prev(it);
    choose_target(it->second);
    draw_typed();
}

/*! Takes a prompt typed in the window: it goes to the window's computer's session, or to the
 * one its `@<address start>` names, which the window then keeps; that computer's `claude`, if
 * one runs, shows it and its answer. */
inline void pc_prompt(const std::string &line) {
    std::string text = line;
    node_p n;
    if (text[0] == '@') {
        size_t sp = text.find(' ');
        n = node_named(text.substr(1, sp == std::string::npos ? std::string::npos : sp - 1));
        if (!n)
            return;
        text = sp == std::string::npos ? "" : text.substr(sp + 1);
        if (n->addr != cloc.target)
            choose_target(n);
        if (text.empty())
            return;
    } else if (cloc.nodes.count(cloc.target)) {
        n = cloc.nodes[cloc.target];
    } else {
        say("pc> " + text + "   (not sent: no computer is served yet)");
        return;
    }
    if (n->conn.state != conn_state::running)
        nsay(*n, "pc> " + text + "   (not sent: the computer is not attached now)");
    else if (!n->has_session)
        nsay(*n, "pc> " + text + "   (not sent: it has no session yet; the first `claude` run "
             "there makes one)");
    else if (n->busy || !n->prompts.empty())
        nsay(*n, "pc> " + text + "   (not sent: still answering the last prompt)");
    else {
        zone_out(*n, enc_pc_prompt(text));
        n->prompts.push_back({0, text, true});
        n->prompt_ready->signal();
    }
}

/*! Returns what the window's prompt starts with: its computer. */
inline std::string target_label() {
    return cloc.target.empty() ? std::string() : short_addr(cloc.target);
}

/* THE ZONE: a computer's frames, and the link to it
=================================================================================================*/

/*! Takes a frame of the session's: begun ('B'), ended ('R'), its directory moved ('D'). */
inline void take_session_frame(node_t &n, char type, const std::string &dir) {
    if (type == 'R') {
        n.has_session = false;
        n.session.clear();
        nsay(n, "`claude stop`: its session has ended");
    } else if (type == 'B') {
        n.has_session = true;
        n.session.clear();
        nsay(n, "the first `claude`: a new session, working in " + dir);
    }
    if (type != 'R')
        n.cwd = dir;
    if (type != 'D')
        n.conversation++;
    save_session(n);
}

/*! Takes a prompt `claude` sent, when the session can take one. */
inline void take_prompt(node_t &n, int id, const std::string &text) {
    if (!n.has_session) {
        no_answer(n, id, "the computer has no session; run claude again");
    } else if (n.busy || !n.prompts.empty()) {
        no_answer(n, id, "still answering the last prompt");
    } else {
        n.prompts.push_back({id, text});
        n.prompt_ready->signal();
    }
}

/*! Takes one frame the zone sent, at the front of `r`. Returns 1 when taken, 0 when it has not
 * all arrived (`r` is left where it was), and -1 when it is not a frame of this zone. */
inline int take_cloc_frame(node_t &n, reader_t &r) {
    reader_t start = r;
    char type = char(r.u(1));
    std::string text, to, msg;
    switch (type) {
    case 'R':
        take_session_frame(n, type, "");
        return 1;
    case 'B':
    case 'D':
        if (!r.str(text, 2))
            break;
        take_session_frame(n, type, text);
        return 1;
    case 'G':
        if (!r.has(2))
            break;
        zone_out(n, enc_reply(int(r.u(2)), true, list_mail(n.addr)));
        return 1;
    case 'Q':
    case 'U':
    case 'M': {
        if (!r.has(type == 'U' ? 3 : 2))
            break;
        int id = int(r.u(2));
        bool ok = type == 'U' && r.u(1) != 0;
        if ((type == 'M' && !r.str(to)) || !r.str(text, 4))
            break;
        if (type == 'U') {
            finish_tool(n, id, ok, text);
        } else if (type == 'Q') {
            take_prompt(n, id, text);
        } else {
            bool sent = send_mail(n.addr, to, text, msg);
            zone_out(n, enc_reply(id, sent, msg));
        }
        return 1;
    }
    default:
        r = start;
        return -1;
    }
    r = start;                          /* it has not all arrived */
    return 0;
}

/*! Takes the zone's bytes, cut anywhere. */
inline bool take_cloc_bytes(node_t &n, const std::string &bytes) {
    n.zone_buf += bytes;
    const uint8_t *begin = reinterpret_cast<const uint8_t *>(n.zone_buf.data());
    reader_t r = {begin, begin + n.zone_buf.size()};
    int rc = 1;
    while (r.has(1) && (rc = take_cloc_frame(n, r)) == 1) {}
    n.zone_buf.erase(0, size_t(r.p - begin));
    if (rc == -1)
        n.conn.goodbye = "the claude-oc zone sent something that is not its frame";
    return rc != -1;
}

/*! Installs `claude` on the computer once its zone is open, and tells the zone the computer's
 * session, if it has one. */
inline bool node_opened(node_t &n) {
    load_session(n);
    nsay(n, "attached; `claude` is installed there; " + (n.has_session
         ? "its session goes on, working in " + n.cwd : std::string("it has no session yet")));
    zone_out(n, enc_program(cloc.program) + enc_session(n.has_session, n.cwd));
    if (cloc.target.empty())
        cloc.target = n.addr;
    return true;
}

/*! Keeps a link to one computer: connects, runs it until it ends, and connects again 5 s later.
 * While the computer is away, the link waits for it on the relay. */
inline colib::task_t node_link(node_p n) {
    while (true) {
        SOCKET s = co_await connect_relay(cloc.port);
        if (s != INVALID_SOCKET) {
            zone_link_t &c = n->conn;
            c.state = conn_state::choosing;
            c.addr.clear();
            c.list.clear();
            c.goodbye.clear();
            n->zone_buf.clear();
            c.out = co_await open_sender(s);
            co_await conn_session(c, s);
            if (c.state == conn_state::running || c.goodbye.find("zone") != std::string::npos)
                nsay(*n, c.goodbye);
            fail_waiting(*n, "the computer went away: " + c.goodbye);
        }
        co_await colib::sleep_s(5);
    }
    co_return 0;
}

/*! Makes a node for a computer seen for the first time. */
inline node_p make_node(const std::string &addr) {
    node_p n = std::make_shared<node_t>();
    n->addr = addr;
    zone_link_t &c = n->conn;
    c.zone = "claude-oc";
    c.prefix = addr;
    c.code = cloc.code;
    c.hash = cloc.hash;
    node_t *raw = n.get();              /* the node outlives its link: nodes are never removed */
    c.on_opened = [raw] { return node_opened(*raw); };
    c.on_zone_bytes = [raw](const std::string &b) { return take_cloc_bytes(*raw, b); };
    cloc.nodes[addr] = n;
    return n;
}

/*! Gives every computer that arrives a node, its link and its prompts. */
inline colib::task_t serve_arrivals() {
    while (true) {
        co_await cloc.arrived->wait();
        while (!cloc.arrivals.empty()) {
            std::string addr = cloc.arrivals.front();
            cloc.arrivals.pop_front();
            if (cloc.nodes.count(addr))
                continue;
            node_p n = make_node(addr);
            n->prompt_ready = co_await colib::create_sem(0);
            co_await colib::sched(prompt_loop(n));
            co_await colib::sched(node_link(n));
        }
    }
    co_return 0;
}

/*! Takes the relay's list of computers on the watcher: the ones served and not seen before
 * arrive. The watcher never attaches. */
inline void watch_list() {
    for (const std::string &a : cloc.watch.list)
        if (a.rfind(cloc.prefix, 0) == 0 && !cloc.nodes.count(a)
                && std::find(cloc.arrivals.begin(), cloc.arrivals.end(), a)
                   == cloc.arrivals.end()) {
            cloc.arrivals.push_back(a);
            cloc.arrived->signal();
        }
}

/*! Keeps the watcher connected, connecting again every 5 s while there is no relay. */
inline colib::task_t watch_link() {
    bool said = false;
    while (true) {
        SOCKET s = co_await connect_relay(cloc.port);
        if (s == INVALID_SOCKET) {
            if (!said)
                say("no relay on " + relay_host() + ":" + std::to_string(cloc.port)
                    + "; trying every 5 s");
            said = true;
        } else {
            said = false;
            zone_link_t &c = cloc.watch;
            c.state = conn_state::choosing;
            c.goodbye.clear();
            c.out = co_await open_sender(s);
            co_await conn_session(c, s);
        }
        co_await colib::sleep_s(5);
    }
    co_return 0;
}

/*! Gives the watcher, the window and the MCP server claude-oc's own parts. */
inline void cloc_init() {
    cloc.watch.on_list = watch_list;
    cloc.mcp.tools = tool_list();
    cloc.mcp.call = call_tool;
    cloc.mcp.instructions = "These tools act on one OpenComputers computer in a Minecraft "
                            "world, the one whose player is talking to you; oc_send and "
                            "oc_mail are its mail with the base's other computers.";
    win.on_line = pc_prompt;
    win.on_switch = step_target;
    win.label = target_label;
}
