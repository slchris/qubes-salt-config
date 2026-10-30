#!/bin/sh
# SPDX-FileCopyrightText: 2026 Chris Su
# SPDX-License-Identifier: MIT
#
# Prepare the persistent KasmVNC runtime. Called by qubes-kasmvnc.service (via
# start-vnc.sh) on every start, and directly by mgmt.gui-vnc.kasm.

set -eu

D=/rw/config/kasmvnc

install -d -m 0700 -o root -g root "$D"

# One-time migration from the pre-persistence layout. The live files lived in
# the AppVM's volatile /root; copy the secrets into /rw before replacing them
# with symlinks. Never overwrite an existing persistent copy.
for f in kasm.pem kasm.key passwd; do
    if [ ! -e "$D/$f" ] && [ -e "/root/.vnc/$f" ] && [ ! -L "/root/.vnc/$f" ]; then
        cp -a "/root/.vnc/$f" "$D/$f"
    fi
done
if [ ! -e "$D/kasmpasswd" ] && [ -e /root/.kasmpasswd ] && [ ! -L /root/.kasmpasswd ]; then
    cp -a /root/.kasmpasswd "$D/kasmpasswd"
fi

# Self-signed TLS certificate, generated once and kept in persistent storage.
if [ ! -s "$D/kasm.pem" ] || [ ! -s "$D/kasm.key" ]; then
    openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
        -subj "/CN=$(hostname)" \
        -keyout "$D/kasm.key" -out "$D/kasm.pem"
fi
chmod 0600 "$D/kasm.key"
chmod 0644 "$D/kasm.pem"

# KasmVNC web credentials. The file is KasmVNC's own password database; the
# password is random only on first boot, then persisted. The credentials note
# is written once and never regenerated, so an operator can find the login.
if [ ! -s "$D/kasmpasswd" ]; then
    pw=$(openssl rand -base64 24)
    printf '%s\n%s\n' "$pw" "$pw" | kasmvncpasswd -u kasmgui -w "$D/kasmpasswd"
    {
        printf 'URL=https://<qubes-host>:{{ ext_port }}/\n'
        printf 'LOCAL=https://127.0.0.1:{{ port }}/\n'
        printf 'USER=kasmgui\n'
        printf 'PASSWORD=%s\n' "$pw"
    } > "$D/credentials.txt"
    chmod 0600 "$D/credentials.txt"
fi

# The RFB password is not used by the web client, but Xvnc is started with
# -rfbauth. Keep one in persistent storage as well.
if [ ! -s "$D/passwd" ]; then
    pw=$(openssl rand -base64 12)
    printf '%s\n%s\n' "$pw" "$pw" | vncpasswd -f > "$D/passwd"
fi
# A migrated file keeps the old runtime's mode (it was 0644); enforce 0600 on
# both password databases regardless of how they arrived.
chmod 0600 "$D/passwd" "$D/kasmpasswd"

# KasmVNC prompts for a desktop environment when this marker is missing, even
# with a custom xstartup. The mirror display has no desktop of its own.
[ -e "$D/.de-was-selected" ] || : > "$D/.de-was-selected"
chmod 0600 "$D/.de-was-selected"

# Point the paths vncserver/kasmxproxy expect at the persistent copies. The
# volatile ~/.vnc keeps only logs and the pid file.
install -d -m 0700 -o root -g root /root/.vnc
for f in kasmvnc.yaml xstartup .de-was-selected kasm.pem kasm.key passwd; do
    ln -sfn "$D/$f" "/root/.vnc/$f"
done
ln -sfn "$D/kasmpasswd" /root/.kasmpasswd
