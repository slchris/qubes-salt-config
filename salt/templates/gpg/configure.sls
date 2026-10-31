# SPDX-License-Identifier: MIT
# Copyright 2026 Chris Su
#
# Configure GPG in a profile's gpg qube. sshcontrol and the split-gpg2
# client list come from the cfg.profiles entry whose gpg qube is this one.
# Any other qube keeps the generic agent settings and does not receive
# another profile's keygrip.

{% from 'config.jinja' import cfg with context %}
{% set found = namespace(profile=None, name='') %}
{% for name, profile in cfg.profiles.items() %}
{% if profile.gpg == grains['nodename'] %}
{% set found.profile = profile %}
{% set found.name = name %}
{% endif %}
{% endfor %}

# Create GPG directory
"gpg-directory":
  file.directory:
    - name: /home/user/.gnupg
    - user: user
    - group: user
    - mode: 700

# GPG agent configuration
"gpg-agent-conf":
  file.managed:
    - name: /home/user/.gnupg/gpg-agent.conf
    - user: user
    - group: user
    - mode: 600
    - contents: |
        # Headless git and SSH. One PIN entry stays cached until gpg-agent
        # or this qube restarts. 31536000 seconds is 365 days. The idle
        # timer resets on use. The card Signature PIN flag has to be
        # "not forced", or each signature asks again and skips this cache.
        default-cache-ttl 31536000
        max-cache-ttl 31536000
        default-cache-ttl-ssh 31536000
        max-cache-ttl-ssh 31536000
        pinentry-program /usr/bin/pinentry-gtk-2
        enable-ssh-support
    - require:
      - file: gpg-directory

# GPG configuration
"gpg-conf":
  file.managed:
    - name: /home/user/.gnupg/gpg.conf
    - user: user
    - group: user
    - mode: 600
    - contents: |
        # GPG Configuration
        # Use strong algorithms
        personal-cipher-preferences AES256 AES192 AES
        personal-digest-preferences SHA512 SHA384 SHA256
        personal-compress-preferences ZLIB BZIP2 ZIP Uncompressed
        default-preference-list SHA512 SHA384 SHA256 AES256 AES192 AES ZLIB BZIP2 ZIP Uncompressed
        cert-digest-algo SHA512
        s2k-digest-algo SHA512
        s2k-cipher-algo AES256
        charset utf-8
        # Show fingerprints
        keyid-format 0xlong
        with-fingerprint
        # Display validity
        list-options show-uid-validity
        verify-options show-uid-validity
        # No comments or version in output
        no-comments
        no-emit-version
    - require:
      - file: gpg-directory

# CanoKey's OpenPGP interface is not interface 0. GnuPG's built-in CCID
# driver stops there and reports "No such device". pcscd reads the card.
"gpg-scdaemon-conf":
  file.managed:
    - name: /home/user/.gnupg/scdaemon.conf
    - user: user
    - group: user
    - mode: '0600'
    - contents: |
        disable-ccid
        pcsc-shared
    - require:
      - file: gpg-directory

# Authentication subkey on the CanoKey only. The sign and encrypt subkeys
# are not offered to SSH. Another profile's keygrip is not this qube's key.
{% if found.profile %}
"gpg-sshcontrol":
  file.managed:
    - name: /home/user/.gnupg/sshcontrol
    - user: user
    - group: user
    - mode: '0600'
    - contents: |
        {{ found.profile.ssh_keygrip }}
    - require:
      - file: gpg-directory

# split-gpg2's default is a zenity question on every signature, and that
# question times out after 30 seconds. The profile's project AppVM is
# headless. The card PIN is the remaining check, and gpg-agent caches it.
"gpg-split-autoaccept":
  file.managed:
    - name: /home/user/.config/qubes-split-gpg2/qubes-split-gpg2.conf
    - user: user
    - group: user
    - mode: '0600'
    - makedirs: True
    - dir_mode: '0700'
    - contents: |
        # Headless {{ found.profile.project }}. Do not pop a zenity question per operation.
        # Policy still allows only this profile. The card PIN is cached by gpg-agent.
        [DEFAULT]
        pksign_autoaccept = yes
        pkdecrypt_autoaccept = yes

        [client:{{ found.profile.project }}]
        pksign_autoaccept = yes
        pkdecrypt_autoaccept = yes

        [client:{{ found.profile.pass }}]
        pksign_autoaccept = yes
        pkdecrypt_autoaccept = yes
{% endif %}

# Copies gpg-agent.conf and scdaemon.conf into the isolated keyring that
# split-gpg2 actually uses, and rebuilds that keyring when ~/.gnupg is newer.
"gpg-refresh-split-keyring":
  file.managed:
    - name: /home/user/.gnupg/refresh-split-keyring.sh
    - source: salt://templates/gpg/files/refresh-split-keyring.sh
    - user: user
    - group: user
    - mode: '0700'
    - require:
      - file: gpg-directory

# The package script at /etc/qubes-rpc/qubes.Gpg2 is replaced on every AppVM
# boot. The canonical copy lives under /rw and is bind-mounted back.
"gpg-split-rpc":
  file.managed:
    - name: /rw/bind-dirs/etc/qubes-rpc/qubes.Gpg2
    - source: salt://templates/gpg/files/qubes.Gpg2
    - makedirs: True
    - user: root
    - group: root
    - mode: '0755'

"gpg-split-persist-mechanism":
  cmd.run:
    - name: |
        if [ -f /var/run/qubes-service/custom-persist ]; then
          echo "custom-persist is enabled on this qube: /rw/config/qubes-bind-dirs.d is ignored." >&2
          exit 1
        fi
    - runas: root

"gpg-split-rpc-bind":
  file.managed:
    - name: /rw/config/qubes-bind-dirs.d/50_split_gpg2.conf
    - makedirs: True
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        # Managed by templates.gpg.configure
        binds+=( '/etc/qubes-rpc/qubes.Gpg2' )
    - require:
      - cmd: gpg-split-persist-mechanism

# This boot. bind-dirs.sh only reads the conf above at the next start.
"gpg-split-rpc-activate":
  cmd.run:
    - name: |
        set -eu
        target=/etc/qubes-rpc/qubes.Gpg2
        mountpoint -q "$target" || mount --bind /rw/bind-dirs/etc/qubes-rpc/qubes.Gpg2 "$target"
    - runas: root
    - require:
      - file: gpg-split-rpc
      - file: gpg-split-rpc-bind

# Build the isolated keyring now, and drop the main agent so SSH reads the
# new cache lifetime. Do not kill the isolated agent on later calls; the
# refresh script does that only when the conf or the keyring changed.
"gpg-split-keyring-now":
  cmd.run:
    - name: |
        set -eu
        /home/user/.gnupg/refresh-split-keyring.sh
        gpgconf --homedir /home/user/.gnupg --kill gpg-agent || true
    - runas: user
    - require:
      - file: gpg-agent-conf
      - file: gpg-scdaemon-conf
      - file: gpg-refresh-split-keyring
      - file: gpg-split-autoaccept
