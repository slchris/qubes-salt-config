{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Clone debian-minimal for the per-project WireGuard gateway.

Debian (not fedora like templates/vpn): matches the repo's newer gateway
standard (mgmt/tailscale) — R4.3 is nftables-native and debian-13-minimal is
the base every other unit here already mirrors/updates through TUNA.
#}

{% from 'utils/macros/clone-template.sls' import clone_template -%}
{% set name = slsdotpath.split('.')[-1] -%}
{{ clone_template('debian-minimal', name) }}
