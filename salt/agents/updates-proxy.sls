{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Send apt for the agent templates out through the build NetVM.

Templates have no netvm. Their apt uses qubes.UpdatesProxy, which otherwise
lands on the global updatevm (sys-firewall). This state redirects only the
templates named in cfg.agents.updates_proxy.templates — tpl-agent-build,
tpl-agents and tpl-ai — to cfg.agents.build.netvm.

The gateway must already exist, and its template must contain tinyproxy
(templates.project-net.install). A running gateway does not see a package
added to its template until it is restarted. The gateway's own firewall
allows output only via wg0, so once the proxy is in use a down tunnel
fail-closes these template builds.

Apply on dom0, after the gateway has been restarted with tinyproxy:

  sudo qubesctl state.apply agents.updates-proxy
#}

{% from 'config.jinja' import cfg with context %}
{% set netvm = cfg.agents.build.netvm %}
{% set templates = cfg.agents.updates_proxy.templates %}

{% if grains['nodename'] == 'dom0' %}

"agents-updates-proxy-netvm":
  cmd.run:
    - name: qvm-check {{ netvm }}

# qvm-service stores feature service.qubes-updates-proxy=1. The proxy process
# starts on demand inside the gateway; it is not a boot service of every
# project-net qube.
"agents-updates-proxy-service":
  cmd.run:
    - name: qvm-service {{ netvm }} qubes-updates-proxy on
    - require:
      - cmd: agents-updates-proxy-netvm

"agents-updates-proxy-policy":
  file.managed:
    - name: /etc/qubes/policy.d/30-agents-updates-proxy.policy
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        # SPDX-License-Identifier: MIT — managed by agents.updates-proxy
        # Apt for these templates exits through {{ netvm }}, not sys-firewall.
        # Other templates keep the global updatevm.
        {%- for name in templates %}
        qubes.UpdatesProxy * {{ name }} @default allow target={{ netvm }}
        {%- endfor %}
    - require:
      - cmd: agents-updates-proxy-service

{% endif %}
