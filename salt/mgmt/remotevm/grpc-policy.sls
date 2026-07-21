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

        # The relay pulls the endpoint map (qube -> ip:port) from the console and
        # writes it into its own QubesDB, so the console is not in the per-call
        # path. Only names and addresses cross this — no credentials.
        qubesair.RemoteEndpoints * {{ relay }} {{ console }} allow
        qubesair.RemoteEndpoints * @anyvm @anyvm deny
        {%- set exec_action = csr.get('exec_action', 'ask') %}
        # A: a caller may reach ANY RemoteVM — @tag:remote-zone is set on every one
        # by qubesair.RegisterRemoteVM, so a newly provisioned qube is covered
        # without editing this file. That triggers dom0's transport rewrite.
        # Ping/Status are read-only -> allow. Exec runs a command on the remote, so
        # it defaults to `ask` (dom0 confirms each call); set
        # remotevm.grpc.csr.exec_action=allow to skip the prompt for trusted callers.
        {%- for c in callers %}
        qubesair.Ping     * {{ c }} @tag:remote-zone allow
        qubesair.Status   * {{ c }} @tag:remote-zone allow
        qubesair.Exec     * {{ c }} @tag:remote-zone {{ exec_action }}
        qubesair.FileCopy * {{ c }} @tag:remote-zone {{ csr.get('filecopy_action', exec_action) }}
        {%- endfor %}
        # Seamless desktop (docs §0.14): enumerate a RemoteVM's apps for the start
        # menu, and launch one so its window forwards (under the remote's Xpra).
        # GetAppmenus is read-only; StartApp runs a program, so it inherits the same
        # gate as Exec. dom0/@adminvm is allowed too, because qvm-sync-appmenus runs
        # there.
        {%- for c in callers %}
        qubes.GetAppmenus * {{ c }} @tag:remote-zone allow
        qubes.StartApp    * {{ c }} @tag:remote-zone {{ exec_action }}
        {%- endfor %}
        qubes.GetAppmenus * @adminvm @tag:remote-zone allow
        qubes.StartApp    * @adminvm @tag:remote-zone allow
        # Any other service to a RemoteVM is denied by default.
        * * @anyvm @tag:remote-zone deny

        # C (GUI / streaming): a raw TCP tunnel is opened DIRECTLY on the relay
        # (the RemoteVM rewrite only carries buffered RPC via GrpcProxy). The relay
        # handler restricts the destination to a known RemoteVM's GUI ports.
        {%- for c in callers %}
        qubesair.ConnectTCP * {{ c }} {{ relay }} allow
        {%- endfor %}
        qubesair.ConnectTCP * @anyvm @anyvm deny
        # B: the rewritten transport call lands on the relay's gRPC handler.
        # ([C1]) If R4.3 sources the rewritten call from something other than the
        # original caller, widen the source here — see grpc-transport-design.md.
        {%- for c in callers %}
        qubesair.GrpcProxy * {{ c }} {{ relay }} allow
        {%- endfor %}
        # dom0's qvm-sync-appmenus reaches a RemoteVM through the same rewrite.
        qubesair.GrpcProxy * @adminvm {{ relay }} allow
        qubesair.GrpcProxy * @anyvm @anyvm deny

{% endif %}
{% endif %}
