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

Edit `salt/config.jinja` (on the machine: `/srv/salt/slchris/config.jinja`). It
is a Jinja dict keyed under `cfg`.

### Per-Qube Git Configuration

```jinja
"qubes": {
  # Git config per AppVM
  "dev": {"git": {"name": "Chris Su", "email": "chris@lesscrowds.org"}},
  "work": {"git": {"name": "Chris Su", "email": "chris@company.com"}},
},
```

### Shell Configuration (for templates)

```jinja
"user": {
  "shell": {"default": "bash", "timezone": "Asia/Shanghai", "locale": "en_US.UTF-8"},
},
```

Changes take effect on the next `state.apply` — this project uses no pillar, so
there is nothing to refresh.

## Usage

1.  Edit `salt/config.jinja` with your configuration (`cfg.qubes.<qube>.git`)
2.  Add an entry under `cfg.qubes` for each AppVM that needs git
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
