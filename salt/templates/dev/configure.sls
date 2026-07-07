{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT
#}

{% if grains['nodename'] != 'dom0' %}

include:
  - dotfiles.git
  - dotfiles.shell

{% endif %}
