#!/bin/bash
# SPDX-FileCopyrightText: 2026 Chris Su
# SPDX-License-Identifier: MIT
#
# One-shot diagnosis of the remote-debug port-forward path, with PER-HOP PASS/
# FAIL verdicts so the break point is obvious. Run in DOM0.
#
#   sudo ./scripts/diagnose-netfw.sh
#   # when it prints the SSH prompt, run from your Mac:
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
JUMP_GW="$(run_in "$JUMP" 'qubesdb-read /qubes-gateway 2>/dev/null')"

echo "remote-debug netfw diagnose (per-hop verdicts)"
echo "hops: $SYSNET -> $SYSFW -> $JUMP   ext_port=$EXT_PORT"
echo "sys-firewall ip=$FW_IP   mgmt-jump ip=$JUMP_IP   jump gw=$JUMP_GW"

# ---- helper: a shell TCP connect test from inside a qube ----
tcp_test() { # tcp_test <from-qube> <ip> <port>
    run_in "$1" "timeout 5 bash -c 'echo > /dev/tcp/$2/$3' >/dev/null 2>&1 && echo PASS || echo FAIL"
}

sec "A. jump network health (should be UP with an IP now)"
run_in "$JUMP" 'ip -o addr show | grep -v " lo "'
echo "default route: $(run_in "$JUMP" 'ip route show default')"
echo "VERDICT jump has IP $JUMP_IP: $(run_in "$JUMP" "ip -o addr show | grep -q '$JUMP_IP' && echo PASS || echo FAIL")"

sec "B. jump -> its gateway (basic outbound)"
echo "ping gw $JUMP_GW: $(run_in "$JUMP" "timeout 5 ping -n -c2 -W2 $JUMP_GW >/dev/null 2>&1 && echo PASS || echo FAIL")"

sec "C. jump sshd reachable FROM sys-firewall (the last forward hop)"
echo "sys-firewall -> jump:22  TCP connect: $(tcp_test "$SYSFW" "$JUMP_IP" 22)"
echo "sys-firewall -> jump      ping:        $(run_in "$SYSFW" "timeout 5 ping -n -c2 -W2 $JUMP_IP >/dev/null 2>&1 && echo PASS || echo FAIL")"
echo "--- sys-firewall neigh entry for jump (REACHABLE vs FAILED) ---"
run_in "$SYSFW" "ip neigh | grep $JUMP_IP || echo 'no neigh entry'"

sec "D. jump sshd reachable FROM sys-net (skips a hop, sanity) "
echo "sys-net -> jump:22 TCP: $(tcp_test "$SYSNET" "$JUMP_IP" 22)  (expected FAIL: no route; informational)"

sec "E. jump: nft input policy (would inbound be dropped here?)"
run_in "$JUMP" 'nft list ruleset 2>&1 | grep -iE "hook input|policy|custom-input|dport 22|counter" | head -20 || echo "no nft ruleset (input not filtered)"'

sec "F. forward-path nft chains + counters (both hops)"
for q in "$SYSNET" "$SYSFW"; do
    for ch in custom-dnat-remotedebug custom-snat-remotedebug custom-forward; do
        echo "--- [$q] $ch ---"
        run_in "$q" "nft list chain ip qubes $ch 2>&1 | grep -E 'counter|masquerade|dnat|accept' || echo NONE"
    done
done

sec "G. sys-firewall drop/antispoof counters"
run_in "$SYSFW" 'nft list ruleset 2>&1 | grep -iE "counter packets [1-9].* drop|antispoof" | head -20 || echo "no nonzero drops"'

sec "H. LIVE conntrack during an SSH attempt"
echo ">>> NOW from your Mac run:  ssh -p ${EXT_PORT} user@<sys-net-physical-ip> <<<"
for i in $(seq "$CAP_SECS" -1 1); do
    printf '\r  waiting %2ds for your SSH attempt...   ' "$i" >&2
    sleep 1
done
printf '\n' >&2
for q in "$SYSNET" "$SYSFW" "$JUMP"; do
    echo "--- [$q] conntrack (dport ${EXT_PORT}/22) ---"
    run_in "$q" "conntrack -L 2>/dev/null | grep -E 'dport=${EXT_PORT}|dport=22' | head -6 || echo 'none'"
    echo "--- [$q] non-LISTEN sockets on :22/:${EXT_PORT} ---"
    run_in "$q" "ss -tan 2>/dev/null | grep -E ':22|:${EXT_PORT}' | grep -v LISTEN | head -6 || echo 'none'"
done

echo
echo "===== READ ME ====="
echo "If C (sys-firewall->jump:22) is PASS but the Mac still can't connect, the"
echo "break is in sys-net<->sys-firewall forwarding/NAT. If C is FAIL, the break"
echo "is the last hop (sys-firewall->jump) — check E (input drop) and C's neigh."
echo "===== END. Upload $OUT ====="
