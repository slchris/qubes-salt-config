#!/bin/bash
# SPDX-FileCopyrightText: 2026 Chris Su
# SPDX-License-Identifier: MIT
#
# Diagnose the remote-debug port-forward path end to end.
# Run in DOM0. It captures packets on all three hops WHILE you SSH from your
# LAN machine, plus each hop's nft rules / counters / routing, into one file.
#
#   sudo ./scripts/diagnose-netfw.sh
#   # when it says "NOW: from your Mac run: ssh -p 2333 user@<sys-net-ip>",
#   # do that within the countdown.
#
# Then upload /tmp/qsc-netfw.txt, e.g. from a networked qube:
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

run_in() {  # run_in <qube> <cmd...>
    local q="$1"; shift
    qvm-run --pass-io -u root -- "$q" "$*" 2>&1
}

echo "remote-debug netfw diagnose"
echo "hops: $SYSNET -> $SYSFW -> $JUMP   ext_port=$EXT_PORT"

sec "0. resolved IPs (dom0 view)"
echo "sys-firewall ip: $(qvm-prefs "$SYSFW" ip 2>&1)"
echo "mgmt-jump ip:    $(qvm-prefs "$JUMP" ip 2>&1)"
echo "mgmt-jump netvm: $(qvm-prefs "$JUMP" netvm 2>&1)"

sec "1. sshd listen + inbound reachability on jump"
run_in "$JUMP" 'ss -tlnp | grep ":22" || echo NO_SSHD_LISTEN'

sec "2. nft DNAT / SNAT / forward chains (all hops)"
for q in "$SYSNET" "$SYSFW" "$JUMP"; do
    echo "--- [$q] custom-dnat-remotedebug ---"
    run_in "$q" 'nft list chain ip qubes custom-dnat-remotedebug 2>&1 || echo NONE'
    echo "--- [$q] custom-snat-remotedebug ---"
    run_in "$q" 'nft list chain ip qubes custom-snat-remotedebug 2>&1 || echo NONE'
    echo "--- [$q] custom-forward ---"
    run_in "$q" 'nft list chain ip qubes custom-forward 2>&1 || echo NONE'
done

sec "3. routing sanity"
echo "--- sys-firewall route to jump ---"
run_in "$SYSFW" "ip route get $(qvm-prefs "$JUMP" ip 2>/dev/null)"
echo "--- sys-net default uplink ---"
run_in "$SYSNET" 'ip -4 route show default'
echo "--- sys-firewall interfaces ---"
run_in "$SYSFW" 'ip -4 -o addr show | grep -E "vif|eth"'

sec "4. LIVE packet capture on all three hops"
echo "Starting ${CAP_SECS}s capture on all hops."
echo ">>> NOW: from your Mac run:  ssh -p ${EXT_PORT} user@<sys-net-physical-ip> <<<"
echo

# Launch tcpdump on each hop in the background, tagging each line with the qube.
CAPFILE_PREFIX="/tmp/qsc-cap"
for q in "$SYSNET" "$SYSFW" "$JUMP"; do
    ( qvm-run --pass-io -u root -- "$q" \
        "timeout ${CAP_SECS} tcpdump -ni any 'tcp port ${EXT_PORT} or tcp port 22' 2>&1" \
        | sed "s/^/[$q] /" > "${CAPFILE_PREFIX}-$q.txt" 2>&1 ) &
done

# Give the user a visible countdown to trigger the SSH from their Mac.
for i in $(seq "$CAP_SECS" -1 1); do
    printf '\r  capturing... %2ds left (SSH from your Mac now)   ' "$i" >&2
    sleep 1
done
printf '\n' >&2
wait

echo "--- capture: $SYSNET (does the client SYN arrive + get DNAT'd?) ---"
cat "${CAPFILE_PREFIX}-$SYSNET.txt" 2>/dev/null | head -40
echo "--- capture: $SYSFW (does the forwarded SYN arrive + go to jump?) ---"
cat "${CAPFILE_PREFIX}-$SYSFW.txt" 2>/dev/null | head -40
echo "--- capture: $JUMP (does the SYN reach jump + does it SYN-ACK back?) ---"
cat "${CAPFILE_PREFIX}-$JUMP.txt" 2>/dev/null | head -40

sec "5. conntrack for the flow (sys-net + sys-firewall)"
for q in "$SYSNET" "$SYSFW"; do
    echo "--- [$q] conntrack dport $EXT_PORT / 22 ---"
    run_in "$q" "conntrack -L 2>/dev/null | grep -E 'dport=${EXT_PORT}|dport=22' | head -10 || echo 'no conntrack tool/entries'"
done

rm -f "${CAPFILE_PREFIX}"-*.txt 2>/dev/null
echo
echo "===== END. Upload $OUT ====="
