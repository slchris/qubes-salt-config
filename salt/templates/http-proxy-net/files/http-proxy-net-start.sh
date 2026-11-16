#!/bin/sh
# SPDX-License-Identifier: MIT — managed by templates.http-proxy-net.install
#
# http-proxy-net-start --prepare   build configs, rules and start the daemons
# http-proxy-net-start --rules     only rebuild the nft extension chains
# http-proxy-net-start --check     validate upstream.conf and exit
#
# upstream.conf is NEVER sourced. It is parsed with sed after an ownership
# and mode check, so a planted line is data, not code.
#
# Fail-closed invariant: any failure runs close_gateway(), which stops the
# daemons, removes the ready flag and the resolved endpoint, and rebuilds the
# dynamic chain empty. The static base table (policy drop on forward/output)
# is never removed.

set -u

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

CONF=${UPSTREAM_CONF:-/rw/config/http-proxy-net/upstream.conf}
RUN=/run/http-proxy-net
RESOLVED=$RUN/upstream.resolved
READY=$RUN/ready
TINY=$RUN/tinyproxy.conf
BASE=/etc/http-proxy-net/base.nft
TINY_UNIT=http-proxy-net-tinyproxy
REDSOCKS_UNIT=http-proxy-net-redsocks
DNSCRYPT_UNIT=http-proxy-net-dnscrypt

err() { printf 'http-proxy-net: %s\n' "$*" >&2; }
note() { logger -t http-proxy-net "$*" 2>/dev/null || true; err "$*"; }

valid_ip4() {
  case "$1" in *[!0-9.]*|""|.*|*.|*..*) return 1 ;; esac
  _ifs=$IFS; IFS=.; set -- $1; IFS=$_ifs
  [ $# -eq 4 ] || return 1
  for _o in "$1" "$2" "$3" "$4"; do
    [ "$_o" -le 255 ] 2>/dev/null || return 1
  done
}

valid_host() {
  case "$1" in
    ""|*[!A-Za-z0-9.-]*|-*|.*|*.|*-|*.-*|*-.*) return 1 ;;
  esac
}

valid_port() {
  # Length check via a pattern, so the script stays free of Jinja
  # delimiters and a future state edit cannot accidentally render it.
  case "$1" in ""|*[!0-9]*|0*|??????*) return 1 ;; esac
  [ "$1" -le 65535 ]
}

# Whitespace, quotes, '#', backslash and non-printable bytes would break (or
# inject into) the tinyproxy config line. '@' is the credential separator.
bad_cred() {
  case "$1" in
    *[[:space:]]*|*'@'*|*'#'*|*\\*|*'"'*|*"'"*) return 0 ;;
  esac
  printf '%s' "$1" | LC_ALL=C grep -q '^[ -~]*$' || return 0
  return 1
}

# CONNECT_PORTS must include 443: dnscrypt's DoH connection goes through
# tinyproxy, and tinyproxy denies CONNECT to a port with no ConnectPort line.
valid_ports() {
  [ -n "$1" ] || return 1
  _has443=0
  _rest=$1
  while [ -n "$_rest" ]; do
    _p=${_rest%%,*}
    case "$_rest" in *,*) _rest=${_rest#*,} ;; *) _rest= ;; esac
    valid_port "$_p" || return 1
    [ "$_p" = 443 ] && _has443=1
  done
  [ "$_has443" -eq 1 ]
}

conf_get() {
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CONF" 2>/dev/null \
    | head -n 1 | sed 's/[[:space:]]*$//'
}

parse_conf() {
  PROXY_HOST=$(conf_get PROXY_HOST)
  PROXY_PORT=$(conf_get PROXY_PORT)
  PROXY_USER=$(conf_get PROXY_USER)
  PROXY_PASS=$(conf_get PROXY_PASS)
  PROXY_IP=$(conf_get PROXY_IP)
  CONNECT_PORTS=$(conf_get CONNECT_PORTS)
  [ -n "$CONNECT_PORTS" ] || CONNECT_PORTS=80,443
}

# An all-empty file is the untouched skeleton: not an error, just closed.
conf_configured() {
  [ -n "${PROXY_HOST}${PROXY_PORT}${PROXY_USER}${PROXY_PASS}${PROXY_IP}" ]
}

validate_conf() {
  _ok=1
  valid_host "$PROXY_HOST" || { err "PROXY_HOST is not a hostname or IPv4 literal"; _ok=0; }
  valid_port "$PROXY_PORT" || { err "PROXY_PORT must be 1-65535"; _ok=0; }
  if [ -z "$PROXY_USER" ] || bad_cred "$PROXY_USER" || [ "${PROXY_USER#*:}" != "$PROXY_USER" ]; then
    err "PROXY_USER is empty or contains a forbidden character (':' is not allowed)"
    _ok=0
  fi
  if [ -z "$PROXY_PASS" ] || bad_cred "$PROXY_PASS"; then
    err "PROXY_PASS is empty or contains a forbidden character ('@' is not allowed)"
    _ok=0
  fi
  if [ -n "$PROXY_IP" ] && ! valid_ip4 "$PROXY_IP"; then
    err "PROXY_IP is not an IPv4 literal"
    _ok=0
  fi
  valid_ports "$CONNECT_PORTS" || { err "CONNECT_PORTS must be comma-separated ports and include 443 (DoH)"; _ok=0; }
  [ "$_ok" -eq 1 ]
}

ensure_base() {
  nft list table inet http-proxy-net >/dev/null 2>&1 && return 0
  if [ -f "$BASE" ]; then
    nft -f "$BASE" 2>/dev/null && return 0
  fi
  # Minimal fallback: still closed if the template file is missing.
  printf '%s\n' \
    'table inet http-proxy-net {' \
    '  chain forward { type filter hook forward priority -10; policy drop; }' \
    '  chain output { type filter hook output priority -10; policy drop; }' \
    '}' | nft -f - 2>/dev/null || note "FAILED to install fallback closed table"
}

refresh_custom_input() {
  nft list chain ip qubes custom-input >/dev/null 2>&1 || return 0
  nft -a list chain ip qubes custom-input 2>/dev/null \
    | grep -F 'comment "http-proxy-net"' \
    | grep -o 'handle [0-9]*' | awk '{print $2}' \
    | while read -r _h; do
        nft delete rule ip qubes custom-input handle "$_h" 2>/dev/null || true
      done
  nft add rule ip qubes custom-input iifname "vif*" udp dport 53 accept comment "http-proxy-net" 2>/dev/null || true
  nft add rule ip qubes custom-input iifname "vif*" tcp dport 53 accept comment "http-proxy-net" 2>/dev/null || true
  nft add rule ip qubes custom-input iifname "vif*" tcp dport 12345 accept comment "http-proxy-net" 2>/dev/null || true
}

rules() {
  ensure_base
  nft list table inet http-proxy-net >/dev/null 2>&1 || return 0
  nft flush chain inet http-proxy-net output-dynamic 2>/dev/null || true
  if [ -f "$RESOLVED" ]; then
    read -r _ip _port < "$RESOLVED" 2>/dev/null || true
    if valid_ip4 "${_ip:-}" && valid_port "${_port:-}"; then
      nft add rule inet http-proxy-net output-dynamic \
        ip daddr "$_ip" tcp dport "$_port" counter accept 2>/dev/null \
        || note "FAILED to add upstream exception $_ip:$_port"
    else
      note "ignoring invalid $RESOLVED"
    fi
  fi
  refresh_custom_input
}

# Restore the netvm-provided resolver before resolving PROXY_HOST. The file
# under /run is the exact resolv.conf setup-ip wrote, saved before the first
# rewrite and outside RuntimeDirectory so a service restart keeps it; after
# a reboot setup-ip writes resolv.conf again and this re-saves it. QubesDB
# is the fallback: /qubes-{primary,secondary}-dns is what dom0 gives THIS
# qube (setup-ip's source); /qubes-netvm-* is the compat fallback. Without
# this, a re-apply after a failed one would try to resolve through a stopped
# dnscrypt.
restore_bootstrap_resolv() {
  _saved=/run/http-proxy-net-bootstrap.resolv
  if [ -s "$_saved" ] && ! grep -q '127\.0\.0\.1' "$_saved" 2>/dev/null; then
    cat "$_saved" > /etc/resolv.conf 2>/dev/null || true
    return 0
  fi
  _d1=$(qubesdb-read /qubes-primary-dns 2>/dev/null || true)
  _d2=$(qubesdb-read /qubes-secondary-dns 2>/dev/null || true)
  if ! valid_ip4 "${_d1:-}"; then
    _d1=$(qubesdb-read /qubes-netvm-primary-dns 2>/dev/null || true)
    _d2=$(qubesdb-read /qubes-netvm-secondary-dns 2>/dev/null || true)
  fi
  if valid_ip4 "${_d1:-}"; then
    {
      printf 'nameserver %s\n' "$_d1"
      if valid_ip4 "${_d2:-}"; then printf 'nameserver %s\n' "$_d2"; fi
    } > "$_saved" 2>/dev/null || true
    cat "$_saved" > /etc/resolv.conf 2>/dev/null || true
    return 0
  fi
  if [ -s /etc/resolv.conf ] && ! grep -q '127\.0\.0\.1' /etc/resolv.conf 2>/dev/null; then
    cat /etc/resolv.conf > "$_saved" 2>/dev/null || true
  fi
}

bootstrap_off() {
  nft flush chain inet http-proxy-net bootstrap 2>/dev/null || true
}

bootstrap_on() {
  bootstrap_off
  while read -r _key _ns _rest; do
    [ "$_key" = nameserver ] || continue
    valid_ip4 "${_ns:-}" || continue
    nft add rule inet http-proxy-net bootstrap ip daddr "$_ns" udp dport 53 counter accept 2>/dev/null || true
    nft add rule inet http-proxy-net bootstrap ip daddr "$_ns" tcp dport 53 counter accept 2>/dev/null || true
  done < /etc/resolv.conf
}

resolve_host() {
  _RESOLVED_IP=
  if [ -n "$PROXY_IP" ]; then
    _RESOLVED_IP=$PROXY_IP
    valid_ip4 "$_RESOLVED_IP" || { err "PROXY_IP is not IPv4"; return 1; }
    return 0
  fi
  bootstrap_on
  _tries=0
  while [ "$_tries" -lt 3 ]; do
    _got=$(timeout 10 getent ahostsv4 "$PROXY_HOST" 2>/dev/null | awk 'NR==1 {print $1}')
    if valid_ip4 "${_got:-}"; then
      _RESOLVED_IP=$_got
      break
    fi
    _tries=$((_tries + 1))
    sleep 2
  done
  bootstrap_off
  valid_ip4 "${_RESOLVED_IP:-}" || { err "cannot resolve PROXY_HOST=$PROXY_HOST"; _RESOLVED_IP=; return 1; }
}

write_resolved() {
  _tmp=$RESOLVED.$$
  printf '%s %s\n' "$_RESOLVED_IP" "$PROXY_PORT" > "$_tmp" || return 1
  chmod 0600 "$_tmp" || return 1
  mv -f "$_tmp" "$RESOLVED" || return 1
}

gen_tinyproxy() {
  _tmp=$TINY.$$
  {
    printf '%s\n' 'Listen 127.0.0.1'
    printf '%s\n' 'Port 8888'
    printf '%s\n' 'Allow 127.0.0.1'
    printf '%s\n' 'User tinyproxy'
    printf '%s\n' 'Group tinyproxy'
    printf '%s\n' 'LogLevel Warning'
    printf '%s\n' 'Syslog On'
    printf '%s\n' 'Timeout 600'
    printf '%s\n' 'DisableViaHeader Yes'
    for _p in $(printf '%s' "$CONNECT_PORTS" | tr ',' ' '); do
      printf 'ConnectPort %s\n' "$_p"
    done
    printf 'upstream http %s:%s@%s:%s\n' "$PROXY_USER" "$PROXY_PASS" "$_RESOLVED_IP" "$PROXY_PORT"
  } > "$_tmp" || return 1
  chmod 0600 "$_tmp" || return 1
  mv -f "$_tmp" "$TINY" || return 1
}

set_resolv_conf() {
  _tmp=/etc/resolv.conf.http-proxy-net.$$
  if printf 'nameserver 127.0.0.1\n' > "$_tmp" 2>/dev/null && mv -f "$_tmp" /etc/resolv.conf 2>/dev/null; then
    return 0
  fi
  rm -f "$_tmp" 2>/dev/null || true
  printf 'nameserver 127.0.0.1\n' > /etc/resolv.conf 2>/dev/null \
    || note "could not point /etc/resolv.conf at 127.0.0.1 (gateway DNS stays closed)"
}

check_owner() {
  [ "$(id -u)" = 0 ] || { err "must run as root"; return 1; }
  _perm=$(stat -c '%U %a' "$CONF" 2>/dev/null || true)
  case "$_perm" in
    "root 600") return 0 ;;
    *) err "$CONF must be root-owned with mode 0600 (found: ${_perm:-unknown})"; return 1 ;;
  esac
}

wait_unit() {
  _n=0
  while [ "$_n" -lt 10 ]; do
    systemctl is-active --quiet "$1" && break
    _n=$((_n + 1))
    sleep 1
  done
  systemctl is-active --quiet "$1" || return 1
  # Type=simple is "active" the moment exec returns. Give an immediately
  # crashing daemon (RestartSec=5) time to fall back to activating/failed.
  sleep 1
  systemctl is-active --quiet "$1"
}

start_daemons() {
  systemctl restart "$TINY_UNIT" 2>/dev/null || { err "$TINY_UNIT failed to start"; return 1; }
  wait_unit "$TINY_UNIT" || { err "$TINY_UNIT is not active"; return 1; }
  systemctl restart "$REDSOCKS_UNIT" 2>/dev/null || { err "$REDSOCKS_UNIT failed to start"; return 1; }
  wait_unit "$REDSOCKS_UNIT" || { err "$REDSOCKS_UNIT is not active"; return 1; }
  systemctl restart "$DNSCRYPT_UNIT" 2>/dev/null || { err "$DNSCRYPT_UNIT failed to start"; return 1; }
  wait_unit "$DNSCRYPT_UNIT" || { err "$DNSCRYPT_UNIT is not active"; return 1; }
}

close_gateway() {
  systemctl stop "$TINY_UNIT" "$REDSOCKS_UNIT" "$DNSCRYPT_UNIT" >/dev/null 2>&1 || true
  rm -f "$READY" "$RESOLVED"
  rules
}

prepare() {
  umask 077
  mkdir -p "$RUN" 2>/dev/null || true
  rm -f "$READY"
  restore_bootstrap_resolv
  rules

  if [ ! -f "$CONF" ]; then
    close_gateway
    note "no $CONF - gateway fully closed"
    return 0
  fi
  parse_conf
  if ! conf_configured; then
    close_gateway
    note "$CONF is empty - gateway fully closed"
    return 0
  fi
  check_owner || { close_gateway; return 1; }
  validate_conf || { close_gateway; return 1; }
  resolve_host || { close_gateway; return 1; }
  write_resolved || { close_gateway; return 1; }
  rules
  gen_tinyproxy || { close_gateway; return 1; }
  set_resolv_conf
  : > "$READY" || { close_gateway; return 1; }
  chmod 0644 "$READY" || { close_gateway; return 1; }
  start_daemons || { close_gateway; return 1; }
  note "upstream ${_RESOLVED_IP}:${PROXY_PORT} ready"
}

check() {
  [ -f "$CONF" ] || return 0
  parse_conf
  conf_configured || return 0
  validate_conf
}

case "${1:-}" in
  --prepare) prepare ;;
  --rules) rules ;;
  --check) check ;;
  *)
    err "usage: $0 --prepare | --rules | --check"
    exit 2
    ;;
esac
