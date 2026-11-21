#!/bin/sh
# SPDX-License-Identifier: MIT — managed by templates.hysteria-net.install
#
# hysteria-net-start --prepare   bring the sing-box hysteria2 gateway up
# hysteria-net-start --rules     (re)apply the nft/route plumbing for tun0
# hysteria-net-start --check     validate client config and exit
#
# Design (proven on the reference deployment):
#   - sing-box runs the Hysteria2 (QUIC) outbound over a userspace gvisor tun
#     whose address is the Qubes virtual DNS subnet 10.139.1.0/30.  That is the
#     key trick: downstream qubes already route DNS/10.139.x into their netvm,
#     so no DNAT-to-local is needed and Qubes' forward model is respected.
#   - The binary lives on /rw (persistent) but is COPIED to /tmp before exec:
#     executing it straight from /rw segfaults on this Debian/tmpfs layout.
#   - Downstream (vif) traffic must reach tun0 and its replies must go back out
#     the vif, so we (a) accept vif<->tun0 in Qubes' forward chains and (b) add
#     ip rule 8999 "to 10.137.0.0/16 lookup main" so replies to downstream
#     qubes are NOT swallowed by sing-box's table 2022 default route.

set -u
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

CONF=${HYSTERIA_CONF:-/rw/config/hysteria-net/config.json}
RWBIN=/rw/config/hysteria-net/bin/sing-box
RUNBIN=/tmp/sing-box
RUNCFG=/tmp/hysteria-net-config.json
# sing-box auto_route uses this table number for its rules (9000-9002 -> 2022).

err() { printf 'hysteria-net: %s\n' "$*" >&2; }
note() { logger -t hysteria-net "$*" 2>/dev/null || true; err "$*"; }

# --- fail-closed base: drop downstream->eth0 forwarding until tun is up ------
fail_closed() {
  sysctl -qw net.ipv4.ip_forward=1 || true
  # Qubes already drops vif forward by default; this makes it explicit and
  # removes any accept we may have added for tun0 if the gateway is closing.
  for c in $(nft -a list chain ip qubes-firewall forward 2>/dev/null \
             | sed -n 's/.*\(iifname "tun0"[^\n]*\)handle \([0-9]*\).*/\2/p'); do
    nft delete rule ip qubes-firewall forward handle "$c" 2>/dev/null || true
  done
  rm -f /run/hysteria-net/ready
  stop_singbox
}

check_conf() {
  [ -f "$CONF" ] || { err "no config.json"; return 1; }
  case "$(stat -c '%a' "$CONF" 2>/dev/null)" in 600|400) : ;; *)
    err "config.json must be mode 0600/0400"; return 1 ;; esac
  # crude but effective sanity: needs a hysteria2 outbound with a server and
  # a password, and the tun address line. sing-box will do the real validation.
  grep -q '"type"[[:space:]]*:[[:space:]]*"hysteria2"' "$CONF" || { err "no hysteria2 outbound"; return 1; }
  grep -q 'CHANGEME' "$CONF" && { err "config.json still contains CHANGEME"; return 1; }
  grep -q '10\.139\.1\.0/30' "$CONF" || { err "tun address must be 10.139.1.0/30"; return 1; }
  return 0
}

ensure_bin() {
  [ -x "$RUNBIN" ] && "$RUNBIN" version >/dev/null 2>&1 && return 0
  [ -x "$RWBIN" ] || { err "no sing-box binary at $RWBIN"; return 1; }
  cp "$RWBIN" "$RUNBIN" || { err "copy binary failed"; return 1; }
  chmod 0755 "$RUNBIN"
  "$RUNBIN" version >/dev/null 2>&1 || { err "sing-box does not run from /tmp"; return 1; }
}

# sing-box is launched directly with a pidfile, not through its systemd unit:
# the AppVM's root (and therefore /etc/systemd/system) can be a stale template
# clone that never refreshes, so the unit is not trustworthy. /tmp and a
# pidfile in /run are always current.
PIDFILE=/run/hysteria-net/singbox.pid
stop_singbox() {
  if [ -f "$PIDFILE" ]; then
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE"
  fi
  pkill -f "$RUNBIN run" 2>/dev/null || true
  # let tun0 disappear before the caller re-adds rules
  i=0
  while [ $i -lt 25 ] && ip link show tun0 >/dev/null 2>&1; do i=$((i+1)); sleep 0.1; done
}
start_singbox() {
  stop_singbox
  install -d -m 0750 /run/hysteria-net
  setsid "$RUNBIN" run -c "$RUNCFG" >> /run/hysteria-net/singbox.log 2>&1 < /dev/null &
  echo $! > "$PIDFILE"
  return 0
}

apply_rules() {
  # 1. reply path: downstream subnet must exit via its vif, not table 2022.
  ip rule show | grep -q '10.137.0.0/16 lookup main' \
    || ip rule add to 10.137.0.0/16 lookup main priority 8999
  # 2. accept vif<->tun0 and tun0 in Qubes' forward chains (policy drop).
  add_accept() {
    nft list chain "$1" 2>/dev/null | grep -qF "$2" && return 0
    nft insert rule "$1" $2 accept 2>/dev/null || true
  }
  add_accept "ip qubes-firewall forward" 'iifname "vif*" oifname "tun0"'
  add_accept "ip qubes-firewall forward" 'iifname "tun0" oifname "vif*"'
  add_accept "ip qubes-firewall forward" 'iifname "tun0"'
  add_accept "ip qubes forward" 'iifname "tun0"'
  add_accept "ip qubes forward" 'oifname "tun0"'
  # 3. clamp MSS on tun0 egress so downstream 1500-MTU SYNs fit the tunnel.
  nft list chain ip qubes-firewall forward 2>/dev/null | grep -q 'tcp option maxseg size set rt mtu' \
    || nft insert rule ip qubes-firewall forward oifname "tun0" tcp flags syn tcp option maxseg size set rt mtu 2>/dev/null || true
}

prepare() {
  check_conf || { fail_closed; return 1; }
  ensure_bin || { fail_closed; return 1; }
  install -d -m 0750 /run/hysteria-net
  install -m 0600 "$CONF" "$RUNCFG"

  start_singbox || { note "sing-box start failed"; fail_closed; return 1; }
  # wait for tun0 before touching forward rules
  i=0
  while [ $i -lt 50 ]; do
    ip link show tun0 >/dev/null 2>&1 && break
    i=$((i+1)); sleep 0.2
  done
  ip link show tun0 >/dev/null 2>&1 || { note "tun0 never appeared"; fail_closed; return 1; }

  apply_rules
  : > /run/hysteria-net/ready
  note "gateway up: tun0 + hysteria2 via sing-box"
  return 0
}

case "${1:-}" in
  --check) check_conf && note "config OK" ;;
  --rules) apply_rules ;;
  --prepare|"") prepare ;;
  *) err "usage: $0 [--prepare|--rules|--check]"; exit 2 ;;
esac
