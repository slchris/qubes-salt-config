# SPDX-License-Identifier: MIT
# Copyright 2026 Chris Su
#
# Configure GPG in gpg qube

{% set user = salt['pillar.get']('user', {}) %}

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
        # GPG Agent Configuration
        default-cache-ttl 600
        max-cache-ttl 7200
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
