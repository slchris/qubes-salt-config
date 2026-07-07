{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Set management preferences and cleanup.
Run after mgmt.install has completed on tpl-mgmt.

Note: Uses cmd.run instead of qvm.vm to avoid state merging conflicts
with create.sls (which also defines qvm.vm for the same qubes).
#}

"{{ slsdotpath }}-set-qubes-prefs-management_dispvm-to-dvm-{{ slsdotpath }}":
  cmd.run:
    - name: qubes-prefs -- management_dispvm dvm-{{ slsdotpath }}

"{{ slsdotpath }}-set-tpl-{{ slsdotpath }}-management_dispvm-to-default":
  cmd.run:
    - require:
      - cmd: "{{ slsdotpath }}-set-qubes-prefs-management_dispvm-to-dvm-{{ slsdotpath }}"
    - name: qvm-prefs --default -- tpl-{{ slsdotpath }} management_dispvm

"{{ slsdotpath }}-remove-default-mgmt-dvm":
  qvm.absent:
    - require:
      - cmd: "{{ slsdotpath }}-set-qubes-prefs-management_dispvm-to-dvm-{{ slsdotpath }}"
      - cmd: "{{ slsdotpath }}-set-tpl-{{ slsdotpath }}-management_dispvm-to-default"
    - name: default-mgmt-dvm