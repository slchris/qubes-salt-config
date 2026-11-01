{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Run the KasmVNC server inside the GUI domain (runs IN the GUI domain).

The GUI domain's real X display is :0, owned by lightdm. KasmVNC cannot attach
to an existing display, so it runs its own Xvnc on :1 and kasmxproxy copies :0
onto :1. The web client connects to KasmVNC's HTTPS server on 127.0.0.1:8444;
sys-vncweb carries that stream over qubes.ConnectTCP (mgmt.gui-vnc.web-*).

Everything that must survive an AppVM restart lives in /rw/config/kasmvnc:
the KasmVNC config, the helper scripts, the TLS certificate, the web password
database and the RFB password. The volatile /root/.vnc is reduced to symlinks
plus logs/pid. The systemd units are installed by apply-units.sh, which
/rw/config/rc.local calls on every boot (mgmt.gui-vnc.create writes that call);
the units themselves are gated on the qube service marker `kasmvnc`, enabled
by mgmt.gui-vnc.create.

Adaptive resize is done by resize-watch.sh: KasmVNC's client resizes :1, the
watcher selects a matching CRTC mode on :0's DUMMY0 (not a bare `xrandr --fb`),
then restarts kasmxproxy when the framebuffer size changed. A bare `--fb` leaves
DUMMY0 with no geometry, so qubes.SetMonitorLayout is sent empty and the guest
screen collapses to 64x64 (pointer misses every window). We deliberately do not
use `kasmxproxy -r`; it segfaults on this Xorg when the display is resized.

Deploy (from dom0), after mgmt.gui-vnc.install and mgmt.gui-vnc.create:
  sudo qubesctl --skip-dom0 --targets=sys-gui-vnc state.apply mgmt.gui-vnc.kasm

KasmVNC's web credentials are in /rw/config/kasmvnc/credentials.txt when this
state generated them; an existing pre-persistence password database is migrated
and never replaced.
#}

{%- from 'config.jinja' import cfg with context -%}
{%- set gv = cfg.get('gui_vnc', {}) -%}
{%- set qube = gv.get('qube', 'sys-gui-vnc') -%}
{%- set web = gv.get('web', {}) -%}
{%- set kasm_port = web.get('kasm_port', 8444) -%}
{%- set ext_port = web.get('ext_port', 6080) -%}
{%- set dir = '/rw/config/kasmvnc' -%}
{%- set files = 'salt://mgmt/gui-vnc/files/kasm' -%}

{% if grains['nodename'] != 'dom0' %}
{% if gv.get('enabled', False) %}

"gui-vnc-kasm-dir":
  file.directory:
    - name: {{ dir }}
    - user: root
    - group: root
    - mode: '0700'
    - makedirs: True

"gui-vnc-kasm-config":
  file.managed:
    - name: {{ dir }}/kasmvnc.yaml
    - source: {{ files }}/kasmvnc.yaml
    - template: jinja
    - user: root
    - group: root
    - mode: '0600'
    - context:
        port: {{ kasm_port }}
        cert: {{ dir }}/kasm.pem
        key: {{ dir }}/kasm.key
    - require:
      - file: "gui-vnc-kasm-dir"

"gui-vnc-kasm-xstartup":
  file.managed:
    - name: {{ dir }}/xstartup
    - source: {{ files }}/xstartup
    - user: root
    - group: root
    - mode: '0755'
    - require:
      - file: "gui-vnc-kasm-dir"

"gui-vnc-kasm-bootstrap-script":
  file.managed:
    - name: {{ dir }}/bootstrap.sh
    - source: {{ files }}/bootstrap.sh
    - template: jinja
    - user: root
    - group: root
    - mode: '0755'
    - context:
        port: {{ kasm_port }}
        ext_port: {{ ext_port }}
    - require:
      - file: "gui-vnc-kasm-dir"

"gui-vnc-kasm-merge-auth":
  file.managed:
    - name: {{ dir }}/merge-auth.sh
    - source: {{ files }}/merge-auth.sh
    - user: root
    - group: root
    - mode: '0755'
    - require:
      - file: "gui-vnc-kasm-dir"

"gui-vnc-kasm-start-vnc":
  file.managed:
    - name: {{ dir }}/start-vnc.sh
    - source: {{ files }}/start-vnc.sh
    - user: root
    - group: root
    - mode: '0755'
    - require:
      - file: "gui-vnc-kasm-dir"

"gui-vnc-kasm-resize-watch":
  file.managed:
    - name: {{ dir }}/resize-watch.sh
    - source: {{ files }}/resize-watch.sh
    - user: root
    - group: root
    - mode: '0755'
    - require:
      - file: "gui-vnc-kasm-dir"

"gui-vnc-kasm-apply-units-script":
  file.managed:
    - name: {{ dir }}/apply-units.sh
    - source: {{ files }}/apply-units.sh
    - user: root
    - group: root
    - mode: '0755'
    - require:
      - file: "gui-vnc-kasm-dir"

"gui-vnc-kasm-gen-xorg":
  file.managed:
    - name: {{ dir }}/gen-xorg-conf.sh
    - source: {{ files }}/gen-xorg-conf.sh
    - user: root
    - group: root
    - mode: '0755'
    - require:
      - file: "gui-vnc-kasm-dir"

"gui-vnc-kasm-lightdm-dropin":
  file.managed:
    - name: {{ dir }}/lightdm-kasm-xorg.conf
    - source: {{ files }}/lightdm-kasm-xorg.conf
    - user: root
    - group: root
    - mode: '0644'
    - require:
      - file: "gui-vnc-kasm-dir"

"gui-vnc-kasm-unit-kasmvnc":
  file.managed:
    - name: {{ dir }}/qubes-kasmvnc.service
    - source: {{ files }}/qubes-kasmvnc.service
    - user: root
    - group: root
    - mode: '0644'
    - require:
      - file: "gui-vnc-kasm-dir"

"gui-vnc-kasm-unit-proxy":
  file.managed:
    - name: {{ dir }}/qubes-kasmxproxy.service
    - source: {{ files }}/qubes-kasmxproxy.service
    - user: root
    - group: root
    - mode: '0644'
    - require:
      - file: "gui-vnc-kasm-dir"

"gui-vnc-kasm-unit-resize":
  file.managed:
    - name: {{ dir }}/qubes-kasm-resize.service
    - source: {{ files }}/qubes-kasm-resize.service
    - user: root
    - group: root
    - mode: '0644'
    - require:
      - file: "gui-vnc-kasm-dir"

"gui-vnc-kasm-de-marker":
  file.touch:
    - name: {{ dir }}/.de-was-selected
    - require:
      - file: "gui-vnc-kasm-dir"

# Migrate the pre-persistence secrets (if any), generate the certificate and
# passwords on first run, and replace the volatile files with symlinks.
"gui-vnc-kasm-bootstrap":
  cmd.run:
    - name: {{ dir }}/bootstrap.sh
    - require:
      - file: "gui-vnc-kasm-config"
      - file: "gui-vnc-kasm-xstartup"
      - file: "gui-vnc-kasm-bootstrap-script"
      - file: "gui-vnc-kasm-de-marker"

# Install the units from /rw and start them now. The touch makes the runtime
# marker exist before mgmt.gui-vnc.create has enabled the `kasmvnc` service;
# create owns the persistent marker from the next boot on.
"gui-vnc-kasm-apply":
  cmd.run:
    - name: |
        install -d -m 0755 /var/run/qubes-service
        touch /var/run/qubes-service/kasmvnc
        {{ dir }}/apply-units.sh
    - require:
      - cmd: "gui-vnc-kasm-bootstrap"
      - file: "gui-vnc-kasm-apply-units-script"
      - file: "gui-vnc-kasm-gen-xorg"
      - file: "gui-vnc-kasm-lightdm-dropin"
      - file: "gui-vnc-kasm-unit-kasmvnc"
      - file: "gui-vnc-kasm-unit-proxy"
      - file: "gui-vnc-kasm-unit-resize"

{% else %}

"gui-vnc-kasm-disabled-note":
  test.show_notification:
    - text: |
        mgmt.gui-vnc.kasm: cfg.gui_vnc.enabled is False — skipping the KasmVNC
        runtime in {{ qube }}.

{% endif %}
{% endif %}
