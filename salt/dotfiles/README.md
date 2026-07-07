# dotfiles

User configuration files (dotfiles) for Qubes OS qubes.

## Table of Contents

*   [Description](#description)
*   [Installation](#installation)
*   [Configuration](#configuration)
*   [Usage](#usage)

## Description

Manages user dotfiles including:

| State | Description | Target |
|-------|-------------|--------|
| git.sls | Git configuration (name, email, signing key) | **AppVM** (per-qube) |
| shell.sls | Bash configuration, aliases, and environment | Template or AppVM |
| init.sls | Apply all dotfiles at once | AppVM |

## Installation

### Git Configuration (Per-AppVM)

Git config is applied to specific AppVMs, not templates:

```sh
# Apply to a specific AppVM
sudo qubesctl --skip-dom0 --targets=dev state.apply dotfiles.git
```

### Shell Configuration (Template or AppVM)

```sh
sudo qubesctl --skip-dom0 --targets=tpl-dev state.apply dotfiles.shell
```

## Configuration

Edit `/srv/user_pillar/user.sls`:

### Per-Qube Git Configuration

```yaml
qubes:
  # Git config for slchris-project AppVM
  slchris-project:
    git:
      name: "Chris Su"
      email: "chris@lesscrowds.org"
      # signingkey: "ABCD1234"  # Optional GPG key

  # Different identity for work AppVM
  work:
    git:
      name: "Chris Su"
      email: "chris@company.com"
```

### Shell Configuration (for templates)

```yaml
user:
  shell:
    default: bash
    timezone: "Asia/Shanghai"
    locale: "en_US.UTF-8"
```

After editing, refresh pillar data:

```sh
sudo qubesctl saltutil.refresh_pillar
```

## Usage

1.  Edit `/srv/user_pillar/user.sls` with your configuration
2.  Add entries under `qubes:` for each AppVM that needs git
3.  Apply the state to your AppVMs

### Files Created

| File | Description |
|------|-------------|
| ~/.gitconfig | Git configuration (AppVM only) |
| ~/.bashrc | Bash configuration |
| ~/.profile | Shell profile |
| ~/.local/bin/ | User binary directory |

## License

SPDX-License-Identifier: MIT

Copyright 2026 Chris Su
