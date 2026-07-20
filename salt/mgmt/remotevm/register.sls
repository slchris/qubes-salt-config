{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Install the console's channel for registering RemoteVMs (dom0).

The console provisions qubes with terraform; dom0 has no way to learn they
exist, because the console writes terraform, not qvm-prefs (config.jinja says as
much under `remotevm.targets`). This ships a SCOPED qrexec service the console
calls to register a provisioned qube as a RemoteVM addressing shell, and a
policy that lets ONLY the console qube call it.

Why a write channel into dom0 at all, and why it is narrow: the alternative is a
hand-maintained static list in cfg.remotevm.targets, which drifts the moment the
console creates or destroys a qube. The service can only run
`qvm-create --class RemoteVM` / `qvm-prefs` / `qvm-remove` against names matching
`remote-*` — it cannot name a system qube, a template, the relay, or dom0. That
is the same boundary the qubes.RemoteDebug whitelist draws, applied to one job.

  register / deregister / status  — see files/qubesair.RegisterRemoteVM

Removed by teardown.sls.

Deploy (from dom0):
  sudo qubesctl state.apply mgmt.remotevm.register
#}

{%- from 'config.jinja' import cfg with context -%}
{%- set rv = cfg.remotevm -%}
{%- set relay = rv.get('relay', 'mgmt-jump') -%}
{%- set transport = rv.get('transport_rpc', 'qubesair.SSHProxy') -%}
{%- set console = cfg.get('qubesair', {}).get('qube', 'qubesair-console') -%}
{#- Qubes allowed to call the register service. The console is the intended
    caller; a list lets an operator add a jump qube for manual registration or
    for verifying the channel on a machine where the console is not deployed. -#}
{%- set callers = rv.get('register_callers', [console]) -%}

{% if grains['nodename'] == 'dom0' %}

# The service. Rendered so the relay/transport defaults are baked in, and the
# common call from the console is just `register <local> <remote>`.
"remotevm-register-service":
  file.managed:
    - name: /etc/qubes-rpc/qubesair.RegisterRemoteVM
    - source: salt://mgmt/remotevm/files/qubesair.RegisterRemoteVM
    - template: jinja
    - context:
        relay: {{ relay }}
        transport: {{ transport }}
    - mode: '0755'
    - user: root
    - group: root

# Only the console qube may register RemoteVMs. @anyvm deny closes the door on
# every other qube — this creates addressing shells that route local calls off
# the machine, so it is not something a disposable that opened an attachment
# should be able to do.
"remotevm-register-policy":
  file.managed:
    - name: /etc/qubes/policy.d/30-qubesair-register.policy
    - mode: '0644'
    - user: root
    - group: root
    - contents: |
        # SPDX-License-Identifier: MIT — managed by mgmt.remotevm.register
        # Remove with: sudo qubesctl state.apply mgmt.remotevm.teardown
        {%- for caller in callers %}
        qubesair.RegisterRemoteVM * {{ caller }} dom0 allow
        {%- endfor %}
        qubesair.RegisterRemoteVM * @anyvm dom0 deny

{% else %}

"remotevm-register-note":
  test.show_notification:
    - text: |
        mgmt.remotevm.register targets dom0; run it without --skip-dom0.

{% endif %}
