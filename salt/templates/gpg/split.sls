{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Add Split GPG 2 and the Split SSH server to tpl-gpg.

This does not run pkg.uptodate. templates.gpg.install upgrades every package;
use this state to add only the split stack. Apt still has to leave through
the VPN updates proxy (tpl-gpg is listed in cfg.agents.updates_proxy.templates).
Start sys-bwg-net first, then shut it down again when apt is finished.

  sudo qubesctl --skip-dom0 --targets=tpl-gpg state.apply templates.gpg.split
#}

{% if grains['nodename'] != 'dom0' %}

include:
  - templates.gpg.pcscd

"gpg-split-packages":
  pkg.installed:
    - refresh: True
    - pkgs:
      - socat
      - split-gpg2
      - zenity
      # GnuPG talks to pcscd through this. It is not pulled in by gnupg.
      - scdaemon
      # Without this, qvm-usb attach fails with "qubes-usb-proxy not installed".
      # The CanoKey for slchris is attached to this qube. The YubiKey is not.
      - qubes-usb-proxy

# /etc in an AppVM is discarded on restart, so the RPC service has to live
# in the template. qubes.Gpg2 comes from the split-gpg2 package.
"gpg-split-ssh-agent-rpc":
  file.managed:
    - name: /etc/qubes-rpc/qubes.SshAgent
    - source: salt://templates/gpg/files/qubes.SshAgent
    - user: root
    - group: root
    - mode: '0755'
    - require:
      - pkg: gpg-split-packages

{% endif %}
