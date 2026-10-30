{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Install the GUI-domain packages in the TEMPLATE (runs IN the template).

A GUI domain needs qubes-vm-guivm — the package that provides
qubes-guivm-session — plus the qubes manager and a small amount of XFCE the
base *-xfce template may not have. The bulk of XFCE is already in the *-xfce
template; the package list here is deliberately short and split by OS because
Qubes ships both Fedora and Debian XFCE templates.

KasmVNC (mgmt.gui-vnc.kasm) is the active remote server. This state installs
its pinned RPM into the template; the old guivm-vnc/x11vnc launcher is patched
below only as defense in depth in case that retired service is re-enabled.

lightdm is enabled with a Qubes drop-in so it only starts when the qube is
built with the `lightdm` service (mgmt.gui-vnc.create enables it) — the same
ConditionPathExists gate Qubes' own qvm.sys-gui-template uses. root is locked;
logins go through the `user` account.

Deploy (from dom0):
  sudo qubesctl --skip-dom0 --targets=<template> state.apply mgmt.gui-vnc.install
#}

{%- from 'config.jinja' import cfg with context -%}
{%- set gv = cfg.get('gui_vnc', {}) -%}
{%- set template = gv.get('template', 'fedora-43-xfce') -%}
{%- set kasm = gv.get('kasmvnc', {}) -%}
{%- set kasm_version = kasm.get('version', '1.5.0-1.fc43') -%}

{% if grains['nodename'] != 'dom0' %}
{% if gv.get('enabled', False) %}

"gui-vnc-template-update":
  pkg.uptodate:
    - refresh: True

"gui-vnc-template-packages":
  pkg.installed:
    - require:
      - pkg: "gui-vnc-template-update"
{% if grains['os'] == 'Fedora' %}
    - setopt: "install_weak_deps=False"
{% else %}
    - install_recommends: False
{% endif %}
    - skip_suggestions: True
    - pkgs:
      # The one package that makes this a GUI domain.
      - qubes-vm-guivm
      # NOTE: Qubes Update GUI shells out to qubes-vm-update, but that CLI is
      # a dom0-only package (qubes-vmupdate) and is not in the VM repos:
      # QubesOS/qubes-issues#8934, and the GUI-domain docs list "Cannot update
      # dom0 from sys-gui". Do not add it here — the template repo has no such
      # package and the whole pkg.installed state fails. The opt-in
      # mgmt.gui-vnc.updater-bridge forwards the CLI call to dom0 instead.
      - qubes-manager
      - qubes-desktop-linux-manager
      - xfce4-session
      - xfce4-settings
      - xfce4-terminal
      - xfwm4
      - xfconf
{% if grains['os'] == 'Fedora' %}
      - lightdm-gtk
      - xfdesktop
      - xfce4-about
      - xfce4-screenshooter-plugin
      # xauth merges the :0 and :1 cookies for kasmxproxy; openssl makes the
      # self-signed KasmVNC certificate; curl fetches the pinned RPM.
      - xorg-x11-xauth
      - openssl
      - curl
{% else %}
      - lightdm
      - xfdesktop4
      - xfce4-screenshooter
      - libxfce4ui-utils
      - greybird-gtk-theme
      - xauth
      - openssl
      - curl
{% endif %}

{% if gv.get('updater_bridge', False) %}

# Qubes Update GUI runs the dom0-only `qubes-vm-update` CLI. mgmt.gui-vnc.
# updater-bridge installs the dom0 side (qubes.UpdateGui + policy); this
# wrapper is the GUI-domain side the app finds on PATH. It forwards argv to the
# dom0 service and demultiplexes the service's stderr marker back onto stderr,
# so the app's progress parser still sees the CLI's `vm updating N` lines.
"gui-vnc-template-updater-bridge":
  file.managed:
    - name: /usr/local/bin/qubes-vm-update
    - user: root
    - group: root
    - mode: '0755'
    - require:
      - pkg: "gui-vnc-template-packages"
    - contents: |
        #!/usr/bin/python3
        # SPDX-License-Identifier: MIT
        # Managed by mgmt.gui-vnc.install. Forwards to dom0's qubes.UpdateGui.
        import os
        import signal
        import subprocess
        import sys

        STDERR_MARK = b"\x01QSC-STDERR\x01"
        EXIT_MARK = b"\x01QSC-EXIT\x01"
        HELPER = "/usr/bin/qrexec-client-vm"


        def write_all(fd, data):
            while data:
                written = os.write(fd, data)
                data = data[written:]


        def main():
            args = sys.argv[1:]
            try:
                proc = subprocess.Popen(
                    [HELPER, "dom0", "qubes.UpdateGui"],
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                )
            except OSError as err:
                sys.stderr.write("qubes-vm-update: cannot start %s: %s\n"
                                 % (HELPER, err))
                return 127

            payload = b"".join(os.fsencode(arg) + b"\n" for arg in args)
            try:
                proc.stdin.write(payload)
                proc.stdin.close()
            except BrokenPipeError:
                pass

            def forward(signum, _frame):
                try:
                    proc.send_signal(signum)
                except ProcessLookupError:
                    pass

            for sig in (signal.SIGINT, signal.SIGTERM):
                signal.signal(sig, forward)

            exit_code = None
            while True:
                line = proc.stdout.readline()
                if not line:
                    break
                if line.startswith(EXIT_MARK):
                    try:
                        exit_code = int(line[len(EXIT_MARK):].strip())
                    except ValueError:
                        pass
                elif line.startswith(STDERR_MARK):
                    try:
                        write_all(2, line[len(STDERR_MARK):])
                    except BrokenPipeError:
                        break
                else:
                    try:
                        write_all(1, line)
                    except BrokenPipeError:
                        break

            rc = proc.wait()
            return exit_code if exit_code is not None else rc


        if __name__ == "__main__":
            sys.exit(main())

{% else %}

"gui-vnc-template-updater-bridge-absent":
  file.absent:
    - name: /usr/local/bin/qubes-vm-update

{% endif %}

# The retired guivm-vnc path. mgmt.gui-vnc.kasm disables that service and runs
# KasmVNC instead; this patch remains so a re-enabled service still requires
# auth, shared mode, and loopback binding. The password file is never created
# by Salt; x11vnc fails closed if it is missing.
"gui-vnc-template-x11vnc-options":
  file.replace:
    - name: /usr/bin/qubes-run-x11vnc
    - pattern: '^\s*OPTIONS_VNC=.*$'
    - repl: '    OPTIONS_VNC="-display :0 -auth /var/run/lightdm/root/:0 -forever -shared -localhost -xrandr -rfbauth /rw/config/gui-vnc/passwd"'
    - flags:
      - MULTILINE
    - require:
      - pkg: "gui-vnc-template-packages"

"gui-vnc-template-x11vnc-options-verify":
  cmd.run:
    - name: |
        grep -q -- '-shared' /usr/bin/qubes-run-x11vnc
        grep -q -- '-localhost' /usr/bin/qubes-run-x11vnc
        grep -q -- '-xrandr' /usr/bin/qubes-run-x11vnc
        grep -q -- '-rfbauth /rw/config/gui-vnc/passwd' /usr/bin/qubes-run-x11vnc
    - require:
      - file: "gui-vnc-template-x11vnc-options"

{% if grains['os'] == 'Fedora' %}

# KasmVNC is not in the Fedora repos. Fetch the exact upstream RPM, verify the
# pinned digest, then let dnf resolve its Fedora dependencies. The GUI domain
# itself is offline; this runs in its template, which has an update proxy.
"gui-vnc-template-kasmvnc":
  cmd.run:
    - name: |
        set -eu
        TMP="$(mktemp -d)"
        trap 'rm -rf "$TMP"' EXIT
        curl -fsSL -o "$TMP/kasmvncserver.rpm" {{ kasm['url'] | yaml_encode }}
        echo "{{ kasm['sha256'] }}  $TMP/kasmvncserver.rpm" | sha256sum -c -
        installed="$(rpm -q --qf '%{VERSION}-%{RELEASE}' kasmvncserver 2>/dev/null || true)"
        if [ "$installed" = "{{ kasm_version }}" ]; then
            exit 0
        fi
        if [ -n "$installed" ]; then
            dnf -y downgrade "$TMP/kasmvncserver.rpm" || dnf -y install "$TMP/kasmvncserver.rpm"
        else
            dnf -y install "$TMP/kasmvncserver.rpm"
        fi
    - unless: rpm -q --qf '%{VERSION}-%{RELEASE}' kasmvncserver 2>/dev/null | grep -qx '{{ kasm_version }}'
    - require:
      - pkg: "gui-vnc-template-packages"

# KasmVNC's software H.264 encoder is libx264 inside the system libavcodec.
# Fedora's ffmpeg-free has the same soname but no libx264, and an unknown
# video codec makes the canvas black instead of falling back. RPM Fusion's
# ffmpeg 7.1.x replaces that stack in place. This is the shared Fedora XFCE
# template (sys-net and sys-gui-vnc both use it); the transaction removes only
# the -free ffmpeg libraries and installs ffmpeg-libs, x264-libs and x265-libs.
"gui-vnc-template-ffmpeg-x264":
  cmd.run:
    - name: |
        set -eu
        if ! rpm -q rpmfusion-free-release >/dev/null 2>&1; then
            dnf install -y --setopt=install_weak_deps=False \
                "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm"
        fi
        dnf config-manager setopt rpmfusion-free.enabled=1 rpmfusion-free-updates.enabled=1
        dnf swap -y ffmpeg-free ffmpeg --allowerasing --setopt=install_weak_deps=False
    - unless: ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libx264
    - require:
      - cmd: "gui-vnc-template-kasmvnc"

{% endif %}

# qubes-update-gui runs as the GUI-domain `user`, but /var/log/qubes is
# root:root 0755 in the stock template, so the updater dies before it can draw
# its window (PermissionError: /var/log/qubes/qui.updater.log). `user` is
# already in the `qubes` group; make the directory and log group-writable.
"gui-vnc-template-qui-log":
  file.managed:
    - name: /etc/tmpfiles.d/qubes-update-gui.conf
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        # SPDX-License-Identifier: MIT
        # Managed by mgmt.gui-vnc.install.
        d /var/log/qubes 0775 root qubes -
        f /var/log/qubes/qui.updater.log 0664 root qubes -

"gui-vnc-template-qui-log-apply":
  cmd.run:
    - name: systemd-tmpfiles --create /etc/tmpfiles.d/qubes-update-gui.conf
    - require:
      - file: "gui-vnc-template-qui-log"

# Start lightdm only when the qube carries the lightdm service, so the template
# itself never launches a display manager and the GUI domain decides when to.
"gui-vnc-template-lightdm-dropin":
  file.managed:
    - name: /etc/systemd/system/lightdm.service.d/qubes.conf
    - makedirs: True
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        [Unit]
        ConditionPathExists=/var/run/qubes-service/lightdm
        [Install]
        WantedBy=multi-user.target
    - require:
      - pkg: "gui-vnc-template-packages"

# Salt's service.enabled calls `systemctl is-enabled`, which reports lightdm as
# already enabled (the unit carries Alias=display-manager.service), so it skips
# the enable and the multi-user wants symlink is never created — the unit then
# does not start at boot and the GUI domain serves no VNC. Enable it explicitly,
# guarded on the symlink that actually matters.
"gui-vnc-template-lightdm-reload":
  cmd.run:
    - name: systemctl daemon-reload
    - require:
      - file: "gui-vnc-template-lightdm-dropin"

"gui-vnc-template-lightdm-enabled":
  cmd.run:
    - name: systemctl enable lightdm
    - unless: test -e /etc/systemd/system/multi-user.target.wants/lightdm.service
    - require:
      - cmd: "gui-vnc-template-lightdm-reload"

# A GUI domain must not be logged into as root; the VNC/lightdm login is `user`.
"gui-vnc-template-lock-root":
  user.present:
    - name: root
    - password: '!!'

{% else %}

"gui-vnc-install-disabled-note":
  test.show_notification:
    - text: |
        mgmt.gui-vnc.install: cfg.gui_vnc.enabled is False — skipping GUI-domain
        packages in {{ template }}.

{% endif %}
{% endif %}
