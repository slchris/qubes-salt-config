# SPDX-License-Identifier: MIT
# Copyright 2026 Chris Su
#
# Configure vault qube

# Create password store directory
"pass-directory":
  file.directory:
    - name: /home/user/.password-store
    - user: user
    - group: user
    - mode: 700

# Create KeePassXC config directory
"keepassxc-config-dir":
  file.directory:
    - name: /home/user/.config/keepassxc
    - user: user
    - group: user
    - mode: 700
    - makedirs: True

# KeePassXC settings for security
"keepassxc-config":
  file.managed:
    - name: /home/user/.config/keepassxc/keepassxc.ini
    - user: user
    - group: user
    - mode: 600
    - contents: |
        [General]
        AutoSaveAfterEveryChange=true
        AutoSaveOnExit=true
        BackupBeforeSave=true
        MinimizeOnCopy=true

        [Security]
        ClearClipboardTimeout=30
        LockDatabaseIdle=true
        LockDatabaseIdleSeconds=300
        LockDatabaseMinimize=true
        LockDatabaseScreenLock=true

        [PasswordGenerator]
        Length=20
        LowerCase=true
        UpperCase=true
        Numbers=true
        SpecialChars=true
    - require:
      - file: keepassxc-config-dir

# Create GPG directory for pass
"gpg-directory":
  file.directory:
    - name: /home/user/.gnupg
    - user: user
    - group: user
    - mode: 700
