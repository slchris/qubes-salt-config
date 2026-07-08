# mgmt.hotspot

Set up a Wi-Fi hotspot on `sys-net` from config — in two idempotent parts:

1. **NetworkManager connection** — creates it with the full parameter set
   clients need (AP mode, WPA-PSK, PMF; missing any of these makes the SSID
   visible but **unjoinable**), but **only if it does not already exist**, so
   re-running never disturbs a hotspot you are currently using.
2. **Firewall** — merges DHCP/DNS `custom-input` accept rules into `sys-net`'s
   `/rw/config/qubes-firewall-user-script` inside a `# >>> hotspot >>>` block.

Both are safe to re-run. The firewall part merges (does not overwrite), so it
**coexists** with the remote-debug block (`mgmt.remote-debug.netfw`) in the same
file, and rules persist across reboots.

## Configure

In `salt/config.jinja`, `cfg.hotspot` (a plain dict — no comments allowed
inside config.jinja's dict):

```jinja
"hotspot": {
  "qube": "sys-net",
  "accept": ["udp/67", "udp/68", "udp/53", "tcp/53"],   # DHCP 67/68, DNS 53
  "con_name": "thinkpad-x1",   # NetworkManager connection name
  "ifname": "wls6f0",          # Wi-Fi NIC (from `nmcli device`)
  "ssid": "thinkpad-x1",
  "password": "114514111",
  "band": "bg",
},
```

If `ifname` or `password` is blank, the NM-create step is skipped (firewall-only).

## Apply

```sh
sudo qubesctl state.apply mgmt.hotspot
```

Run this **before** `mgmt.remote-debug.netfw` so both firewall blocks land in
the file. On a machine that already has the hotspot connection, the create step
is a no-op — only the firewall rules are (re)merged.

## Bringing the hotspot up

The formula does **not** start the connection (that would disturb a running
hotspot). After a firewall reload or reboot, bring it up yourself:

```sh
qvm-run -u user sys-net 'nmcli con up thinkpad-x1'
```

## Verify

```sh
# connection exists?
qvm-run --pass-io -u root sys-net 'nmcli -t -f NAME con show | grep thinkpad-x1'
# firewall accept rules present?
qvm-run --pass-io -u root sys-net 'nft list chain ip qubes custom-input'
```
