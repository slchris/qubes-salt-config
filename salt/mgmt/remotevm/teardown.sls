{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Tear down RemoteVM setup: remove local policy and the RemoteVM qubes (dom0).

  sudo qubesctl state.apply mgmt.remotevm.teardown

Removing the policy instantly revokes local access to the RemoteVMs. The
transport service + ~/.ssh/config left in the relay qube are harmless without
the RemoteVMs; remove them by hand if desired. Set cfg.remotevm.keep_qubes:
True to remove policy but keep the RemoteVM definitions.

A RemoteVM has no running domain, so no shutdown is needed before removal.
#}

{%- from 'config.jinja' import cfg with context -%}
{%- set rv = cfg.remotevm -%}
{%- set targets = rv.get('targets', []) -%}
{%- set keep = rv.get('keep_qubes', False) -%}

{% if grains['nodename'] == 'dom0' %}

"remotevm-teardown-policy":
  file.absent:
    - name: /etc/qubes/policy.d/30-remotevm.policy

# The console's register channel goes with it. Removing the policy is what
# actually revokes access; the service file is removed too so a re-applied
# policy cannot silently re-enable a stale script.
"remotevm-teardown-register-policy":
  file.absent:
    - name: /etc/qubes/policy.d/30-qubesair-register.policy

"remotevm-teardown-register-service":
  file.absent:
    - name: /etc/qubes-rpc/qubesair.RegisterRemoteVM

{% if not keep %}
{% for t in targets %}
"remotevm-teardown-remove-{{ t.local_name }}":
  cmd.run:
    - name: qvm-remove -f -- {{ t.local_name }}
    - onlyif: qvm-check --quiet -- {{ t.local_name }}
{% endfor %}
{% endif %}

{% endif %}
