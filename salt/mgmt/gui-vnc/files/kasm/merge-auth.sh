#!/bin/sh
# SPDX-FileCopyrightText: 2026 Chris Su
# SPDX-License-Identifier: MIT
#
# Build the one Xauthority file kasmxproxy needs. It must contain the cookies
# for BOTH displays: lightdm's :0 cookie and the :1 cookie vncserver writes to
# /root/.Xauthority. Rebuilt on every start; never persisted.

set -u

A=/root/.Xauthority-kasm

# Wait until each display answers with its OWN authority. Merging before
# vncserver has finished writing /root/.Xauthority can copy a stale cookie and
# leave the merged file unable to reach :1 even though Xvnc is up.
wait_display() {
    disp="$1"
    auth="$2"
    i=0
    while [ "$i" -lt 120 ]; do
        if DISPLAY="$disp" XAUTHORITY="$auth" xrandr --current >/dev/null 2>&1; then
            return 0
        fi
        i=$((i + 1))
        sleep 1
    done
    return 1
}

wait_display :0 /run/lightdm/root/:0 || {
    echo "kasmvnc: :0 is not reachable" >&2
    exit 1
}
wait_display :1 /root/.Xauthority || {
    echo "kasmvnc: :1 is not reachable" >&2
    exit 1
}

umask 077
rm -f "$A"
: > "$A"
xauth -f "$A" merge /root/.Xauthority 2>/dev/null || true
xauth -f "$A" merge /run/lightdm/root/:0 2>/dev/null || true

if wait_display :0 "$A" && wait_display :1 "$A"; then
    exit 0
fi

echo "kasmvnc: merged authority does not reach both displays" >&2
exit 1
