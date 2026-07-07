# VPN

VPN gateway template for Qubes OS.

## Table of Contents

*   [Description](#description)
*   [Installation](#installation)
*   [Usage](#usage)

## Description

Creates a VPN gateway qube (sys-vpn) that can be used as a NetVM for other qubes. Supports WireGuard and OpenVPN.

Packages installed:

*   wireguard-tools - WireGuard VPN
*   openvpn - OpenVPN client
*   NetworkManager-openvpn - NetworkManager OpenVPN plugin
*   NetworkManager-openvpn-gnome - GNOME integration

## Installation

### Using Top File (Recommended)

```sh
sudo qubesctl top.enable templates.vpn
sudo qubesctl --targets=tpl-vpn state.apply
sudo qubesctl top.disable templates.vpn
```

### Using State Directly

```sh
# Create the VPN qube
sudo qubesctl state.apply templates.vpn.create

# Install packages
sudo qubesctl --skip-dom0 --targets=tpl-vpn state.apply templates.vpn.install

# Configure (optional)
sudo qubesctl --skip-dom0 --targets=sys-vpn state.apply templates.vpn.configure
```

## Usage

### WireGuard Setup

1.  Copy your WireGuard config to sys-vpn:

    ```sh
    qvm-copy-to-vm sys-vpn /path/to/wg0.conf
    ```

2.  In sys-vpn, move the config:

    ```sh
    sudo mv /home/user/QubesIncoming/*/wg0.conf /etc/wireguard/
    sudo chmod 600 /etc/wireguard/wg0.conf
    ```

3.  Start WireGuard:

    ```sh
    sudo wg-quick up wg0
    ```

### OpenVPN Setup

1.  Copy your OpenVPN config to sys-vpn:

    ```sh
    qvm-copy-to-vm sys-vpn /path/to/vpn.ovpn
    ```

2.  Start OpenVPN:

    ```sh
    sudo openvpn --config /home/user/QubesIncoming/*/vpn.ovpn
    ```

### Using sys-vpn as NetVM

Set sys-vpn as the NetVM for qubes that should use VPN:

```sh
qvm-prefs my-qube netvm sys-vpn
```

Or in Qube Manager, change the NetVM setting for the desired qube.

## Network Topology

```
Internet <-> sys-net <-> sys-firewall <-> sys-vpn <-> AppVMs
```

## Qubes Created

| Qube | Type | Description |
|------|------|-------------|
| tpl-vpn | Template | Base template with VPN packages |
| sys-vpn | AppVM | VPN gateway (ProxyVM) |

## License

SPDX-License-Identifier: MIT

Copyright 2026 Chris Su
