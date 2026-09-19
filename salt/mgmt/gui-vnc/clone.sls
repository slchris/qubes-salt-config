{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Install the XFCE template the GUI domain is built from (runs IN dom0).

Qubes' GUI-domain session is XFCE, and it needs qubes-vm-guivm (the
qubes-guivm-session / guivm-vnc plumbing) present in the template. Qubes ships
ready-made *-xfce templates in qubes-templates-itl, so this installs one from
that repo with qvm.template_installed — the same mechanism salt/fedora/clone.sls
uses — rather than cloning a minimal template and building the desktop by hand.
mgmt.gui-vnc.install then adds qubes-vm-guivm and the remaining bits.

Deploy (from dom0):
  sudo qubesctl state.apply mgmt.gui-vnc.clone
#}

{%- from 'config.jinja' import cfg with context -%}
{%- set gv = cfg.get('gui_vnc', {}) -%}
{%- set template = gv.get('template', 'fedora-43-xfce') -%}
{%- set repo = gv.get('template_repo', 'qubes-templates-itl') -%}

{% if grains['nodename'] == 'dom0' %}
{% if gv.get('enabled', False) %}

"gui-vnc-template-installed":
  qvm.template_installed:
    - name: {{ template }}
    - fromrepo: {{ repo }}

{% else %}

"gui-vnc-clone-disabled-note":
  test.show_notification:
    - text: |
        mgmt.gui-vnc.clone: cfg.gui_vnc.enabled is False — not installing
        {{ template }}.

{% endif %}
{% endif %}
