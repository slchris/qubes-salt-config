{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Clone debian-minimal for the transparent HTTP-CONNECT proxy gateway.

Debian matches the other fail-closed gateways in this repo (project-net,
mgmt/tailscale): R4.3 is nftables-native, and redsocks, tinyproxy and
dnscrypt-proxy are all Debian packages. No pinned binary is needed.
#}

{% from 'utils/macros/clone-template.sls' import clone_template -%}
{% set name = slsdotpath.split('.')[-1] -%}
{{ clone_template('debian-minimal', name) }}
