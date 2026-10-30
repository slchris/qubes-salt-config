#!/bin/sh
# SPDX-FileCopyrightText: 2026 Chris Su
# SPDX-License-Identifier: MIT
#
# Install the KasmVNC runtime units from persistent /rw and (re)start them.
# Called by mgmt.gui-vnc.kasm now, and from /rw/config/rc.local on every boot.

set -eu

D=/rw/config/kasmvnc

# rc.local runs before lightdm (lightdm.service has After=rc-local.service).
# Make the display-manager prerequisites ready here without relying on the
# retired guivm-vnc service:
#  * the qube service marker that lightdm.service is conditioned on,
#  * the dummyqbs Xorg config (lightdm's default X otherwise finds no screen),
#  * a writable qubes-update-gui log directory for the `user` account.
install -d -m 0755 /var/run/qubes-service
touch /var/run/qubes-service/lightdm

install -d -m 0775 -o root -g qubes /var/log/qubes
if [ ! -e /var/log/qubes/qui.updater.log ]; then
    install -m 0664 -o root -g qubes /dev/null /var/log/qubes/qui.updater.log
else
    chown root:qubes /var/log/qubes/qui.updater.log 2>/dev/null || true
    chmod 0664 /var/log/qubes/qui.updater.log 2>/dev/null || true
fi

install -D -m 0755 "$D/gen-xorg-conf.sh" /usr/local/libexec/qubes-kasm-xorg-conf
install -D -m 0644 "$D/lightdm-kasm-xorg.conf" /etc/systemd/system/lightdm.service.d/60-kasm-xorg.conf
if [ ! -e /etc/X11/xorg.conf ]; then
    /usr/local/libexec/qubes-kasm-xorg-conf
fi

for u in qubes-kasmvnc.service qubes-kasmxproxy.service qubes-kasm-resize.service; do
    install -m 0644 "$D/$u" "/etc/systemd/system/$u"
done

systemctl daemon-reload

# Retire the x11vnc path. Two servers capturing :0 waste resources and the old
# launcher keeps a second password file in the trust path.
systemctl disable --now guivm-vnc.service >/dev/null 2>&1 || true
rm -f /var/run/qubes-service/guivm-vnc
pkill -f '/usr/bin/x11vnc -display :0' >/dev/null 2>&1 || true

# Stop the pre-persistence ad-hoc processes once. The transient unit was
# started with systemd-run --unit=kasmxproxy before this state existed.
systemctl stop kasmxproxy.service >/dev/null 2>&1 || true
systemctl reset-failed kasmxproxy.service >/dev/null 2>&1 || true
/usr/bin/vncserver -kill :1 >/dev/null 2>&1 || true
pkill -f '/usr/bin/kasmxproxy' >/dev/null 2>&1 || true

if [ -e /var/run/qubes-service/kasmvnc ]; then
    systemctl enable qubes-kasmvnc.service qubes-kasmxproxy.service qubes-kasm-resize.service >/dev/null 2>&1
    # The proxy's first ExecStartPre can lose a race with vncserver writing its
    # cookie; Restart=always recovers. Do not fail the Salt apply on that
    # transient: wait for all three units instead.
    systemctl restart qubes-kasmvnc.service qubes-kasmxproxy.service qubes-kasm-resize.service || true
    i=0
    while [ "$i" -lt 90 ]; do
        if systemctl is-active --quiet qubes-kasmvnc.service &&
           systemctl is-active --quiet qubes-kasmxproxy.service &&
           systemctl is-active --quiet qubes-kasm-resize.service; then
            exit 0
        fi
        i=$((i + 1))
        sleep 1
    done
    echo "kasmvnc: units did not all become active" >&2
    exit 1
else
    systemctl disable qubes-kasmvnc.service qubes-kasmxproxy.service qubes-kasm-resize.service >/dev/null 2>&1 || true
fi
