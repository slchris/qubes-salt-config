{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Configure the sys-project-net WireGuard gateway (runs IN the qube, not dom0).

Fail-closed by design. The firewall block is installed and active BEFORE the
tunnel ever comes up (qubes-firewall runs the user script early at boot;
rc.local runs later), and it stays up if the tunnel dies:

  1. downstream (vif*) traffic may ONLY be forwarded into wg0 — never eth0;
  2. the gateway's own clearnet egress is limited to the WireGuard handshake
     (the Endpoint ip:port parsed from wg0.conf) — tunnel down => nothing
     leaks, things just stop working until it is back;
  3. downstream DNS (queries to the Qubes virtual NS 10.139.1.1/.2) is DNAT'd
     to the tunnel resolver from wg0.conf's DNS= line (fallback: 9.9.9.9,
     still routed THROUGH the tunnel) so lookups never exit via the upstream
     resolvers — the classic VPN-gateway DNS leak;
  4. NAT: masquerade downstream traffic out wg0.

The WireGuard credential (wg0.conf) is a secret and is NOT salt-managed.
Mullvad or any standard provider/peer works — they all emit plain wg-quick
confs. Supply it once:

    qvm-copy-to-vm sys-project-net wg0.conf
    # inside sys-project-net:
    sudo mv /home/user/QubesIncoming/*/wg0.conf /rw/config/wireguard/wg0.conf
    sudo chmod 600 /rw/config/wireguard/wg0.conf

then restart the qube (or re-apply this state). Use an IP-literal Endpoint
(Mullvad's default): under the kill-switch a hostname endpoint can never
resolve before the tunnel exists, so it is treated as "no endpoint" and gets
no clearnet exception.

Deploy (from dom0):
  sudo qubesctl --skip-dom0 --targets=sys-project-net state.apply templates.project-net.configure
#}

{% if grains['nodename'] != 'dom0' %}

"project-net-wireguard-dir":
  file.directory:
    - name: /rw/config/wireguard
    - user: root
    - group: root
    - mode: '0700'

# Kill-switch + downstream DNS + NAT, marker-merged into the shared
# qubes-firewall-user-script (same convention as mgmt.tailscale/remote-debug:
# we own only our >>> project-net >>> section, other modules keep theirs).
#
# Two-stage load, so bad user input can NEVER produce fail-open:
#
#   1. (re)load the 100% static base table from /etc/project-net/base.nft
#      (shipped by templates.project-net.install; also loaded even earlier at
#      boot by project-net-fail-closed.service). No interpolated values — it
#      cannot fail to parse. It drops vif*-forward except into wg0, drops the
#      gateway's own eth0 egress, and leaves two extension points: the empty
#      `output-dynamic` chain (jumped BEFORE the eth0 drop) and the empty
#      `dnat-dns` nat chain (prerouting -110, i.e. before Qubes' own dnat-dns
#      at dstnat -100).
#   2. append the conf-derived dynamic rules with individual `nft add rule`
#      commands. If parsing/validation rejects a value, or an add fails, the
#      base drops stay intact: the gateway degrades to fully-closed (tunnel
#      cannot handshake, downstream DNS is dropped) — never to clearnet.
#
# Validation is structural, not just charset (a value like 1.2.3:99999 that
# slips into an nft command would make that command fail — harmless for the
# kill-switch, but it must also never silently half-work): IPv4 = exactly
# four octets 0-255, port = 1-65535. Key matching is case-insensitive (GNU
# sed //I) because wireguard-tools itself accepts `endpoint =` / `dns =`.
#
# The `inet` family covers IPv6 with the same chains: v6 downstream traffic
# that cannot go through the (v4) tunnel hits the same fail-closed drop.
"project-net-fw-script":
  file.blockreplace:
    - name: /rw/config/qubes-firewall-user-script
    - marker_start: "# >>> project-net >>>"
    - marker_end: "# <<< project-net <<<"
    - append_if_not_found: True
    - show_changes: True
    - content: |
        # Managed by templates.project-net.configure — do not edit between markers.
        # Fail-closed WireGuard gateway policy; active even with no wg0.conf.
        valid_ip4() {
          case "$1" in *[!0-9.]*|""|.*|*.|*..*) return 1 ;; esac
          _ifs=$IFS; IFS=.; set -- $1; IFS=$_ifs
          [ $# -eq 4 ] || return 1
          for _o in "$1" "$2" "$3" "$4"; do
            [ "$_o" -le 255 ] || return 1
          done
        }
        WG_CONF=/rw/config/wireguard/wg0.conf
        EP_IP=""; EP_PORT=""; DNS_IP=""
        if [ -f "$WG_CONF" ]; then
          ep=$(sed -n 's/^[[:space:]]*Endpoint[[:space:]]*=[[:space:]]*//Ip' "$WG_CONF" | head -n1 | tr -d '[:space:]')
          EP_IP=${ep%:*}
          EP_PORT=${ep##*:}
          DNS_IP=$(sed -n 's/^[[:space:]]*DNS[[:space:]]*=[[:space:]]*//Ip' "$WG_CONF" | head -n1 | cut -d, -f1 | tr -d '[:space:]')
        fi
        # Only a valid IPv4-literal ip:port endpoint gets the pre-tunnel eth0
        # exception; hostname / IPv6 / malformed => no exception (stays closed).
        valid_ip4 "$EP_IP" || EP_IP=""
        case "$EP_PORT" in *[!0-9]*|"") EP_IP="" ;; esac
        [ -n "$EP_IP" ] && { [ "$EP_PORT" -ge 1 ] && [ "$EP_PORT" -le 65535 ] || EP_IP=""; }
        # Downstream DNS target must be a valid IPv4 literal; if the conf sets
        # none (or a v6/hostname value), fall back to a public resolver routed
        # THROUGH wg0 — never the upstream Qubes resolvers (that leaks every
        # lookup to the clearnet).
        valid_ip4 "$DNS_IP" || DNS_IP=9.9.9.9
        # Stage 1: static fail-closed base (atomic replace; cannot fail on input).
        nft -f /etc/project-net/base.nft || logger -t project-net "FAILED to load base ruleset"
        # Stage 2: conf-derived dynamic rules; failures degrade to fully-closed.
        if [ -n "$EP_IP" ]; then
          nft add rule inet project-net output-dynamic oifname "eth0" ip daddr $EP_IP udp dport $EP_PORT counter accept \
            || logger -t project-net "FAILED to add endpoint exception $EP_IP:$EP_PORT"
        else
          logger -t project-net "no valid IPv4 Endpoint in wg0.conf - gateway fully closed"
        fi
        nft add rule inet project-net dnat-dns iifname "vif*" ip daddr { 10.139.1.1, 10.139.1.2 } udp dport 53 counter dnat ip to $DNS_IP \
          || logger -t project-net "FAILED to add udp DNS dnat to $DNS_IP"
        nft add rule inet project-net dnat-dns iifname "vif*" ip daddr { 10.139.1.1, 10.139.1.2 } tcp dport 53 counter dnat ip to $DNS_IP \
          || logger -t project-net "FAILED to add tcp DNS dnat to $DNS_IP"

"project-net-fw-shebang":
  cmd.run:
    - name: |
        f=/rw/config/qubes-firewall-user-script
        head -n1 "$f" | grep -q '^#!' || sed -i '1i #!/bin/sh' "$f"
        chmod 0755 "$f"
    - runas: root
    - require:
      - file: "project-net-fw-script"

# Install the kill-switch NOW (this run), before any tunnel/downstream
# exists — then VERIFY it actually loaded. The script itself swallows nft
# failures (`|| logger`) so an unattended boot never aborts other modules'
# blocks; the salt apply is where a failure must surface loudly.
"project-net-fw-apply-now":
  cmd.run:
    - name: |
        /rw/config/qubes-firewall-user-script
        nft list table inet project-net > /dev/null
        nft list chain inet project-net forward | grep -q 'iifname "vif\*" counter'
    - runas: root
    - require:
      - cmd: "project-net-fw-shebang"
      - file: "project-net-wireguard-dir"

# Bring the tunnel up on every boot, after the kill-switch (qubes-firewall
# starts before rc.local), so a missing/broken conf fails CLOSED.
"project-net-rc-local":
  file.blockreplace:
    - name: /rw/config/rc.local
    - marker_start: "# >>> project-net >>>"
    - marker_end: "# <<< project-net <<<"
    - append_if_not_found: True
    - content: |
        # Managed by templates.project-net.configure — do not edit between markers.
        if [ -f /rw/config/wireguard/wg0.conf ]; then
          wg-quick up /rw/config/wireguard/wg0.conf 2>&1 | logger -t project-net
        fi

"project-net-rc-shebang":
  cmd.run:
    - name: |
        f=/rw/config/rc.local
        head -n1 "$f" | grep -q '^#!' || sed -i '1i #!/bin/sh' "$f"
        chmod 0755 "$f"
    - runas: root
    - require:
      - file: "project-net-rc-local"

# Bring the tunnel up NOW if the conf is already in place (first deploy drops
# the conf after this state — then just restart the qube). No `|| true`: a
# broken conf must fail the apply visibly, the kill-switch keeps it safe.
"project-net-wg-up-now":
  cmd.run:
    - name: wg-quick up /rw/config/wireguard/wg0.conf
    - runas: root
    - onlyif: test -f /rw/config/wireguard/wg0.conf
    - unless: ip link show wg0
    - require:
      - cmd: "project-net-fw-apply-now"
      - cmd: "project-net-rc-shebang"

{% endif %}
