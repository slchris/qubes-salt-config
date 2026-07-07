#!/bin/bash
# SPDX-FileCopyrightText: 2026 Chris Su
# SPDX-License-Identifier: MIT
#
# One-shot, comprehensive diagnosis of the remote-debug port-forward path.
# Run in DOM0. Collects EVERYTHING needed to locate where the double-NAT
# forward breaks, so no follow-up commands are needed.
#
#   sudo ./scripts/diagnose-netfw.sh
#   # keep it running; when it prints the SSH prompt, run from your Mac:
#   #   ssh -p 2333 user@<sys-net-physical-ip>
#
# Then upload /tmp/qsc-netfw.txt from a networked qube:
#   cat /tmp/qsc-netfw.txt | qvm-run --pass-io <netqube> \
#     'curl -s -X POST --data-binary @- "https://pb.plz.ac/"'

set -u

OUT="/tmp/qsc-netfw.txt"
SYSNET="sys-net"
SYSFW="sys-firewall"
JUMP="mgmt-jump"
EXT_PORT="2333"
CAP_SECS=12

exec > "$OUT" 2>&1
sec() { echo; echo "===== $1 ====="; }
run_in() { local q="$1"; shift; qvm-run --pass-io -u root -- "$q" "$*" 2>&1; }

FW_IP="$(qvm-prefs "$SYSFW" ip 2>&1)"
JUMP_IP="$(qvm-prefs "$JUMP" ip 2>&1)"

echo "remote-debug netfw diagnose (comprehensive)"
echo "hops: $SYSNET -> $SYSFW -> $JUMP   ext_port=$EXT_PORT"

sec "0. IPs / netvm"
echo "sys-firewall ip: $FW_IP"
echo "mgmt-jump ip:    $JUMP_IP"
echo "mgmt-jump netvm: $(qvm-prefs "$JUMP" netvm 2>&1)"
echo "sys-firewall netvm: $(qvm-prefs "$SYSFW" netvm 2>&1)"

sec "1. jump: sshd listen"
run_in "$JUMP" 'ss -tlnp | grep ":22" || echo NO_SSHD_LISTEN'

sec "2. jump: FULL nft ruleset (does it have a qubes table? is input drop? is custom-input empty?)"
run_in "$JUMP" 'nft list ruleset 2>&1 || echo "nft failed"'

sec "3. jump: NETWORK HEALTH (root cause suspect — does the qube even have a NIC?)"
echo "--- all links (lo only == no network!) ---"
run_in "$JUMP" 'ip -o link show 2>&1'
echo "--- all addrs ---"
run_in "$JUMP" 'ip -o addr show 2>&1'
echo "--- /sys/class/net (kernel-visible interfaces) ---"
run_in "$JUMP" 'ls -1 /sys/class/net/ 2>&1'
echo "--- default route ---"
run_in "$JUMP" 'ip route 2>&1'
echo "--- qubes network service ---"
run_in "$JUMP" 'systemctl is-active qubes-network 2>&1; systemctl status qubes-network 2>&1 | tail -6'
echo "--- qubesdb network values (what IP/gw Qubes told the qube to use) ---"
run_in "$JUMP" 'for k in /qubes-ip /qubes-netmask /qubes-gateway /qubes-primary-dns; do printf "%s = " "$k"; qubesdb-read "$k" 2>&1; echo; done'
echo "--- dmesg network/vif errors ---"
run_in "$JUMP" 'dmesg 2>/dev/null | grep -iE "eth0|vif|xen-netfront|network" | tail -8 || echo "no dmesg access"'

sec "3b. jump: dom0-side network prefs"
echo "provides_network: $(qvm-prefs "$JUMP" provides_network 2>&1)"
echo "visible_ip:       $(qvm-prefs "$JUMP" visible_ip 2>&1)"
echo "mac:              $(qvm-prefs "$JUMP" mac 2>&1)"
echo "qrexec/features:  $(qvm-features "$JUMP" 2>&1 | grep -iE 'net|ip' || echo none)"

sec "4. sys-firewall: interfaces, route to jump, neigh entry for jump"
run_in "$SYSFW" "ip -4 -o addr show | grep -E 'vif|eth'; echo '--- route get jump ---'; ip route get ${JUMP_IP}; echo '--- neigh for jump ---'; ip neigh | grep ${JUMP_IP} || echo 'NO NEIGH ENTRY for jump (ARP not resolved!)'"

sec "5. sys-firewall: ACTIVE probes to jump (can it even reach the jump itself?)"
echo "--- arping jump on the routed vif ---"
run_in "$SYSFW" "DEV=\$(ip route get ${JUMP_IP} | sed -n 's/.*dev \\([^ ]*\\).*/\\1/p'); echo dev=\$DEV; timeout 5 arping -c2 -I \$DEV ${JUMP_IP} 2>&1; echo arping_exit=\$?"
echo "--- direct TCP 22 from sys-firewall to jump (bypasses forwarding) ---"
run_in "$SYSFW" "timeout 5 bash -c 'echo > /dev/tcp/${JUMP_IP}/22' && echo TCP22_OK || echo TCP22_FAIL"
echo "--- ping jump ---"
run_in "$SYSFW" "timeout 5 ping -n -c2 -W2 ${JUMP_IP} 2>&1; echo ping_exit=\$?"

sec "6. nft chains + counters on sys-net and sys-firewall"
for q in "$SYSNET" "$SYSFW"; do
    for ch in custom-dnat-remotedebug custom-snat-remotedebug custom-forward; do
        echo "--- [$q] $ch ---"
        run_in "$q" "nft list chain ip qubes $ch 2>&1 | grep -vE '^table|^}|^\s*chain' || echo NONE"
    done
done

sec "7. sys-firewall: antispoof / drop counters (is our forwarded pkt being dropped?)"
run_in "$SYSFW" 'nft list ruleset 2>&1 | grep -iE "drop|antispoof|counter packets" | head -30'

sec "8. LIVE conntrack during an SSH attempt"
echo ">>> NOW from your Mac run:  ssh -p ${EXT_PORT} user@<sys-net-physical-ip> <<<"
for i in $(seq "$CAP_SECS" -1 1); do
    printf '\r  waiting %2ds for your SSH attempt...   ' "$i" >&2
    sleep 1
done
printf '\n' >&2
for q in "$SYSNET" "$SYSFW" "$JUMP"; do
    echo "--- [$q] conntrack (dport ${EXT_PORT} or 22) ---"
    run_in "$q" "conntrack -L 2>/dev/null | grep -E 'dport=${EXT_PORT}|dport=22' | head -8 || echo 'no conntrack entries/tool'"
    echo "--- [$q] SYN-RECV / ESTAB sockets to :22 ---"
    run_in "$q" "ss -tan 2>/dev/null | grep -E ':22|:${EXT_PORT}' | grep -vE 'LISTEN' | head -8 || echo 'none'"
done

echo
echo "===== END. Upload $OUT ====="
