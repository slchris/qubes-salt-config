#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright 2026 Chris Su
#
# Check a qube's public egress before assigning that exit to a project.
# Runs in dom0; the HTTP request is made from the qube, so the service sees
# the qube's exit IP, not dom0's. Reports the egress IP, location, ASN,
# datacenter/VPN/Tor flags, and abuse deductions.
#
# The score is a third-party heuristic, not an Anthropic decision. Every
# datacenter/VPN exit loses the datacenter points; use this to compare
# candidates before a project uses one, not as a guarantee that an account
# will not be restricted.
#
# Usage: scripts/check-exit.sh <qube> [min-purity]
#
#   min-purity  Exit non-zero when the purity score is below this
#               (default: 0, i.e. only report).
#
# Examples:
#   scripts/check-exit.sh emilyjace-project
#   scripts/check-exit.sh emilyjace-project 55

set -eu

CHECK_URL="${CHECK_URL:-https://fuck-claude.vercel.app/api/ip?format=json}"

usage() {
    echo "Usage: ${0##*/} <qube> [min-purity]"
    echo ""
    echo "Check the public egress and IP-purity signals of a running qube."
    echo ""
    echo "Arguments:"
    echo "  qube        Qube whose exit should be tested (must be running)"
    echo "  min-purity  Fail when the purity score is below this (default: 0)"
    echo ""
    echo "Environment:"
    echo "  CHECK_URL   Override the purity-check endpoint"
}

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    usage >&2
    exit 2
fi

qube=$1
min=${2:-0}

case "$min" in
    *[!0-9]*|"")
        echo "check-exit: min-purity must be a non-negative integer" >&2
        exit 2
        ;;
esac

if ! qvm-check "$qube" >/dev/null 2>&1; then
    echo "check-exit: $qube is not running" >&2
    exit 1
fi

json=$(qvm-run --pass-io -- "$qube" \
    "curl -sS -m 25 '$CHECK_URL'") || {
    echo "check-exit: no answer from the purity endpoint via $qube" >&2
    echo "check-exit: check the qube's netvm and DNS, then retry" >&2
    exit 1
}

printf '%s\n' "$json" | MIN="$min" QUBE="$qube" python3 -c '
import json
import os
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit("check-exit: the endpoint did not return JSON")

qube = os.environ["QUBE"]
minimum = int(os.environ["MIN"])
network = data.get("network") or {}
geo = data.get("geo") or {}
flags = data.get("flags") or {}
deductions = data.get("deductions") or []

print("qube:    {}".format(qube))
print("ip:      {}".format(data.get("ip")))
print("purity:  {}/100 ({})".format(data.get("purity"), data.get("band")))
print("geo:     {}, {}, {}".format(geo.get("city"), geo.get("region"), geo.get("countryCode")))
print("network: {} {} ({})".format(network.get("asn"), network.get("org"), network.get("type")))
print("flags:   " + ", ".join("{}={}".format(key, "unknown" if value is None else value) for key, value in flags.items()))

for item in deductions:
    print("  - {}: {} ({})".format(item.get("label"), item.get("points"), item.get("source")))

score = data.get("purity")
if score is None:
    sys.exit("check-exit: the endpoint returned no purity score")
if score < minimum:
    print("verdict: BELOW min-purity {}".format(minimum))
    sys.exit(1)
print("verdict: ok (min-purity {})".format(minimum))
'
