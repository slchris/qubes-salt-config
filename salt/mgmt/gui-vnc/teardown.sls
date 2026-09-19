{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Tear down the GUI domain and the browser front end (runs IN dom0).

Order is deliberate: the global GUI domain is pointed back at dom0 FIRST (a
dangling default_guivm would leave every qube unable to render), then the
policies are revoked, then the qubes are removed. Set
cfg.gui_vnc.keep_qubes = True to keep the qubes and only revoke access.

Note: qubes whose guivm was set to the GUI domain individually keep that setting;
repoint them with `qvm-prefs <qube> guivm dom0` before removing the qube.

Deploy (from dom0):
  sudo qubesctl state.apply mgmt.gui-vnc.teardown
#}

{%- from 'config.jinja' import cfg with context -%}
{%- set gv = cfg.get('gui_vnc', {}) -%}
{%- set web = gv.get('web', {}) -%}
{%- set qube = gv.get('qube', 'sys-gui-vnc') -%}
{%- set web_qube = web.get('qube', 'sys-vncweb') -%}
{%- set web_tpl = web.get('template', 'tpl-gui-vnc-web') -%}

{% if grains['nodename'] == 'dom0' %}

# 1. Point the global GUI domain back at dom0 if it was ours.
"gui-vnc-teardown-default-guivm":
  cmd.run:
    - name: |
        if [ "$(qubes-prefs default_guivm)" = "{{ qube }}" ]; then
          qubes-prefs default_guivm dom0
        fi

# 2. Revoke the qrexec policy. Removing the GUI domain policy file is what
#    stops the GUI domain from compositing; the ConnectTCP file closes the
#    browser front end's only hole.
"gui-vnc-teardown-policy":
  file.absent:
    - names:
      - /etc/qubes/policy.d/50-gui-{{ qube }}.policy
      - /etc/qubes/policy.d/50-gui-vnc-web.policy
    - require:
      - cmd: "gui-vnc-teardown-default-guivm"

"gui-vnc-teardown-admin-local":
  cmd.run:
    - name: |
        f=/etc/qubes/policy.d/include/admin-local-rwx
        [ -f "$f" ] && sed -i "/# >>> mgmt.gui-vnc {{ qube }} >>>/,/# <<< mgmt.gui-vnc {{ qube }} <<</d" "$f" || true
    - require:
      - cmd: "gui-vnc-teardown-default-guivm"

{% if gv.get('admin_global_permissions', 'rwx') == 'rwx' %}
"gui-vnc-teardown-admin-global":
  cmd.run:
    - name: |
        f=/etc/qubes/policy.d/include/admin-global-rwx
        [ -f "$f" ] && sed -i "/# >>> mgmt.gui-vnc {{ qube }} >>>/,/# <<< mgmt.gui-vnc {{ qube }} <<</d" "$f" || true
    - require:
      - cmd: "gui-vnc-teardown-default-guivm"
{% elif gv.get('admin_global_permissions', 'rwx') == 'ro' %}
"gui-vnc-teardown-admin-global":
  cmd.run:
    - name: |
        f=/etc/qubes/policy.d/include/admin-global-ro
        [ -f "$f" ] && sed -i "/# >>> mgmt.gui-vnc {{ qube }} >>>/,/# <<< mgmt.gui-vnc {{ qube }} <<</d" "$f" || true
    - require:
      - cmd: "gui-vnc-teardown-default-guivm"
{% endif %}

{% if not gv.get('keep_qubes', False) %}

"gui-vnc-teardown-remove-web":
  cmd.run:
    - name: |
        if qvm-check {{ web_qube }} 2>/dev/null; then
          qvm-shutdown --wait {{ web_qube }} 2>/dev/null || true
          qvm-remove -f {{ web_qube }}
        fi
        if qvm-check {{ web_tpl }} 2>/dev/null; then
          qvm-shutdown --wait {{ web_tpl }} 2>/dev/null || true
          qvm-remove -f {{ web_tpl }}
        fi
        true
    - require:
      - cmd: "gui-vnc-teardown-policy"

"gui-vnc-teardown-remove-gui":
  cmd.run:
    - name: |
        if qvm-check {{ qube }} 2>/dev/null; then
          qvm-shutdown --wait {{ qube }} 2>/dev/null || true
          qvm-remove -f {{ qube }}
        fi
        true
    - require:
      - cmd: "gui-vnc-teardown-remove-web"

{% else %}

"gui-vnc-teardown-keep-note":
  test.show_notification:
    - text: |
        mgmt.gui-vnc.teardown: keep_qubes is True — policies revoked, {{ qube }}
        and {{ web_qube }} left in place.

{% endif %}

{% endif %}
