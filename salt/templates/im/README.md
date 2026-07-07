# tpl-im

Instant Messaging (IM) environment template for Qubes OS.

## Table of Contents

*   [Description](#description)
*   [Installation](#installation)
*   [Packages](#packages)
*   [Usage](#usage)

## Description

Creates an instant messaging environment with the following qubes:

| Qube | Type | Description |
|------|------|-------------|
| tpl-im | Template | Base template with messaging tools |
| im | AppVM | Persistent messaging workspace |

Note: IM applications typically need persistent storage for accounts and
message history, so no DispVM template is created by default.

## Installation

### Using Top File (Recommended)

```sh
sudo qubesctl top.enable templates.im
sudo qubesctl --targets=tpl-im state.apply
sudo qubesctl top.disable templates.im
```

### Using State Directly

```sh
# Step 1: Create qubes (in dom0)
sudo qubesctl state.apply templates.im.create

# Step 2: Install packages in template
sudo qubesctl --skip-dom0 --targets=tpl-im state.apply templates.im.install
```

## Packages

The following packages are installed:

### IRC Clients

| Package | Description |
|---------|-------------|
| weechat | Extensible IRC client |

### Matrix Clients

| Package | Description |
|---------|-------------|
| nheko | Desktop Matrix client |

### XMPP Clients

| Package | Description |
|---------|-------------|
| profanity | Console-based XMPP client |

### Telegram

| Package | Description |
|---------|-------------|
| telegram-desktop | Official Telegram client |

### Email (Optional)

| Package | Description |
|---------|-------------|
| neomutt | Terminal email client |

## Usage

After installation:

### Start Telegram

```sh
qvm-run im "telegram-desktop"
```

### Start Weechat (IRC)

```sh
qvm-run im "weechat"
```

### Start nheko (Matrix)

```sh
qvm-run im "nheko"
```

### Start Profanity (XMPP)

```sh
qvm-run im "profanity"
```

## Security Notes

*   IM applications often require persistent network access
*   Consider using separate qubes for different messaging accounts
*   Telegram and other proprietary clients may have privacy implications
