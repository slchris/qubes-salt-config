#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright 2026 Chris Su
#
# split-gpg2 serves slchris-project from ~/.gnupg/qubes-auto-keyring, not from
# ~/.gnupg. It deletes that directory whenever ~/.gnupg is newer, and the
# replacement has no gpg-agent.conf and no scdaemon.conf. The PIN cache then
# falls back to 10 minutes, and the CanoKey's OpenPGP interface is missed.
#
# Rebuild only when the source directory is newer. Copy the two conf files,
# restart that agent only when the conf changed or the directory was rebuilt,
# then bump the directory mtime so split-gpg2 keeps it.

set -euo pipefail
umask 077

src=/home/user/.gnupg
auto=$src/qubes-auto-keyring
log=$src/split-keyring-refresh.log

if command -v flock >/dev/null 2>&1; then
  exec 9>"$src/.refresh-split-keyring.lock"
  flock -w 30 9
fi

: >"$log"
exec >>"$log" 2>&1

need_rebuild=0
if [ ! -d "$auto" ] || [ "$(stat -c %Y "$src")" -gt "$(stat -c %Y "$auto")" ]; then
  need_rebuild=1
fi

if [ "$need_rebuild" -eq 1 ]; then
  tmp=$(mktemp -d "$src/.qubes-auto-keyring.XXXXXX")
  chmod 700 "$tmp"
  xfer=(gpg --no-armor --batch --pinentry-mode error --with-colons --no-tty --disable-dirmngr)
  if ! "${xfer[@]}" --export-secret-subkeys --homedir "$src" \
      | "${xfer[@]}" --import --homedir "$tmp"; then
    rm -rf "$tmp"
    echo "refresh: subkey export failed"
    exit 1
  fi
  rm -rf "$auto"
  mv "$tmp" "$auto"
  echo "refresh: rebuilt $auto"
fi

changed=0
for name in gpg-agent.conf scdaemon.conf; do
  if [ ! -f "$src/$name" ]; then
    echo "refresh: missing $src/$name"
    exit 1
  fi
  if [ ! -f "$auto/$name" ] || ! cmp -s "$src/$name" "$auto/$name"; then
    cp -a "$src/$name" "$auto/$name"
    chmod 600 "$auto/$name"
    changed=1
  fi
done

# --export-secret-subkeys does not write card stubs into private-keys-v1.d
# unless the card is present. Copy only files GnuPG marks as shadowed, and
# only for grips already on this isolated key. That leaves the certify
# primary, which has no passphrase, in ~/.gnupg.
copied=0
dst_priv=$auto/private-keys-v1.d
mkdir -p "$dst_priv"
chmod 700 "$dst_priv"
while IFS= read -r grip; do
  [ -n "$grip" ] || continue
  src_key=$src/private-keys-v1.d/$grip.key
  dst_key=$dst_priv/$grip.key
  if [ -f "$dst_key" ] || [ ! -f "$src_key" ]; then
    continue
  fi
  if grep -q -a -- shadowed "$src_key"; then
    cp -a "$src_key" "$dst_key"
    chmod 600 "$dst_key"
    copied=$((copied + 1))
  fi
done < <(gpg --homedir "$auto" --pinentry-mode error --with-keygrip --list-keys --with-colons \
  | awk -F: '$1 == "grp" && $10 != "" { print $10 }')
echo "refresh: copied $copied card stubs"

if [ "$need_rebuild" -eq 1 ] || [ "$changed" -eq 1 ] || [ "$copied" -gt 0 ]; then
  gpgconf --homedir "$auto" --kill gpg-agent || true
  echo "refresh: reloaded isolated agent"
fi

touch "$auto"
chmod 700 "$auto"
echo "refresh: ok"
