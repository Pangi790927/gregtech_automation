#!/usr/bin/env bash
# server-request 001 - survey: what the relay must fit around.
#
# Reads:   the OS release and architecture, the internet section of the server's
#          OpenComputers.cfg, and the listening TCP ports.
# Changes: nothing. No sudo, no files written, no network traffic.
# Undo:    nothing to undo.
#
# Why: the console's relay (console/DESIGN.md) is a C++ program that runs here. It is built on the
# PC, in WSL, and linked statically, so this only has to be x86-64 Linux. The OpenComputers config
# says whether the Internet Card may reach the PC or 127.0.0.1 (both are blocked by default),
# and the listening ports show which one is free for the relay.
#
# The Minecraft server lives in ~/servers/gtnh/, its world in ~/servers/gtnh/World (user,
# 2026-09-30).

set -u

section() { printf '\n=== %s\n' "$1"; }

section "system"
uname -srm
grep -h '^PRETTY_NAME=' /etc/os-release 2>/dev/null

section "OpenComputers internet settings (comments left out)"
cfg=~/servers/gtnh/config/OpenComputers.cfg
ls -l "$cfg"
# Prints the internet block, from its opening line to the brace at the same indent.
awk '
    !on && /^[[:space:]]*internet[[:space:]]*\{/ {
        on = 1; match($0, /^[[:space:]]*/); ind = RLENGTH
    }
    on && $0 !~ /^[[:space:]]*#/ && NF { print }
    on && /^[[:space:]]*\}/ { match($0, /^[[:space:]]*/); if (RLENGTH == ind) exit }
' "$cfg"

section "listening TCP ports"
ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null
