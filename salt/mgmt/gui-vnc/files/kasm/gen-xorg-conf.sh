#!/bin/bash
# SPDX-FileCopyrightText: 2026 Chris Su
# SPDX-License-Identifier: MIT
#
# Render the dummyqbs Xorg config for the lightdm GUI domain.
#
# The stock Qubes GUI-domain path runs `qubes-run-x11vnc pre` from a lightdm
# ExecStartPre, and that only does anything when the guivm-vnc service is
# enabled. This module retires x11vnc, so we reuse Qubes' own pre-render
# function without starting it: source the script with a positional argument
# that matches no branch, then call guivm_vnc_pre.
#
# Without /etc/X11/xorg.conf, lightdm's default X server cannot load dummyqbs
# and dies with "no screens found" (a black browser session).

set -- noop
# guivm_vnc_pre uses MEM as an input; the Qubes agent normally exports it.
# Do not use `set -u`: the function also probes several optional qubesdb values.
MEM=0
. /usr/bin/qubes-run-x11vnc
guivm_vnc_pre
