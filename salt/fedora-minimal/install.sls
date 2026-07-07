{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Install packages in fedora-minimal template
Note: This runs via dvm-fedora (from management_dispvm setting)
#}

{% if grains['nodename'] != 'dom0' %}

include:
  - dotfiles.init

"{{ slsdotpath }}-update-packages":
  pkg.uptodate:
    - refresh: True

{% endif %}
