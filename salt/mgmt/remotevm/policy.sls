{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Install local qrexec policy for RemoteVM service calls (dom0).

Writes one policy file allowing the configured local sources to call the
configured services on each RemoteVM target. dom0's policy engine sees the
destination is a RemoteVM and routes the call through its relayvm using
transport_rpc (set by create.sls) — no relay name appears in these rules.

The REMOTE side (Remote-QubesOS) enforces its OWN policy for the incoming call
and must register the local source qube as a RemoteVM; that is configured on
the remote host, not here.

Removed by teardown.sls.

Deploy (from dom0):
  sudo qubesctl state.apply mgmt.remotevm.policy
#}

{%- from 'config.jinja' import cfg with context -%}
{%- set rv = cfg.remotevm -%}
{%- set targets = rv.get('targets', []) -%}
{%- set sources = rv.get('allowed_sources', ['@anyvm']) -%}
{%- set services = rv.get('services', []) -%}

{% if grains['nodename'] == 'dom0' %}

"remotevm-policy":
  file.managed:
    - name: /etc/qubes/policy.d/30-remotevm.policy
    - mode: '0644'
    - user: root
    - group: root
    - contents: |
        # SPDX-License-Identifier: MIT
        # Managed by mgmt.remotevm.policy. Remove with:
        #   sudo qubesctl state.apply mgmt.remotevm.teardown
        # Allow configured local sources to call services on each RemoteVM;
        # dom0 routes to the RemoteVM's relayvm via its transport_rpc.
        {%- for svc in services %}
        {%- set action = svc.get('action', 'ask') %}
        {%- for t in targets %}
        {%- for src in sources %}
        {{ svc.name }} * {{ src }} {{ t.local_name }} {{ action }}
        {%- endfor %}
        {%- endfor %}
        # Deny anything else to this RemoteVM by default.
        {%- for t in targets %}
        {{ svc.name }} * @anyvm {{ t.local_name }} deny
        {%- endfor %}
        {%- endfor %}

{% endif %}
