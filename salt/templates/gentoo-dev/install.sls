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

# Sync the Portage tree so atoms resolve and are up to date.
"gentoo-dev-sync-portage":
  cmd.run:
    - name: emerge --sync --quiet
    - unless: test -d /var/db/repos/gentoo/metadata

# Core ebuild / overlay development tooling.
"gentoo-dev-install-tools":
  pkg.installed:
    - require:
      - cmd: gentoo-dev-sync-portage
    - pkgs:
      # Networking so Qubes proxy/DNS work in the template's derived qubes.
      - app-emulation/qubes-core-agent-networking
      # Version control
      - dev-vcs/git
      # Ebuild authoring and QA
      - app-portage/gentoolkit         # equery, euse, revdep-rebuild, ...
      - app-portage/eix                # fast package index/search
      - app-portage/portage-utils      # qatom, qlist, qmerge, ...
      - app-portage/repoman            # ebuild QA / policy checker
      - app-portage/pkgcheck           # modern ebuild linter (replaces repoman QA)
      - app-portage/flaggie            # manage USE flags
      - app-portage/layman             # overlay management (legacy but common)
      - app-eselect/eselect-repository # add/manage ebuild repositories
      # General dev utilities
      - app-editors/vim
      - app-editors/neovim
      - app-shells/bash-completion
      - app-misc/tmux
      - sys-process/htop
      - app-misc/jq
      - sys-apps/ripgrep

{% endif %}
