{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Common update state - always run before installing packages
#}

{% if grains['nodename'] != 'dom0' %}

"utils-update-packages":
  pkg.uptodate:
    - refresh: True

{% endif %}
