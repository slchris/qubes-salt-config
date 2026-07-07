{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Tear down remote-debug: revoke dom0 access and remove the jump qube (dom0).

  sudo qubesctl state.apply mgmt.remote-debug.teardown

Removing the policy instantly revokes dom0 access even if the qube still runs.
Set pillar remote_debug:keep_qube: true to revoke access but keep the qube.
#}

{%- set rd = salt['pillar.get']('remote_debug', {}) -%}
{%- set qube = rd.get('qube', 'mgmt-jump') -%}
{%- set keep = rd.get('keep_qube', False) -%}

{% if grains['nodename'] == 'dom0' %}

"remote-debug-teardown-policy":
  file.absent:
    - name: /etc/qubes/policy.d/30-remote-debug.policy

"remote-debug-teardown-service":
  file.absent:
    - name: /etc/qubes-rpc/qubes.RemoteDebug

{% if not keep %}
"remote-debug-teardown-shutdown":
  cmd.run:
    - name: qvm-shutdown --wait {{ qube }}
    - onlyif: qvm-check {{ qube }}

"remote-debug-teardown-remove":
  cmd.run:
    - name: qvm-remove -f {{ qube }}
    - onlyif: qvm-check {{ qube }}
    - require:
      - cmd: remote-debug-teardown-shutdown
{% endif %}

{% endif %}
