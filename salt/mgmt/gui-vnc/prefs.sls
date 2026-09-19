{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Point the machine at the GUI domain (runs IN dom0) — optional and deliberately
NOT part of create.

`qubes-prefs default_guivm <qube>` sends every qube's windows to the GUI domain
instead of dom0. That is what makes the browser session a full desktop, and it
is also why this is a separate, opt-in step: it REQUIRES shutting down every
running qube first (Qubes cannot move a live qube between GUI domains), and once
it is set the physical screen no longer shows qube windows. Individual qubes can
instead opt in per-qube with `qvm-prefs <qube> guivm <qube>`.

Set cfg.gui_vnc.default_guivm = True to enable.

Deploy (from dom0):
  sudo qubesctl state.apply mgmt.gui-vnc.prefs
#}

{%- from 'config.jinja' import cfg with context -%}
{%- set gv = cfg.get('gui_vnc', {}) -%}
{%- set qube = gv.get('qube', 'sys-gui-vnc') -%}

{% if grains['nodename'] == 'dom0' %}
{% if gv.get('enabled', False) %}

{% if gv.get('default_guivm', False) %}

"gui-vnc-default-guivm":
  cmd.run:
    - name: qubes-prefs default_guivm {{ qube }}
    - onlyif: test "$(qubes-prefs default_guivm)" != "{{ qube }}"

{% else %}

"gui-vnc-default-guivm-note":
  test.show_notification:
    - text: |
        mgmt.gui-vnc.prefs: cfg.gui_vnc.default_guivm is False — {{ qube }} was
        NOT made the global GUI domain, so the browser session shows only qubes
        that point at it individually. To send every qube's windows there, set
        gui_vnc.default_guivm = True and re-apply (shut down all qubes first);
        or per qube: qvm-prefs <qube> guivm {{ qube }}.

{% endif %}
{% endif %}
{% endif %}
