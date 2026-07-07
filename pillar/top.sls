# SPDX-FileCopyrightText: 2026 Chris Su
# SPDX-License-Identifier: MIT
#
# Pillar top file
# Files deployed to /srv/pillar/slchris/
# Minion config sets this as the ONLY pillar_root

base:
  '*':
    - user
