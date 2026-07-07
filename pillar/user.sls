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
  # Qubes 4.3 ships Whonix 18 (templates: whonix-gateway-18 /
  # whonix-workstation-18). Note the version is NOT part of a single template
  # name like debian-13 — it applies to both the gateway and workstation.
  whonix:
    version: "18"
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
    enabled: true
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
# Remote Debug (OPT-IN) — SSH into a jump qube to drive this machine
# =============================================================================
# Deploy with: sudo qubesctl state.apply mgmt.remote-debug
# See docs/remote-debug.md. This is a DEVELOPMENT convenience with a real
# security cost — read the security section before enabling.
remote_debug:
  # Jump qube: a dedicated networked AppVM that terminates SSH.
  qube: "mgmt-jump"
  template: "debian-13-minimal"
  label: "red"
  # SSH public key(s) allowed to log in (your dev machine). One per list item.
  authorized_keys:
    # yamllint disable-line rule:line-length
    - "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDFBtGrp0fsGhJ2mCiDtGnOWHbmAscWMnfPwkcvmbj6C2sotpstfSFPd63bzME8shQZYJmNJp9aS5VdW9L1bTpfCHkTm/6l9bOT2r2hsLMUxHpd8FK+k7qiUGvpuQu2QAy+q4MD93Mvna0rwwwNEd4TPMVzi7S8V5wPuzOK4aU/QIW8UwnWKRNFGokiCl3ySOd6NFxpvsp259N0KKL01Xc71QBy5BzrKPOco+1wlFqrtUrSQt9TsbtLrj2yYY+1RcD6JJlt2OoCJs0WHEXbyYw30PdNZVB4oJF1lzjAZTE9miyxxGDDixygCLBHcspVcj62T/5QYOP9QG+vU0y0wlXyYE4g6SI+UUJeNu0ZVpi1APzlA4TpxyAqLGQIzfBeyEAEObFZlENhZ/LV5ZDleYgD/wkTONm8aRq6ScmUdZPlel3z9wOfbr2TAuSxL93HoxqamQG7wGHD5iBpwn/gysr/gEkURZz/umFqep/KNi3gIpwcP9iBsbvBV6bUeVg7M0JrxYp+MCALY339Haw1b0yfqdxbL2bNl30D6IQOquv5IrTiMnYwKBK37tdhdwTG12Lj03FGxSNkIFLy5D+ZLBXdFtPhOXtwOOnDQ6K9pJ+2bURLDjVc/bIEZ6w22xj+tjykciTsUg4lHsQzvwkHA1xd4UwEyJXe7FPOdtQ9eOJy5w== cardno:11_023_204"
  # dom0 access mode reachable from the jump qube:
  #   "whitelist" — a qrexec service that only runs an allowed set of commands
  #                 (salt + qvm-create/run/copy/prefs + dom0-update). Safer.
  #   "shell"     — qubes.VMShell: ANY dom0 command. Convenient, but a
  #                 compromise of the jump qube compromises the whole system.
  dom0_access: "whitelist"
  # Network exposure so your LAN machine can reach the jump qube's sshd:
  #   "portforward" — DNAT sys-net(physical IP):<port> -> sys-firewall -> jump:22
  #   "none"        — no forwarding installed (use a mesh VPN yourself, or the
  #                   Qubes console); sshd still runs in the jump qube.
  network: "portforward"
  ssh_port: 2333            # external port on sys-net's physical IP
  netvm: "sys-firewall"
  # LAN subnet allowed to reach the forwarded port (source match in sys-net's
  # nftables DNAT rule). Narrow this to your real subnet.
  lan_subnet: "10.42.0.0/24"

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
