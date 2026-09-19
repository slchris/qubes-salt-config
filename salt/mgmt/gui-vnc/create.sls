{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Create the GUI domain (runs IN dom0).

This is the Qubes-supported remote-desktop primitive: a dedicated AppVM acting
as the GUI domain, running lightdm plus a VNC server on localhost:5900 (the
guivm-vnc service). Nothing is exposed by this state — the VNC socket only
accepts connections from inside the qube; a separate front-end qube reaches it
over the qubes.ConnectTCP qrexec service.

It builds the same three things Qubes' own qvm.sys-gui-vnc formula does, but
from config.jinja instead of pillar:

  1. the qube, with netvm/audiovm empty, guivm dom0, autostart, and the
     lightdm + guivm + guivm-vnc services enabled;
  2. the GUI-domain RPC policy (adapted from qvm/template-gui.jinja
     gui_common()) that lets the GUI domain composite @tag:guivm-<qube>;
  3. the lightdm credential, by copying the dom0 user's shadow hash into the
     qube (see cfg.gui_vnc.sync_dom0_password). Qubes' formula does exactly
     this; the hash sits in a 0600 file inside a qube that has no network.

Deploy (from dom0):
  sudo qubesctl state.apply mgmt.gui-vnc.create
#}

{%- from 'config.jinja' import cfg with context -%}
{%- from "qvm/template.jinja" import load -%}
{%- set gv = cfg.get('gui_vnc', {}) -%}
{%- set template = gv.get('template', 'fedora-43-xfce') -%}
{%- set qube = gv.get('qube', 'sys-gui-vnc') -%}
{%- set label = gv.get('label', 'black') -%}
{%- set memory = gv.get('memory', 2000) -%}
{%- set maxmem = gv.get('maxmem', 4000) -%}
{%- set vcpus = gv.get('vcpus', 2) -%}
{%- set admin_gp = gv.get('admin_global_permissions', 'rwx') -%}

{% if grains['nodename'] == 'dom0' %}
{% if gv.get('enabled', False) %}

# The `create` state's require below is an SLS requisite, so the clone state
# must actually be in this run (Salt does not auto-include it) — same pattern as
# debian-minimal/create.sls.
include:
  - mgmt.gui-vnc.clone

{% load_yaml as defaults -%}
name: {{ qube }}
force: True
require:
- sls: mgmt.gui-vnc.clone
present:
- label: {{ label }}
- template: {{ template }}
- maxmem: {{ maxmem }}
prefs:
- label: {{ label }}
- template: {{ template }}
- netvm: ""
- guivm: dom0
- audiovm: ""
- memory: {{ memory }}
- maxmem: {{ maxmem }}
- vcpus: {{ vcpus }}
- autostart: {{ gv.get('autostart', True) }}
service:
- enable:
  - lightdm
  - guivm
  - guivm-vnc
{%- endload %}
{{ load(defaults) }}

# --- GUI-domain RPC policy --------------------------------------------------
# Adapted verbatim from Qubes' qvm/template-gui.jinja gui_common(): these
# services let the GUI domain receive window/clipboard/appmenu traffic for the
# qubes tagged guivm-<qube>, and read the Admin API bits a GUI session needs.
# The tag itself is maintained by Qubes when a qube's guivm is set to <qube>.
"gui-vnc-rpc-policy":
  file.managed:
    - name: /etc/qubes/policy.d/50-gui-{{ qube }}.policy
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        # SPDX-License-Identifier: MIT
        # Managed by mgmt.gui-vnc.create — GUI domain policy for {{ qube }}.
        policy.EvalGUI  +qubes.ClipboardPaste   {{ qube }}  dom0  allow
        qubes.GetImageRGBA                  *   {{ qube }}  @tag:guivm-{{ qube }}  allow
        qubes.GetAppmenus                   *   {{ qube }}  @tag:guivm-{{ qube }}  allow
        qubes.ClipboardCopy                 +   {{ qube }}  @tag:guivm-{{ qube }}  allow
        qubes.ClipboardPaste                +   {{ qube }}  @tag:guivm-{{ qube }}  allow
        qubes.GetAppmenus                   *   {{ qube }}  @type:TemplateVM      allow
        qubes.SetMonitorLayout              *   {{ qube }}  @tag:guivm-{{ qube }}  allow
        qubes.StartApp                      *   {{ qube }}  @tag:guivm-{{ qube }}  allow
        qubes.StartApp                      *   {{ qube }}  @dispvm:@tag:guivm-{{ qube }}  allow
        qubes.SyncAppMenus                  *   @tag:guivm-{{ qube }}  dom0  allow target={{ qube }}
        qubes.WindowIconUpdater             *   @tag:guivm-{{ qube }}  dom0  allow target={{ qube }}
        qubes.Notifications                 *   @tag:guivm-{{ qube }}  @default  allow target={{ qube }} autostart=no
        qubes.WaitForSession                *   {{ qube }}  @tag:guivm-{{ qube }}  allow

        # Admin API subset a GUI session needs (matches the Qubes default grant).
        admin.vm.List                       *   {{ qube }}  dom0                      allow
        admin.vm.List                       *   {{ qube }}  @tag:guivm-{{ qube }}    allow target=dom0
        admin.Events                        *   {{ qube }}  dom0                      allow
        admin.Events                        *   {{ qube }}  @tag:guivm-{{ qube }}    allow target=dom0
        admin.label.Get                     *   {{ qube }}  dom0                      allow
        admin.label.Index                   *   {{ qube }}  dom0                      allow
        admin.vm.feature.Set                +keyboard-layout   {{ qube }}  {{ qube }}  allow target=dom0
        admin.vm.property.Get               *   {{ qube }}  dom0                      allow
        admin.vm.volume.List                *   {{ qube }}  dom0                      allow
        admin.vm.device.pci.Available       *   {{ qube }}  dom0                      allow
        admin.vm.device.mic.Available       *   {{ qube }}  dom0                      allow
        admin.vm.feature.Get                +internal {{ qube }}  dom0                allow
        admin.vm.feature.Get                +servicevm {{ qube }}  dom0               allow
        admin.vm.CurrentState               *   {{ qube }}  dom0                      allow

# The Admin API includes are shared files; marker-merge our grant so re-applies
# never duplicate it (file.append, as Qubes' formula uses, would).
"gui-vnc-admin-local-rwx":
  file.blockreplace:
    - name: /etc/qubes/policy.d/include/admin-local-rwx
    - marker_start: "# >>> mgmt.gui-vnc {{ qube }} >>>"
    - marker_end: "# <<< mgmt.gui-vnc {{ qube }} <<<"
    - append_if_not_found: True
    - show_changes: True
    - content: |
        {{ qube }} @tag:guivm-{{ qube }} allow target=dom0
        {{ qube }} {{ qube }} allow target=dom0

{% if admin_gp == 'rwx' %}
"gui-vnc-admin-global-rwx":
  file.blockreplace:
    - name: /etc/qubes/policy.d/include/admin-global-rwx
    - marker_start: "# >>> mgmt.gui-vnc {{ qube }} >>>"
    - marker_end: "# <<< mgmt.gui-vnc {{ qube }} <<<"
    - append_if_not_found: True
    - show_changes: True
    - content: |
        {{ qube }} @adminvm allow target=dom0
        {{ qube }} @tag:guivm-{{ qube }} allow target=dom0
        {{ qube }} {{ qube }} allow target=dom0
{% elif admin_gp == 'ro' %}
"gui-vnc-admin-global-ro":
  file.blockreplace:
    - name: /etc/qubes/policy.d/include/admin-global-ro
    - marker_start: "# >>> mgmt.gui-vnc {{ qube }} >>>"
    - marker_end: "# <<< mgmt.gui-vnc {{ qube }} <<<"
    - append_if_not_found: True
    - show_changes: True
    - content: |
        {{ qube }} @adminvm allow target=dom0
        {{ qube }} @tag:guivm-{{ qube }} allow target=dom0
        {{ qube }} {{ qube }} allow target=dom0
{% endif %}

# --- lightdm credential -----------------------------------------------------
# The GUI domain's lightdm authenticates the `user` account against the qube's
# own shadow file. The qube starts with no password, so we copy dom0's hash for
# its first `qubes`-group user, exactly as qvm.sys-gui-vnc-vm does via pillar.
{% if gv.get('sync_dom0_password', True) %}

{%- set members = salt['cmd.run']("getent group qubes | awk -F: '{print $4}'", python_shell=True).strip() -%}
{%- set dom0_user = members.split(',')[0] if members else '' -%}

{% if not dom0_user %}
"gui-vnc-password-no-user":
  test.fail_without_changes:
    - name: |
        cfg.gui_vnc.sync_dom0_password is True but the 'qubes' group has no
        members, so there is no dom0 user password to copy into {{ qube }}.
        Add your dom0 user to the 'qubes' group, or set
        cfg.gui_vnc.sync_dom0_password = False and set the guivm user's password
        by hand.
    - failhard: True
{% else %}

{%- set shadow = salt['cmd.run']("getent shadow " ~ dom0_user, python_shell=True).strip() -%}
{%- set pw_hash = shadow.split(':')[1] if shadow else '' -%}

{% if not pw_hash or not pw_hash.startswith('$') %}
"gui-vnc-password-no-hash":
  test.fail_without_changes:
    - name: |
        Could not read a usable password hash for dom0 user '{{ dom0_user }}'
        (got: '{{ pw_hash }}'). Refusing to push this into {{ qube }} where it
        could clobber the account. Set cfg.gui_vnc.sync_dom0_password = False
        and set the guivm user's password by hand, or give that dom0 user a
        password first.
    - failhard: True
{% else %}

# Staged under /run (tmpfs) and removed, so the hash is on disk in dom0 for the
# shortest possible window; show_changes: False keeps it out of state output.
"gui-vnc-password-stage":
  file.managed:
    - name: /run/gui-vnc-pw-hash
    - contents: {{ pw_hash | yaml_encode }}
    - user: root
    - group: root
    - mode: '0600'
    - show_changes: False

"gui-vnc-rc-stage":
  file.managed:
    - name: /run/gui-vnc-rc
    - user: root
    - group: root
    - mode: '0600'
    - show_changes: False
    - contents: |
        #!/bin/sh
        # Managed by mgmt.gui-vnc.create — do not edit.
        if [ -s /rw/config/gui-vnc/password-hash ]; then
            usermod -p "$(cat /rw/config/gui-vnc/password-hash)" user
        fi

# qvm-run starts the qube if needed, so this also brings the GUI domain up once.
"gui-vnc-password-write":
  cmd.run:
    - name: |
        cat /run/gui-vnc-pw-hash | qvm-run --pass-io -u root -- {{ qube }} \
          'umask 077; mkdir -p /rw/config/gui-vnc; cat > /rw/config/gui-vnc/password-hash; chmod 0600 /rw/config/gui-vnc/password-hash'
    - require:
      - qvm: {{ qube }}
      - file: "gui-vnc-password-stage"

"gui-vnc-rc-write":
  cmd.run:
    - name: |
        cat /run/gui-vnc-rc | qvm-run --pass-io -u root -- {{ qube }} \
          'cat > /rw/config/rc.local && chmod 0755 /rw/config/rc.local'
    - require:
      - qvm: {{ qube }}
      - file: "gui-vnc-rc-stage"
      - cmd: "gui-vnc-password-write"

# Apply it now as well, so the first VNC login works without a reboot.
"gui-vnc-password-apply":
  cmd.run:
    - name: qvm-run --pass-io -u root -- {{ qube }} '/rw/config/rc.local'
    - require:
      - cmd: "gui-vnc-rc-write"

"gui-vnc-stage-remove":
  file.absent:
    - names:
      - /run/gui-vnc-pw-hash
      - /run/gui-vnc-rc
    - require:
      - cmd: "gui-vnc-password-apply"

{% endif %}
{% endif %}
{% endif %}

{% else %}

"gui-vnc-create-disabled-note":
  test.show_notification:
    - text: |
        mgmt.gui-vnc.create: cfg.gui_vnc.enabled is False — not creating
        {{ qube }}.

{% endif %}
{% endif %}
