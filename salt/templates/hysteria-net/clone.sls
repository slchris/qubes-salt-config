{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Clone debian-minimal for the Hysteria2 gateway.

Debian matches the other fail-closed gateways here (project-net,
http-proxy-net, mgmt/tailscale): R4.3 is nftables-native, and redsocks and
dnscrypt-proxy are Debian packages. Hysteria2 itself is a single static
binary, so no distro packaging is required.
#}

{% from 'utils/macros/clone-template.sls' import clone_template -%}
{% set name = slsdotpath.split('.')[-1] -%}
{{ clone_template('debian-minimal', name) }}
