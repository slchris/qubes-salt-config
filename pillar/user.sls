# SPDX-FileCopyrightText: 2026 Chris Su
# SPDX-License-Identifier: MIT
#
# User configuration pillar
# Edit these values to customize your Qubes OS environment

# =============================================================================
# Template Version Configuration
# =============================================================================
# Change these values to upgrade to newer template versions.
# After changing, rerun the formulas to upgrade:
#   sudo qubesctl state.apply <formula>.clone
#
# WARNING: Upgrading templates will clone new templates.
# The old template qubes will remain. Use Qube Manager to rename
# old templates with -old suffix before upgrade.

qvm:
  debian:
    # Debian template version (e.g., 13, 14)
    version: "13"
    repo: "qubes-templates-itl"
  fedora:
    # Fedora template version (e.g., 43, 44)
    version: "43"
    repo: "qubes-templates-itl"
  # Whonix configuration (if using Whonix templates)
  whonix:
    version: "17"
    repo: "qubes-templates-community"

  # ===========================================================================
  # Mirror configuration (OPT-IN)
  # ===========================================================================
  # If the default ITL/upstream sources are slow or unreachable (e.g. behind a
  # slow link or in a region far from the CDN), point Qubes at a faster mirror.
  #
  # This is entirely optional and OFF by default. Enable it and fill in the
  # base URLs, then apply with scripts/qubes-mirror.sh (see docs/mirror.md).
  # Leave `enabled: false` (or blank URLs) to keep the official sources.
  #
  # Only set the layers you actually need; blank/absent URLs are left untouched.
  #
  # The defaults below use Tsinghua TUNA (mirrors.tuna.tsinghua.edu.cn), which
  # is verified to carry the Qubes r4.3 repos under /qubesos/ and is fast from
  # mainland China. If you are outside China, mirrors.kernel.org (a global CDN)
  # is usually a better choice — swap the URLs below. Keep `enabled: false` to
  # stay on the official ITL source.
  #
  # Verified working (2026): TUNA base for Qubes is /qubesos/repo/yum (note the
  # path is "qubesos", not "qubes").
  mirror:
    enabled: false
    # Layer 1 — Qubes template download source (qvm-template / qubes-dom0-update
    # qubes-template-*). This is the one that stalls when it can't reach ITL.
    templates_baseurl: "https://mirrors.tuna.tsinghua.edu.cn/qubesos/repo/yum"
    # Layer 2 — in-template OS package sources.
    debian_baseurl: "https://mirrors.tuna.tsinghua.edu.cn/debian"
    fedora_baseurl: "https://mirrors.tuna.tsinghua.edu.cn/fedora/linux"
    # Layer 3 — dom0 update source (Qubes' own packages). Optional; higher risk,
    # change only if dom0 updates are also unreachably slow.
    dom0_baseurl: "https://mirrors.tuna.tsinghua.edu.cn/qubesos/repo/yum"

# =============================================================================
# Per-Qube Configuration
# =============================================================================
# Git configuration is per-qube, not per-template.
# Add entries for each AppVM that needs git configured.
#
# Usage:
#   sudo qubesctl --skip-dom0 --targets=dev state.apply dotfiles.git

qubes:
  # Example: dev AppVM
  dev:
    git:
      name: "Chris Su"
      email: "chris@lesscrowds.org"
      # signingkey: "ABCD1234EFGH5678"

  # Example: work AppVM with different identity
  # work:
  #   git:
  #     name: "Chris Su"
  #     email: "chris@company.com"

# =============================================================================
# Shell Configuration (for templates)
# =============================================================================

user:
  shell:
    # Default shell: bash, zsh
    default: bash
    # Timezone
    timezone: "Asia/Shanghai"
    # Locale
    locale: "en_US.UTF-8"

# =============================================================================
# Global Qubes Preferences
# =============================================================================
# These settings control dom0 global preferences
# Apply with: sudo qubesctl state.apply dom0.prefs

global:
  # Default template for new qubes
  # default_template: debian-13-minimal
  # Default NetVM
  # default_netvm: sys-firewall
  # Default disposable VM
  # default_dispvm: dvm-tools
  # Clock VM
  # clockvm: sys-net
  # Update VM
  # updatevm: sys-firewall
