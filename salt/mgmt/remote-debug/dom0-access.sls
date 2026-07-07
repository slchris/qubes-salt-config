{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Install the dom0-access channel for the remote-debug jump qube (dom0).

Two modes, chosen by pillar remote_debug:dom0_access:
  "whitelist" (default, safer) — installs the qubes.RemoteDebug qrexec service
      (an allow-list wrapper) plus a policy permitting ONLY the jump qube to
      call it. A compromise of the jump qube cannot run arbitrary dom0 commands.
  "shell" — installs a qubes.VMShell policy allowing the jump qube to run ANY
      dom0 command. Convenient, but hands dom0 to the jump qube if it is
      compromised. Use only on a throwaway dev machine.

Both are single files under /etc/qubes/policy.d and are removed by teardown.sls.
#}

{%- set rd = salt['pillar.get']('remote_debug', {}) -%}
{%- set qube = rd.get('qube', 'mgmt-jump') -%}
{%- set mode = rd.get('dom0_access', 'whitelist') -%}

{% if grains['nodename'] == 'dom0' %}

{% if mode == 'shell' %}

# --- SHELL MODE: arbitrary dom0 commands from the jump qube ---
"remote-debug-policy-shell":
  file.managed:
    - name: /etc/qubes/policy.d/30-remote-debug.policy
    - mode: '0644'
    - user: root
    - group: root
    - contents: |
        # SPDX-License-Identifier: MIT
        # remote-debug (SHELL mode): {{ qube }} may run ANY dom0 command.
        # Remove with: sudo qubesctl state.apply mgmt.remote-debug.teardown
        qubes.VMShell * {{ qube }} dom0 allow

# Ensure the whitelist policy/service are not also present.
"remote-debug-policy-whitelist-absent":
  file.absent:
    - name: /etc/qubes/policy.d/30-remote-debug.policy.whitelist

{% else %}

# --- WHITELIST MODE (default): only qubes.RemoteDebug, allow-listed commands ---
"remote-debug-service":
  file.managed:
    - name: /etc/qubes-rpc/qubes.RemoteDebug
    - source: salt://mgmt/remote-debug/files/qubes.RemoteDebug
    - mode: '0755'
    - user: root
    - group: root

"remote-debug-policy-whitelist":
  file.managed:
    - name: /etc/qubes/policy.d/30-remote-debug.policy
    - mode: '0644'
    - user: root
    - group: root
    - contents: |
        # SPDX-License-Identifier: MIT
        # remote-debug (WHITELIST mode): {{ qube }} may call the allow-listed
        # qubes.RemoteDebug service only. Remove with the teardown state.
        qubes.RemoteDebug * {{ qube }} dom0 allow
        qubes.RemoteDebug * @anyvm dom0 deny

{% endif %}

{% endif %}
