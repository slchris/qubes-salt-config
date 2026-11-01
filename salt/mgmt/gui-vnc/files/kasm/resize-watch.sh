#!/bin/sh
# SPDX-FileCopyrightText: 2026 Chris Su
# SPDX-License-Identifier: MIT
#
# Adaptive resize without kasmxproxy -r. KasmVNC's web client changes the :1
# size via RandR; this watcher copies that size onto the real Qubes display :0,
# then restarts the proxy when the framebuffer size actually changed.
#
# The copy has to select a CRTC mode on DUMMY0. `xrandr --fb` alone changes
# "Screen current" and leaves the output as "DUMMY0 connected primary" with
# no WxH+X+Y, because the guivm xorg.conf has no modeline for an arbitrary
# browser size (HorizSync is only 49-50, so a stock cvt mode is rejected too).
# qubesadmin get_monitor_layout() skips an output that has no geometry, returns
# [], and qvm-start-gui still calls qubes.SetMonitorLayout with empty stdin.
# The guest agent then turns every DUMMY output off. The qube's RandR screen
# falls back to the dummy minimum, 64x64, so pointer coordinates never land on
# a window. The keyboard still reaches whichever window already has focus.
#
# The modeline clock matches the ones Qubes writes in the guivm xorg.conf:
# clock = 50 * (width + 3) / 1000, which keeps horizontal sync inside 49-50 kHz.

set -u

A=/root/.Xauthority-kasm

current_size() {
    DISPLAY="$1" XAUTHORITY="$A" xrandr --current 2>/dev/null \
        | sed -n 's/.*current \([0-9]\+\) x \([0-9]\+\).*/\1x\2/p' | head -1
}

# WxH of DUMMY0's current mode, or empty when that output has no CRTC.
output_mode() {
    DISPLAY=:0 XAUTHORITY="$A" xrandr --current 2>/dev/null \
        | sed -n 's/^DUMMY0 connected[^0-9]*\([0-9][0-9]*x[0-9][0-9]*\)+.*/\1/p' | head -1
}

apply_mode() {
    w=$1
    h=$2
    mode="QB${w}x${h}"
    if ! DISPLAY=:0 XAUTHORITY="$A" xrandr --current 2>/dev/null | grep -q "^ *${mode} "; then
        clock=$(( (500 * (w + 3)) / 10000 ))
        if [ "$clock" -lt 1 ]; then
            clock=1
        fi
        if ! DISPLAY=:0 XAUTHORITY="$A" xrandr --newmode "$mode" \
            "$clock" "$w" "$((w + 1))" "$((w + 2))" "$((w + 3))" \
            "$h" "$((h + 1))" "$((h + 2))" "$((h + 3))"; then
            echo "kasm-resize: newmode $mode failed" >&2
            return 1
        fi
    fi
    # addmode is a no-op once the mode is already on the output.
    DISPLAY=:0 XAUTHORITY="$A" xrandr --addmode DUMMY0 "$mode" || true
    if ! DISPLAY=:0 XAUTHORITY="$A" xrandr --output DUMMY0 --mode "$mode" --pos 0x0; then
        echo "kasm-resize: failed to set DUMMY0 to $mode" >&2
        return 1
    fi
}

# Let start-vnc.sh set the initial :1 geometry before this watcher can mistake
# VNC's 1024x768 default for a client-requested size.
sleep 3

failed=""
while :; do
    s1=$(current_size :1)
    s0=$(current_size :0)
    m0=$(output_mode)
    if [ -n "$s1" ] && [ "$s1" != "$failed" ] && { [ "$s1" != "$s0" ] || [ "$m0" != "$s1" ]; }; then
        w=${s1%x*}
        h=${s1#*x}
        echo "kasm-resize: :0 ${s0:-?} mode ${m0:-none} -> $s1"
        if apply_mode "$w" "$h"; then
            failed=""
            if [ "$s0" != "$s1" ]; then
                # Give Xorg a moment to finish the RandR change, then restart
                # the proxy so it captures the new framebuffer geometry.
                # Skip the restart when the size was already right and only the
                # CRTC mode was missing: the proxy is already copying this fb.
                sleep 1
                systemctl restart qubes-kasmxproxy.service 2>/dev/null || true
            fi
        else
            failed=$s1
        fi
    fi
    sleep 1
done
