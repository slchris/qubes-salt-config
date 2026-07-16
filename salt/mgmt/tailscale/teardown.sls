{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Tear down the sys-tailscale gateway (runs IN dom0).

Logs the node out of the tailnet (best-effort, so the Headscale entry can be
expired/removed), then removes the qube unless cfg.tailscale.keep_qube is True.
Does NOT touch downstream qubes' netvm — repoint those to another NetVM first if
they used sys-tailscale, or they'll lose network.

Deploy (from dom0):
  sudo qubesctl top.enable mgmt.tailscale.teardown
  sudo qubesctl state.apply mgmt.tailscale.teardown
  sudo qubesctl top.disable mgmt.tailscale.teardown
#}

{%- from 'config.jinja' import cfg with context -%}
{%- set ts = cfg.get('tailscale', {}) -%}
{%- set qube = ts.get('qube', 'sys-tailscale') -%}

{% if grains['nodename'] == 'dom0' %}

# Best-effort logout so Headscale can reap the node. Ignore failure (qube may be
# down / already gone).
"tailscale-logout":
  cmd.run:
    - name: |
        if qvm-check --running {{ qube }} 2>/dev/null; then
          qvm-run --pass-io -u root {{ qube }} 'tailscale logout 2>/dev/null || true'
        fi
        true

{% if not ts.get('keep_qube', False) %}
"tailscale-remove-qube":
  cmd.run:
    - name: |
        if qvm-check {{ qube }} 2>/dev/null; then
          qvm-shutdown --wait {{ qube }} 2>/dev/null || true
          qvm-remove -f {{ qube }}
        fi
        true
    - require:
      - cmd: "tailscale-logout"
{% else %}
"tailscale-keep-qube-note":
  test.show_notification:
    - text: "mgmt.tailscale.teardown: keep_qube is True — {{ qube }} left in place (logged out)."
{% endif %}

{% endif %}
