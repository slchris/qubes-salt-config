#!/bin/bash
# SPDX-FileCopyrightText: 2026 Chris Su
# SPDX-License-Identifier: MIT
#
# Diagnose why Salt pillar / states are not loading in dom0.
# Collects everything relevant into one file you can upload to a pastebin.
#
# Run in DOM0:
#   sudo ./scripts/diagnose.sh
# then upload /tmp/qsc-diag.txt, e.g. from a networked qube:
#   cat /tmp/qsc-diag.txt | qvm-run --pass-io <netqube> \
#     'curl -s -X POST --data-binary @- "https://pb.plz.ac/"'

OUT="/tmp/qsc-diag.txt"
PILLAR_DIR="/srv/pillar/slchris"
SALT_DIR="/srv/salt/slchris"

exec > "$OUT" 2>&1

sec() { echo; echo "===== $1 ====="; }

echo "qubes-salt-config diagnose  (host=$(hostname))"

sec "1. minion.d config files present"
ls -la /etc/salt/minion.d/ 2>&1

sec "2. our slchris.conf as deployed (may differ from repo)"
cat /etc/salt/minion.d/slchris.conf 2>&1

sec "3. salt effective file_roots + pillar_roots (what salt ACTUALLY uses)"
echo "-- file_roots --"
salt-call --local config.get file_roots 2>&1
echo "-- pillar_roots --"
salt-call --local config.get pillar_roots 2>&1
echo "-- pillar_source_merging_strategy --"
salt-call --local config.get pillar_source_merging_strategy 2>&1

sec "4. our pillar files on disk"
ls -la "$PILLAR_DIR" 2>&1
echo "-- top.sls --"
cat "$PILLAR_DIR/top.sls" 2>&1
echo "-- user.sls top-level keys --"
grep -nE '^[a-zA-Z_]+:' "$PILLAR_DIR/user.sls" 2>&1
echo "-- user.sls: mirror enabled + remote_debug lines --"
grep -nE 'enabled:|^remote_debug:|qube:' "$PILLAR_DIR/user.sls" 2>&1
echo "-- PROOF the deployed file is the NEW version (remote_debug present?) --"
grep -c 'remote_debug' "$PILLAR_DIR/user.sls" 2>&1
echo "-- file mtime (recent = freshly setup) --"
stat -c '%y  %n' "$PILLAR_DIR/user.sls" 2>&1 || ls -l "$PILLAR_DIR/user.sls"

sec "4b. ALL pillar_roots dirs + every top.sls under them (top conflict?)"
for d in $(salt-call --local config.get pillar_roots --out=json 2>/dev/null | grep -oE '/[^",]+'); do
  echo "-- pillar_root: $d --"
  ls -la "$d" 2>&1 | head
  [ -f "$d/top.sls" ] && { echo "   top.sls:"; sed 's/^/     /' "$d/top.sls"; }
done
echo "-- Qubes-shipped pillar top(s) that may win over ours --"
ls -la /srv/pillar/base/ 2>&1 | head
cat /srv/pillar/base/top.sls 2>&1 | head

sec "5. what salt actually LOADS for pillar (the decisive test)"
echo "-- pillar.get qvm:mirror:enabled --"
qubesctl pillar.get qvm:mirror:enabled 2>&1
echo "-- pillar.get remote_debug:qube --"
qubesctl pillar.get remote_debug:qube 2>&1
echo "-- pillar.get qvm:debian:version (existing key, sanity) --"
qubesctl pillar.get qvm:debian:version 2>&1

sec "6. pillar render errors (salt-call, verbose)"
salt-call --local pillar.items 2>&1 | grep -iA6 '_error\|render\|Traceback\|SLS\|Jinja\|Unable\|failed' | head -60

sec "7. full pillar top-level keys salt sees (is our data there at all?)"
salt-call --local pillar.items --out=yaml 2>&1 | grep -E '^[a-zA-Z_]+:' | head -40

sec "8. our state on disk + can salt find the mirror sls?"
ls -la "$SALT_DIR/mgmt/mirror/" 2>&1
echo "-- head of deployed dom0.sls (is it the fixed version?) --"
sed -n '18,35p' "$SALT_DIR/mgmt/mirror/dom0.sls" 2>&1

sec "9. salt/minion versions"
salt-call --version 2>&1
qubesctl --version 2>&1

echo
echo "===== END. Upload $OUT ====="
