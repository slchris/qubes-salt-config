{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Configure the gentoo-dev qube for ebuild/overlay work:
  - a local personal overlay under /home/user/overlay
  - a repos.conf entry pointing at it
  - basic portage make.conf ergonomics for a dev box

Runs inside the target qube (gentoo-dev), not dom0.
#}

{% if grains['nodename'] != 'dom0' %}

# Personal overlay directory (persists in the AppVM home).
"gentoo-dev-overlay-dir":
  file.directory:
    - name: /home/user/overlay/metadata
    - user: user
    - group: user
    - makedirs: True
    - mode: '0755'

"gentoo-dev-overlay-layout":
  file.managed:
    - name: /home/user/overlay/metadata/layout.conf
    - user: user
    - group: user
    - mode: '0644'
    - contents: |
        masters = gentoo
        thin-manifests = true
    - require:
      - file: gentoo-dev-overlay-dir

"gentoo-dev-overlay-profiles":
  file.directory:
    - name: /home/user/overlay/profiles
    - user: user
    - group: user
    - mode: '0755'
    - require:
      - file: gentoo-dev-overlay-dir

"gentoo-dev-overlay-repo-name":
  file.managed:
    - name: /home/user/overlay/profiles/repo_name
    - user: user
    - group: user
    - mode: '0644'
    - contents: |
        localdev
    - require:
      - file: gentoo-dev-overlay-profiles

# Register the overlay with Portage (system-wide repos.conf).
"gentoo-dev-repos-conf":
  file.managed:
    - name: /etc/portage/repos.conf/localdev.conf
    - makedirs: True
    - mode: '0644'
    - contents: |
        [localdev]
        location = /home/user/overlay
        masters = gentoo
        auto-sync = false
    - require:
      - file: gentoo-dev-overlay-repo-name

{% endif %}
