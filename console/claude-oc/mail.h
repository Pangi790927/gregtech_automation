/*! mail.h - the mailboxes of the claude-oc network: one per computer, kept on the PC in
 * work/<address>.mail.json (the user's mailbox: "claude send <address> <text>", sent with the
 * sender's address).
 *
 * A letter has a sender, a time and a text, and two marks: shown, once `claude mail` has listed
 * it on its computer, and seen, once that computer's Claude has been given it, with its next
 * prompt. Mail only waits: nothing runs because it came (the user's choice), so two Claudes
 * cannot talk each other into a loop on the user's plan. A mailbox keeps its last 100 letters.
 *
 * @date 2026-10-01 */

#pragma once

#include <ctime>
#include <string>
#include <vector>

#include "json.h"

using json = nlohmann::json;

constexpr size_t MAILBOX_KEEPS = 100;

struct letter_t {
    std::string from, time, text;
    bool shown = false;                 /*!< listed by `claude mail` */
    bool seen = false;                  /*!< given to the computer's Claude */
};

/*! Returns the letters kept in `file`; none when there is no such file. */
inline std::vector<letter_t> read_mailbox(const std::string &file) {
    std::vector<letter_t> box;
    FILE *f = fopen(file.c_str(), "rb");
    if (!f)
        return box;
    std::string text;
    char chunk[4096];
    size_t n;
    while ((n = fread(chunk, 1, sizeof(chunk), f)) > 0)
        text.append(chunk, n);
    fclose(f);
    json j = json::parse(text, nullptr, false);
    if (!j.is_array())
        return box;
    for (const json &l : j)
        box.push_back({l.value("from", ""), l.value("time", ""), l.value("text", ""),
                       l.value("shown", false), l.value("seen", false)});
    return box;
}

/*! Keeps the letters in `file`, the last MAILBOX_KEEPS of them; false when it cannot. */
inline bool write_mailbox(const std::string &file, const std::vector<letter_t> &box) {
    json j = json::array();
    size_t first = box.size() > MAILBOX_KEEPS ? box.size() - MAILBOX_KEEPS : 0;
    for (size_t i = first; i < box.size(); i++)
        j.push_back({{"from", box[i].from}, {"time", box[i].time}, {"text", box[i].text},
                     {"shown", box[i].shown}, {"seen", box[i].seen}});
    std::string text = j.dump(2, ' ', false, json::error_handler_t::replace);
    FILE *f = fopen(file.c_str(), "wb");
    if (!f)
        return false;
    bool ok = fwrite(text.data(), 1, text.size(), f) == text.size();
    return fclose(f) == 0 && ok;
}

/*! Returns the time now, as a letter carries it. */
inline std::string mail_time() {
    time_t now = time(NULL);
    char stamp[32];
    strftime(stamp, sizeof(stamp), "%Y-%m-%d %H:%M", localtime(&now));
    return stamp;
}

inline std::string letter_line(const letter_t &l) {
    return l.time + "  from " + l.from + ":\n" + l.text + "\n";
}

/*! Returns the whole mailbox as text, oldest first, the letters not listed before marked new;
 * marks them all shown. */
inline std::string mailbox_text(std::vector<letter_t> &box) {
    if (box.empty())
        return "no mail";
    std::string out;
    for (letter_t &l : box) {
        out += (l.shown ? "" : "(new) ") + letter_line(l) + "\n";
        l.shown = true;
    }
    out.pop_back();
    return out;
}

/*! Returns the letters the computer's Claude has not been given, as text, and marks them seen;
 * "" when there are none. */
inline std::string unseen_mail(std::vector<letter_t> &box) {
    std::string out;
    for (letter_t &l : box)
        if (!l.seen) {
            out += letter_line(l);
            l.seen = true;
        }
    return out;
}
