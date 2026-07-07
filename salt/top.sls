# SPDX-FileCopyrightText: 2026 Chris Su
# SPDX-License-Identifier: MIT
#
# Salt top file
# Enable specific tops with: sudo qubesctl top.enable <module>

base:
  'dom0':
    - match: nodegroup
