/*! mcp.h - a Model Context Protocol server over HTTP on 127.0.0.1, the way Claude Code reaches
 * the tools it is given with `--mcp-config` ({"type": "http", "url": ...}).
 *
 * What Claude Code 2.1.285 sends, read off a stand-in server (2026-09-30): POSTs of JSON-RPC on
 * connections it keeps alive, first a `server/discover` probe (an error answer makes it go on
 * with `initialize`), then `notifications/initialized`, a GET for an event stream (405 declines
 * it), `tools/list`, and a `tools/call` per use of a tool. Every answer here is plain JSON, never
 * an event stream, which the protocol allows. A notification, having no id, gets 202 and no body.
 *
 * The tools are the caller's: their list, and a coroutine that runs one, which is given the
 * path the call came to, so one server can serve several callers told apart by their URL. A
 * tool's text goes out with invalid UTF-8 replaced, since a computer's programs may print any
 * bytes.
 *
 * Needs colib.h included first.
 *
 * @date 2026-09-30 */

#pragma once

#include <functional>
#include <string>
#include <vector>

#include "json.h"

using json = nlohmann::json;

struct tool_answer_t {
    bool ok = false;
    std::string text;
};

struct mcp_server_t {
    json tools = json::array();         /*!< what tools/list answers */
    std::string instructions;           /*!< initialize's `instructions`: how to use the tools */
    /*! Runs a tool: the path the call came to, the tool's name, and its arguments, as Claude
     * sent them. */
    std::function<colib::task<tool_answer_t>(std::string, std::string, json)> call;
};

struct http_req_t {
    std::string method, path, body;
};

/*! Takes one whole HTTP request off the front of `buf`. Returns 1 when one was taken, 0 when it
 * has not all arrived, and -1 when the bytes are not one this server takes. */
inline int take_http_request(std::string &buf, http_req_t &req) {
    size_t head_end = buf.find("\r\n\r\n");
    if (head_end == std::string::npos)
        return buf.size() > 65536 ? -1 : 0;
    std::string head = buf.substr(0, head_end);
    size_t line_end = head.find("\r\n");
    std::string first = head.substr(0, line_end);
    size_t sp1 = first.find(' '), sp2 = first.find(' ', sp1 + 1);
    if (sp1 == std::string::npos || sp2 == std::string::npos)
        return -1;
    req.method = first.substr(0, sp1);
    req.path = first.substr(sp1 + 1, sp2 - sp1 - 1);
    size_t length = 0;
    for (size_t at = line_end; at != std::string::npos && at < head.size();) {
        size_t next = head.find("\r\n", at + 2);
        std::string line = head.substr(at + 2, next == std::string::npos ? std::string::npos
                                                                         : next - at - 2);
        size_t colon = line.find(':');
        if (colon != std::string::npos && _stricmp(line.substr(0, colon).c_str(),
                                                   "Content-Length") == 0)
            length = size_t(strtoull(line.c_str() + colon + 1, NULL, 10));
        at = next;
    }
    if (length > (16u << 20))
        return -1;
    if (buf.size() < head_end + 4 + length)
        return 0;
    req.body = buf.substr(head_end + 4, length);
    buf.erase(0, head_end + 4 + length);
    return 1;
}

inline std::string http_response(int status, const std::string &reason, const std::string &body) {
    std::string r = "HTTP/1.1 " + std::to_string(status) + " " + reason + "\r\n"
                    "Content-Length: " + std::to_string(body.size()) + "\r\n"
                    "Connection: keep-alive\r\n";
    if (!body.empty())
        r += "Content-Type: application/json\r\n";
    if (status == 405)
        r += "Allow: POST\r\n";
    return r + "\r\n" + body;
}

inline std::string rpc_error(const json &id, int code, const std::string &msg) {
    json e = {{"jsonrpc", "2.0"}, {"id", id}, {"error", {{"code", code}, {"message", msg}}}};
    return e.dump();
}

inline std::string rpc_result(const json &id, const json &result) {
    json r = {{"jsonrpc", "2.0"}, {"id", id}, {"result", result}};
    return r.dump(-1, ' ', false, json::error_handler_t::replace);
}

/*! Answers one JSON-RPC message: the JSON to send back, or "" for a notification. */
inline colib::task<std::string> mcp_answer(mcp_server_t &mcp, std::string path,
                                           std::string body) {
    json req = json::parse(body, nullptr, false);
    if (req.is_discarded() || !req.is_object())
        co_return rpc_error(nullptr, -32700, "not a JSON-RPC message");
    if (!req.contains("id"))
        co_return std::string();
    json id = req["id"];
    std::string method = req.value("method", "");
    json params = req.value("params", json::object());
    if (method == "initialize") {
        json result = {
            {"protocolVersion", params.value("protocolVersion", "2025-06-18")},
            {"capabilities", {{"tools", json::object()}}},
            {"serverInfo", {{"name", "oc"}, {"version", "1"}}},
            {"instructions", mcp.instructions}};
        co_return rpc_result(id, result);
    }
    if (method == "tools/list")
        co_return rpc_result(id, {{"tools", mcp.tools}});
    if (method == "ping")
        co_return rpc_result(id, json::object());
    if (method != "tools/call")
        co_return rpc_error(id, -32601, "no method " + method);
    tool_answer_t a = co_await mcp.call(path, params.value("name", ""),
                                        params.value("arguments", json::object()));
    json content = json::array();
    content.push_back({{"type", "text"}, {"text", a.text}});
    co_return rpc_result(id, {{"content", content}, {"isError", !a.ok}});
}

/*! Serves one connection: request after request, each answered before the next is read. */
inline colib::task_t mcp_session(mcp_server_t &mcp, SOCKET s) {
    std::string buf;
    std::vector<char> chunk(16384);
    bool open = true;
    while (open) {
        http_req_t req;
        int rc;
        while (open && (rc = take_http_request(buf, req)) == 0) {
            SSIZE_T n = co_await colib::read((HANDLE)s, chunk.data(), chunk.size());
            if (n <= 0)
                open = false;
            else
                buf.append(chunk.data(), size_t(n));
        }
        if (!open || rc < 0)
            break;
        std::string resp;
        if (req.method == "POST") {
            std::string body = co_await mcp_answer(mcp, req.path, req.body);
            resp = body.empty() ? http_response(202, "Accepted", "")
                                : http_response(200, "OK", body);
        } else {
            resp = http_response(405, "Method Not Allowed", "");
        }
        open = co_await colib::write_sz((HANDLE)s, resp.data(), resp.size()) == colib::ERROR_OK;
    }
    closesocket(s);
    co_return 0;
}

/*! Accepts Claude Code's connections for as long as the program runs. */
inline colib::task_t mcp_accept(mcp_server_t &mcp, SOCKET listener) {
    while (true) {
        sockaddr_in addr = {};
        uint32_t len = sizeof(addr);
        SOCKET s = co_await colib::accept(listener, (sockaddr *)&addr, &len);
        if (s == INVALID_SOCKET) {
            co_await colib::sleep_ms(500);
            continue;
        }
        co_await colib::sched(mcp_session(mcp, s));
    }
    co_return 0;
}
