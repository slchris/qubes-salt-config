{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Install the dom0 qrexec policy for the path-b gRPC transport (see
qubes-air/docs/grpc-transport-design.md §0.5). Runs in dom0.

Writes /etc/qubes/policy.d/25-qubes-air-grpc.policy, which sorts BEFORE the
SSHProxy policy (30-*) so these allows win over its deny fallbacks. Three groups:
  - IssueRelayCert: only the relay qube may ask the console to sign its CSR.
  - A: a caller may reach each RemoteVM, which triggers dom0's transport rewrite.
  - B: the rewritten qubesair.GrpcProxy call may land on the relay.

Remove the file (or mgmt.remotevm.teardown) to revert.

Deploy (from dom0):
  sudo qubesctl state.apply mgmt.remotevm.grpc-policy
#}

{%- from 'config.jinja' import cfg with context -%}
{%- set rv = cfg.remotevm -%}
{%- set csr = rv.get('grpc', {}).get('csr', {}) -%}
{%- set console = csr.get('console_qube', 'qubesair-console') -%}
{%- set relay = rv.get('relay', 'mgmt-jump') -%}
{%- set targets = rv.get('targets', []) -%}
{%- set callers = csr.get('allowed_callers', [relay]) -%}

{% if grains['nodename'] == 'dom0' %}
{% if csr.get('enabled', False) %}

"grpc-csr-policy":
  file.managed:
    - name: /etc/qubes/policy.d/25-qubes-air-grpc.policy
    - mode: '0644'
    - user: root
    - group: root
    - contents: |
        # SPDX-License-Identifier: MIT
        # Managed by mgmt.remotevm.grpc-policy. Remove to revert.
        # Sorts before 30-*.policy so these allows win over the SSHProxy denies.

        # The relay may ask the console to sign its client CSR. The console pins
        # the certificate CN to the caller ({{ relay }}), so this cannot mint
        # another qube's identity even though the service is reachable.
        qubesair.IssueRelayCert * {{ relay }} {{ console }} allow
        qubesair.IssueRelayCert * @anyvm @anyvm deny
        {% for t in targets %}
        # A: a caller may reach RemoteVM {{ t.local_name }} (triggers the rewrite).
        {%- for c in callers %}
        qubesair.Ping   * {{ c }} {{ t.local_name }} allow
        qubesair.Status * {{ c }} {{ t.local_name }} allow
        {%- endfor %}
        {% endfor %}
        # B: the rewritten transport call lands on the relay's gRPC handler.
        # ([C1]) If R4.3 sources the rewritten call from something other than the
        # original caller, widen the source here — see grpc-transport-design.md.
        {%- for c in callers %}
        qubesair.GrpcProxy * {{ c }} {{ relay }} allow
        {%- endfor %}
        qubesair.GrpcProxy * @anyvm @anyvm deny

{% endif %}
{% endif %}
