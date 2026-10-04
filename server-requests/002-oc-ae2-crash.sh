#!/usr/bin/env bash
# server-request 002 - the crash when OpenComputers reads an AE2 network's items.
#
# Reads:   the names of the server's crash reports, and the start of each one that mentions
#          OpenComputers, AE2 or running out of memory; the lines of the server logs that do;
#          and the OpenComputers settings that bear on reading items (item NBT, call budgets).
# Changes: nothing. No sudo, no files written, no network traffic.
# Undo:    nothing to undo.
#
# Why: the user's client or server crashes when a computer reads an ME interface's items
# (getItemsInNetwork / allItems). OpenComputers 1.8.0.13-GTNH runs both on the server's own
# thread and turns every item type in the network into a table, and the item converters can add
# each item's NBT. Which of those crashes the server is in its crash reports, not on the PC.
#
# The Minecraft server lives in ~/servers/gtnh/ (user, 2026-09-30).

set -u
cd ~/servers/gtnh || exit 1
pattern='li\.cil\.oc|appeng|NetworkControl|getItemsInNetwork|allItems|OutOfMemory|None\.get|Ticking'

section() { printf '\n=== %s\n' "$1"; }

section "crash reports, newest first"
ls -lt crash-reports 2>/dev/null | head -25

section "crash reports that mention OpenComputers, AE2 or memory (first 70 lines of each)"
for f in $(ls -t crash-reports/*.txt 2>/dev/null | head -40); do
    if grep -Eq "$pattern" "$f"; then
        printf '\n----- %s\n' "$f"
        head -70 "$f"
        printf '  ... lines that match:\n'
        grep -En "$pattern" "$f" | head -25
    fi
done

section "server logs: matching lines with 2 lines of context (newest logs, at most 120 lines)"
for f in logs/latest.log $(ls -t logs/*.log.gz 2>/dev/null | head -15); do
    case "$f" in *.gz) cat=zcat ;; *) cat=cat ;; esac
    hits=$($cat "$f" 2>/dev/null | grep -Ec "$pattern")
    if [ "${hits:-0}" -gt 0 ]; then
        printf '\n----- %s (%s lines match)\n' "$f" "$hits"
        $cat "$f" | grep -En -B2 -A2 "$pattern" | head -120
    fi
done

section "OpenComputers settings that bear on reading items"
grep -nE 'allowItemStackNBTTags|callBudgets|maxNetworkPacketSize|timeout|threads' \
    config/OpenComputers.cfg 2>/dev/null | head -20
