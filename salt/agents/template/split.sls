{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Install the Split GPG 2 client packages in tpl-agents.

agents.template.install upgrades the whole template. This state installs
only the split client. Apt leaves through sys-bwg-net (agents.updates-proxy).
Shut the template down afterwards so an AppVM restart picks the packages up.

  sudo qubesctl --skip-dom0 --targets=tpl-agents state.apply agents.template.split
#}

{% if grains['nodename'] != 'dom0' %}

"tpl-agents-split-packages":
  pkg.installed:
    - refresh: True
    - pkgs:
      - socat
      - split-gpg2
      - zenity

{% endif %}
