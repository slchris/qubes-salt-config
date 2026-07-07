{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Install packages in Fedora (full) template
This is minimal - the full template already has most things
#}

{% if grains['nodename'] != 'dom0' %}

include:
  - dotfiles.init

"{{ slsdotpath }}-update-packages":
  pkg.uptodate:
    - refresh: True

{% endif %}
