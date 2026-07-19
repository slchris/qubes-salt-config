{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Port-forward so a LAN machine can SSH to the jump qube. Qubes is double-NAT'd,
so DNAT is installed in BOTH hops:

  Mac ──► sys-net(physical IP):<ext_port> ──► sys-firewall ──► jump:22

Qubes 4.2/4.3 use **nftables**. Rules are added to the existing `ip qubes`
table using the official custom hook points (a `custom-dnat-*` chain, hook
prerouting, and the `custom-forward` chain) and persisted in each hop's
/rw/config/qubes-firewall-user-script, which Qubes runs on every firewall load.
So once written, the forwarding comes back automatically on every boot — no
manual step needed.

BOOT ORDERING — the reason nothing here may consult the routing table:
  qubes-firewall.service runs the user script as soon as it starts, which on
  sys-net is SECONDS BEFORE NetworkManager has a DHCP lease (measured: script at
  05:24:28.658, dhcp4 lease at 05:24:35.112). At that moment there is no default
  route and no LAN route. Any rule whose installation depends on `ip route` will
  therefore be skipped on every single boot, which is what used to make SSH fail
  after each reboot until the formula was re-applied by hand. Rules are matched
  on `ip saddr`/`ip daddr` (no routing needed); the interface name is an optional
  tightening added only when it happens to resolve, and a NetworkManager
  dispatcher hook re-runs the script once the lease lands.

IMPORTANT — why this is driven entirely from dom0:
  qubesctl cannot run states in sys-net: Qubes denies sys-net the admin.* API by
  default (sys-net is the least-trusted qube), so `qubesctl --targets=sys-net`
  fails with "denied admin.vm.List ... sys-net -> dom0". Rather than loosen that
  (a real security downgrade), this whole formula runs in dom0 and pushes the
  firewall script into sys-net AND sys-firewall via qvm-run. Nothing runs as a
  Salt minion inside the service qubes.

Apply (dom0 only):
  sudo qubesctl state.apply mgmt.remote-debug.netfw

Requires cfg.remote_debug.network == "portforward" in config.jinja.
#}

{%- from 'config.jinja' import cfg with context -%}
{%- set rd = cfg.remote_debug -%}
{%- set qube = rd.get('qube', 'mgmt-jump') -%}
{%- set ext_port = rd.get('ssh_port', 2333) -%}
{%- set network = rd.get('network', 'portforward') -%}
{#- lan_subnet accepts a single CIDR or a list of them; normalise to a list so
    one DNAT/forward rule is emitted per client subnet. -#}
{%- set lan_raw = rd.get('lan_subnet', '10.31.0.0/24') -%}
{%- set lans = [lan_raw] if lan_raw is string else lan_raw -%}
{%- set sysnet = rd.get('sysnet', 'sys-net') -%}
{%- set sysfw = rd.get('netvm', 'sys-firewall') -%}

{% if grains['nodename'] == 'dom0' and network == 'portforward' %}

{#- The firewall script for a hop. $DEST is resolved at run time inside the hop
    by qube name, so it survives IP changes. -#}
{#- Resolve the next-hop IPs in dom0 (where this runs). A qube cannot resolve a
    DOWNSTREAM qube's name (getent hosts sys-firewall fails inside sys-net), so
    we look them up here via qvm-prefs and bake the IP into each hop's script.
    Re-run `state.apply mgmt.remote-debug.netfw` if a qube is rebuilt and its IP
    changes. -#}
{%- set sysfw_ip = salt['cmd.run']('qvm-prefs ' ~ sysfw ~ ' ip', python_shell=True).strip() -%}
{%- set jump_ip = salt['cmd.run']('qvm-prefs ' ~ qube ~ ' ip', python_shell=True).strip() -%}

{#- fw_script emits only the remote-debug rule block, wrapped in markers, so it
    can be MERGED into /rw/config/qubes-firewall-user-script without clobbering
    other rules the user added there (e.g. hotspot DHCP/DNS custom-input). -#}
{%- macro fw_script(hop) -%}
# >>> remote-debug (managed by mgmt.remote-debug.netfw — do not edit) >>>
EXT_PORT={{ ext_port }}
{% if hop == 'sys-net' -%}
FWD_DPORT={{ ext_port }}
DEST="{{ sysfw_ip }}"
{% else -%}
FWD_DPORT=22
DEST="{{ jump_ip }}"
{% endif -%}
# NEVER `exit` from this block. This file is shared with other formulas (hotspot,
# tailscale) whose blocks may follow ours, so an early exit silently skips them —
# and it is exactly what broke SSH after every reboot. Measured on sys-net:
#   05:24:28.658  qubes-firewall.service starts -> runs this script
#   05:24:32.286  ens7 only now BEGINS dhcp4
#   05:24:35.112  ens7 gets its lease; the default route appears
# The script runs ~6.5s before there is any route, so an older marker-less
# version of this block hit its `[ -n "$UPLINK" ] || exit 0` and quit before
# installing a single rule. Nothing below may depend on routing being up.
if [ -z "$DEST" ]; then
  echo "remote-debug: next-hop IP empty (re-run netfw from dom0)" >&2
else
  # DNAT (prerouting) rewrites the destination to the next hop. We ALSO need SNAT
  # (postrouting masquerade) so the next hop sees this gateway as the source —
  # otherwise its reply goes back to the original client IP, which it cannot route,
  # and the connection hangs. This is why plain DNAT alone timed out.
  # Both chains are ours alone, so delete+recreate makes re-runs idempotent.
  nft delete chain ip qubes custom-dnat-remotedebug 2>/dev/null || true
  nft delete chain ip qubes custom-snat-remotedebug 2>/dev/null || true
  nft add chain ip qubes custom-dnat-remotedebug '{ type nat hook prerouting priority -99 ; policy accept ; }'
  nft add chain ip qubes custom-snat-remotedebug '{ type nat hook postrouting priority 99 ; policy accept ; }'
  nft add rule ip qubes custom-snat-remotedebug ip daddr "$DEST" tcp dport "$FWD_DPORT" counter masquerade
  # custom-forward belongs to Qubes, not to us, so we cannot delete+recreate it.
  # Drop only OUR leftover rules by handle first — otherwise every re-run appends
  # another duplicate accept rule and the chain grows without bound.
  nft -a list chain ip qubes custom-forward 2>/dev/null \
    | grep -F "ip daddr $DEST" | grep -F "tcp dport $FWD_DPORT" \
    | grep -o 'handle [0-9]*' | awk '{print $2}' \
    | while read -r h; do nft delete rule ip qubes custom-forward handle "$h" 2>/dev/null || true; done
{%- if hop == 'sys-net' %}
  # One rule per client subnet. `ip saddr` is what actually scopes the forward to
  # trusted clients and it needs NO routing table, so it is installed correctly
  # even at boot. iifname is only an extra tightening for the multi-uplink case
  # (e.g. cellular for internet + a hotspot NIC the client connects through, where
  # the default route points at the wrong NIC); when the route is not up yet we
  # simply omit it rather than skipping the rule.
  for LAN in {{ lans | join(' ') }}; do
    UPLINK="$(ip -4 route show "$LAN" 2>/dev/null | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1)"
    [ -n "$UPLINK" ] || UPLINK="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"
    if [ -n "$UPLINK" ]; then
      nft add rule ip qubes custom-dnat-remotedebug iifname "$UPLINK" ip saddr "$LAN" tcp dport "$EXT_PORT" ct state new,established,related counter dnat to "${DEST}:${FWD_DPORT}"
      nft add rule ip qubes custom-forward iifname "$UPLINK" ip saddr "$LAN" ip daddr "$DEST" tcp dport "$FWD_DPORT" ct state new,established,related counter accept
    else
      nft add rule ip qubes custom-dnat-remotedebug ip saddr "$LAN" tcp dport "$EXT_PORT" ct state new,established,related counter dnat to "${DEST}:${FWD_DPORT}"
      nft add rule ip qubes custom-forward ip saddr "$LAN" ip daddr "$DEST" tcp dport "$FWD_DPORT" ct state new,established,related counter accept
    fi
  done
{%- else %}
  # Flush any stale ARP/neigh entry for the jump. Each restart of the jump gives
  # it a new vif, but a leftover PERMANENT neigh entry can pin the old vif/MAC, so
  # forwarded packets go to a dead interface (sys-firewall->jump silently fails
  # even though the jump has a working IP). Deleting it forces re-learning.
  ip neigh flush to "$DEST" 2>/dev/null || true
  for d in $(ip -o link show | sed -n 's/^[0-9]*: \(vif[0-9.]*\).*/\1/p'); do
    ip neigh del "$DEST" dev "$d" 2>/dev/null || true
  done
  # sys-firewall: the forwarded packet arrives with dst = sys-firewall's own IP
  # (it was DNAT'd there by sys-net) on the external port. Match on that dst IP
  # rather than iifgroup — the upstream interface group is not reliably 1, which
  # is why the DNAT never matched and the packet stalled here (conntrack showed
  # dst=<sysfw>:2333 UNREPLIED, un-DNAT'd). The baked-in fallback keeps this
  # correct at boot, when `ip route get` has nothing to answer with yet.
  SELF="$(ip -4 route get {{ jump_ip }} 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p')"
  [ -n "$SELF" ] || SELF="{{ sysfw_ip }}"
  nft add rule ip qubes custom-dnat-remotedebug ip daddr "$SELF" tcp dport "$EXT_PORT" ct state new,established,related counter dnat to "${DEST}:${FWD_DPORT}"
  nft add rule ip qubes custom-forward ip daddr "$DEST" tcp dport "$FWD_DPORT" ct state new,established,related counter accept
{%- endif %}
  # Self-heal: re-run this script whenever an interface comes up or renews its
  # lease, which both tightens the boot-time rules above once routing exists and
  # recovers from any link flap or network change. dispatcher.d lives in the
  # template's read-only rootfs and is reset every boot, so it is (re)installed
  # from here — this script is the one thing guaranteed to run as root on boot.
  D=/etc/NetworkManager/dispatcher.d/50-remote-debug-fw
  if [ -d /etc/NetworkManager/dispatcher.d ]; then
    printf '%s\n' '#!/bin/sh' 'case "$2" in' '  up|dhcp4-change|dhcp6-change)' '    [ -x /rw/config/qubes-firewall-user-script ] && /rw/config/qubes-firewall-user-script ;;' 'esac' > "$D"
    chmod 0755 "$D"
  fi
fi
# <<< remote-debug <<<
{%- endmacro %}

{#- For each hop: stage the firewall script as a dom0 temp file (Salt-native
    file.managed, no jinja filters), then stream it into the hop's /rw/config
    via `qvm-run --pass-io`, chmod, and run it now. Using file.managed +
    --pass-io avoids both b64encode (absent in this Salt) and shell quoting. -#}
{% for hop in [sysnet, sysfw] %}
{%   set script = fw_script('sys-net' if hop == sysnet else 'sys-firewall') %}
{%   set staged = '/tmp/remote-debug-fw-' ~ hop ~ '.sh' %}

"remote-debug-netfw-stage-{{ hop }}":
  file.managed:
    - name: {{ staged }}
    - mode: '0644'
    - contents: |
        {{ script | indent(8) }}

"remote-debug-netfw-write-{{ hop }}":
  cmd.run:
    # MERGE our block into /rw/config/qubes-firewall-user-script instead of
    # overwriting it — the user may have their own rules there (e.g. a Wi-Fi
    # hotspot's DHCP/DNS custom-input rules on sys-net). The remote helper:
    #  1. ensures the file exists with a #!/bin/sh shebang,
    #  2. removes the pre-marker LEGACY block (see below),
    #  3. strips any previous remote-debug marker block,
    #  4. appends our new block (piped in on stdin), and makes it executable.
    #
    # Step 2 exists because a pre-marker version of this formula wrote its rules
    # with no markers at all, so step 3's range sed could never match them: the
    # dead block survived every re-apply, sat ABOVE the managed one, and killed
    # the whole script at boot via its `[ -n "$UPLINK" ] || exit 0`. It is
    # identified by the header comment that version emitted, and is deleted only
    # up to the marker — never to EOF — and only when that marker is present, so
    # a following hotspot/tailscale block can never be swallowed by the range.
    - name: |
        cat {{ staged }} | qvm-run --pass-io -u root -- {{ hop }} 'F=/rw/config/qubes-firewall-user-script; NEW=$(cat); [ -f "$F" ] || printf "#!/bin/sh\n" > "$F"; grep -q "^#!" "$F" || sed -i "1i #!/bin/sh" "$F"; grep -q "^# >>> remote-debug" "$F" && sed -i "/^# remote-debug port-forward/,/^# >>> remote-debug/{/^# >>> remote-debug/!d}" "$F"; sed -i "/# >>> remote-debug/,/# <<< remote-debug <<</d" "$F"; printf "%s\n" "$NEW" >> "$F"; chmod 0755 "$F"'
    - onlyif: qvm-check --running {{ hop }}
    - require:
      - file: "remote-debug-netfw-stage-{{ hop }}"

"remote-debug-netfw-apply-{{ hop }}":
  cmd.run:
    - name: qvm-run --pass-io -u root -- {{ hop }} /rw/config/qubes-firewall-user-script
    - onlyif: qvm-check --running {{ hop }}
    - require:
      - cmd: "remote-debug-netfw-write-{{ hop }}"

{% endfor %}

{% endif %}
