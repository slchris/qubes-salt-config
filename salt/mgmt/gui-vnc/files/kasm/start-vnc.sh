#!/bin/sh
# SPDX-FileCopyrightText: 2026 Chris Su
# SPDX-License-Identifier: MIT
#
# Start KasmVNC's Xvnc on :1 at the same size as the real :0 display.

set -eu

D=/rw/config/kasmvnc
"$D/bootstrap.sh"

# Wait for :0 and record its size. Starting :1 at VNC's default 1024x768 would
# make the resize watcher shrink the real :0 display on its first poll.
s=""
i=0
while [ "$i" -lt 120 ]; do
    s=$(DISPLAY=:0 XAUTHORITY=/run/lightdm/root/:0 xrandr --current 2>/dev/null \
        | sed -n 's/.*current \([0-9]\+\) x \([0-9]\+\).*/\1x\2/p' | head -1)
    [ -n "$s" ] && break
    i=$((i + 1))
    sleep 1
done
if [ -z "$s" ]; then
    echo "kasmvnc: :0 is not ready" >&2
    exit 1
fi

# A stale Xvnc from a previous start would keep the :1 socket; kill it first.
/usr/bin/vncserver -kill :1 >/dev/null 2>&1 || true

# KasmVNC's vncserver wrapper falls back to 1024x768 for non-standard
# geometries (verified on 1.5.0), so start it and then set :1 to the real :0
# size with RandR. The web client's own resize requests still arrive later via
# AcceptSetDesktopSize.
/usr/bin/vncserver :1 -fg &
vnc_pid=$!

i=0
while [ "$i" -lt 120 ]; do
    if DISPLAY=:1 XAUTHORITY=/root/.Xauthority xrandr --current >/dev/null 2>&1; then
        break
    fi
    i=$((i + 1))
    sleep 1
done
if [ "$i" -ge 120 ]; then
    echo "kasmvnc: :1 did not become reachable" >&2
    kill "$vnc_pid" 2>/dev/null || true
    exit 1
fi

w=${s%x*}
h=${s#*x}
if ! DISPLAY=:1 XAUTHORITY=/root/.Xauthority xrandr --fb "${w}x${h}" >/dev/null 2>&1; then
    echo "kasmvnc: could not set :1 to $s" >&2
    kill "$vnc_pid" 2>/dev/null || true
    exit 1
fi
echo "kasmvnc: :1 started at $s"

wait "$vnc_pid"
