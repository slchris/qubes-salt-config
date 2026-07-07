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
    # Fedora template version (e.g., 42, 43)
    version: "42"
    repo: "qubes-templates-itl"
  # Whonix configuration (if using Whonix templates)
  whonix:
    version: "17"
    repo: "qubes-templates-community"

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
