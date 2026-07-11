{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Install ebuild / package-development tooling in tpl-gentoo-dev.

Gentoo uses Portage, so Salt's pkg state maps to emerge and packages are named
by their atom (category/name). This installs the toolchain needed to write,
test and maintain ebuilds and overlays.

Note: emerge builds from source; the first sync + install can take a long time.
#}

{% if grains['nodename'] != 'dom0' %}

{% from 'config.jinja' import cfg with context -%}
{% set overlay_uri = cfg.qvm.get('gentoo', {}).get('overlay_uri', 'https://github.com/slchris/qubes-gentoo.git') -%}
{% set profile = cfg.qvm.get('gentoo', {}).get('profile', 'default/linux/amd64/23.0/systemd') -%}

# The prebuilt gentoo-minimal base carries an OUTDATED Portage profile (17.1) and
# the UPSTREAM fepitre qubes overlay (R4.2) in its rootfs — both leftover from how
# the community template was assembled. On the current tree that profile is
# deprecated and the 4.2 overlay ebuilds fail the depend phase, which breaks every
# emerge. Realign the dev box to the profile we build with (23.0) and OUR overlay
# (slchris/qubes-gentoo, R4.3, the one we bump) before anything else.
"gentoo-dev-set-profile":
  cmd.run:
    - name: eselect profile set {{ profile }}
    - unless: readlink /etc/portage/make.profile | grep -q '{{ profile }}$'

"gentoo-dev-swap-overlay":
  cmd.run:
    - name: |
        rm -rf /var/db/repos/qubes
        git clone --quiet {{ overlay_uri }} /var/db/repos/qubes
        mkdir -p /etc/portage/repos.conf
        printf '[qubes]\nlocation = /var/db/repos/qubes\nsync-uri = {{ overlay_uri }}\nsync-type = git\nsync-git-verify-commit-signature = false\nauto-sync = false\n' > /etc/portage/repos.conf/qubes.conf
    - unless: test -f /var/db/repos/qubes/app-emulation/qubes-core-agent-linux/qubes-core-agent-linux-4.3.46.ebuild
    - require:
      - cmd: gentoo-dev-set-profile

# Sync the Portage tree so atoms resolve and are up to date. Prefer
# emerge-webrsync (unpacks the HTTP snapshot — no rsync daemon, no pty, works
# through the China mirror configured in make.conf/repos.conf) and fall back to
# emerge --sync. Skip if the tree already has metadata.
"gentoo-dev-sync-portage":
  cmd.run:
    - name: emerge-webrsync --quiet || emerge --sync --quiet
    - unless: test -d /var/db/repos/gentoo/metadata/md5-cache
    - require:
      - cmd: gentoo-dev-swap-overlay

# Bring the whole system in line with the (now current) profile before adding
# tools — the base packages are a build-time snapshot and newer masks/slots would
# otherwise block the toolchain with slot conflicts.
"gentoo-dev-world-update":
  cmd.run:
    - name: emerge -uDN --quiet-build=y --keep-going=y --with-bdeps=y @world
    - require:
      - cmd: gentoo-dev-sync-portage

# Core ebuild / overlay development tooling.
"gentoo-dev-install-tools":
  pkg.installed:
    - require:
      - cmd: gentoo-dev-world-update
    - pkgs:
      # Version control
      - dev-vcs/git
      # Ebuild authoring and QA
      - app-portage/gentoolkit         # equery, euse, revdep-rebuild, ...
      - app-portage/eix                # fast package index/search
      - app-portage/portage-utils      # qatom, qlist, qmerge, ...
      - dev-util/pkgcheck              # modern ebuild linter (pkgcheck+pkgdev)
      - dev-util/pkgdev                # pkgdev manifest, commit helpers
      - app-portage/flaggie            # manage USE flags
      - app-eselect/eselect-repository # add/manage ebuild repositories
      # General dev utilities
      - app-editors/vim
      - app-editors/neovim
      - app-shells/bash-completion
      - app-misc/tmux
      - sys-process/htop
      - app-misc/jq

{% endif %}
