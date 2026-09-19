{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Install the GUI-domain packages in the TEMPLATE (runs IN the template).

A GUI domain needs qubes-vm-guivm — the package that provides
qubes-guivm-session and the guivm-vnc service the sys-gui-vnc qube runs — plus
the qubes manager and a small amount of XFCE the base *-xfce template may not
have. The bulk of XFCE is already in the *-xfce template; the package list here
is deliberately short and split by OS because Qubes ships both Fedora and
Debian XFCE templates.

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
{% else %}
      - lightdm
      - xfdesktop4
      - xfce4-screenshooter
      - libxfce4ui-utils
      - greybird-gtk-theme
{% endif %}

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
