#!/bin/sh
# SPDX-FileCopyrightText: 2026 Chris Su
# SPDX-License-Identifier: MIT
#
# gui-vnc-healthcheck — runs in dom0 on a timer.
#
# The GUI domain can wedge: a kasmxproxy segfault (or a hung lightdm/X0
# session) leaves the whole qube's qrexec agent unresponsive, so every qube's
# windows silently stop rendering and qvm-shutdown cannot stop it. That state
# went unnoticed for days on the reference machine. This probe catches it.
#
# Probe: `qvm-run --no-gui sys-gui-vnc true` with a hard timeout. A healthy
# GUI domain answers immediately; a wedged one hangs until the timeout.
#
# On cfg.gui_vnc.healthcheck.fail_threshold consecutive failures it:
#   1. qvm-kill  the GUI domain  (qvm-shutdown hangs on a wedged qube),
#   2. qvm-start it and wait for qrexec to answer,
#   3. restart the running AppVMs that use it as their GUI domain, so their
#      qubes-gui reconnects to the new GUI session (otherwise they stay bound
#      to the dead one and keep showing no windows).
#
# Exit status: 0 when healthy or after a successful recovery, non-zero when a
# recovery attempt failed (systemd records it; the timer fires again later).

set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

# --- config injected by Salt (see healthcheck.sls) -------------------------
GUIQUBE="{{ qube }}"
TIMEOUT="{{ probe_timeout }}"
THRESHOLD="{{ fail_threshold }}"
STATE="{{ state_dir }}"
LOG_TAG=gui-vnc-healthcheck
# --------------------------------------------------------------------------

mkdir -p "$STATE"
COUNT_FILE="$STATE/fail_count"
DOWN_FILE="$STATE/down_since"

log() { logger -t "$LOG_TAG" "$*" 2>/dev/null; printf '%s %s\n' "$(date -Is)" "$*" >> "$STATE/health.log" 2>/dev/null || true; }

qrexec_ok() {
    # `timeout` wraps the CLI; qvm-run itself has no per-call timeout. A wedged
    # qube makes qvm-run block, so we bound it here.
    timeout "$TIMEOUT" qvm-run --no-gui --pass-io -- "$GUIQUBE" true >/dev/null 2>&1
}

inc_fail() {
    n=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)
    n=$((n + 1))
    echo "$n" > "$COUNT_FILE"
    printf '%s\n' "$n"
}

reset_fail() {
    rm -f "$COUNT_FILE" "$DOWN_FILE" 2>/dev/null || true
}

recover() {
    log "GUI domain $GUIQUBE unresponsive ($1 consecutive fails) — recovering"
    date -Is > "$DOWN_FILE" 2>/dev/null || true

    # qvm-shutdown hangs on a wedged qube; qvm-kill is the only reliable stop.
    qvm-kill "$GUIQUBE" >/dev/null 2>&1 || true
    # Give the domain a moment to actually go down before starting it again.
    i=0
    while [ "$i" -lt 20 ]; do
        qvm-check --running --quiet "$GUIQUBE" >/dev/null 2>&1 || break
        i=$((i + 1)); sleep 1
    done

    qvm-start "$GUIQUBE" >/dev/null 2>&1 || true

    # Wait up to ~90s for qrexec to come back.
    i=0
    while [ "$i" -lt 45 ]; do
        if qrexec_ok; then
            log "GUI domain $GUIQUBE answered after restart"
            # Restart running AppVMs (with this GUI domain) so their gui-agent
            # reconnects. Skip the GUI domain itself and dom0.
            for q in $(qvm-ls --raw-list 2>/dev/null); do
                [ "$q" = "$GUIQUBE" ] && continue
                # only AppVMs currently running; qvm-ls state via qvm-check
                qvm-check --running --quiet "$q" >/dev/null 2>&1 || continue
                kl=$(qvm-prefs "$q" klass 2>/dev/null)
                [ "$kl" = "AppVM" ] || continue
                # only qubes whose guivm is the GUI domain (or inherits it)
                gv=$(qvm-prefs "$q" guivm 2>/dev/null)
                if [ "$gv" = "$GUIQUBE" ] || [ -z "$gv" ] || [ "$gv" = "dom0" ]; then
                    log "restarting $q to reconnect its GUI"
                    qvm-shutdown --wait "$q" >/dev/null 2>&1 || qvm-kill "$q" >/dev/null 2>&1 || true
                    qvm-start "$q" >/dev/null 2>&1 || true
                fi
            done
            reset_fail
            return 0
        fi
        i=$((i + 1)); sleep 2
    done

    log "GUI domain $GUIQUBE did NOT answer after restart — manual attention needed"
    return 1
}

# --- main -----------------------------------------------------------------
if qrexec_ok; then
    reset_fail
    exit 0
fi

n=$(inc_fail)
log "probe failed ($n/$THRESHOLD)"
if [ "$n" -ge "$THRESHOLD" ]; then
    recover "$n" || exit 1
fi
exit 0
