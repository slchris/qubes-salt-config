# magpie

Publish an existing project qube's magpie on the house LAN. The Mac's
own magpie adds that qube as a remote magpie. Model calls leave through
the project qube's netvm. The Mac's agent stays on the Mac.

`cfg.magpie.enabled` is True, and slchris is published. A magpie state
still does nothing while that switch is False.

```
10.31.0.0/24
  -> sys-net:<port>
  -> sys-firewall:<port>
  -> <profile netvm>:<port>
  -> <profile project qube> eth0:<port>
```

slchris is `3425` on `slchris-project`, netvm `sys-bwg-mullvad`. Another
project is another `cfg.magpie.services` entry. The steps are below.

`3425` is not 2333, 6080, or 18080. The chains are `custom-dnat-magpie`
and `custom-snat-magpie`. Each hop DNATs and SNATs. The later hops accept
the port only from their Qubes gateway, so a sibling qube cannot use the
forward. On the project qube, `MAGPIE_ADDR` is its eth0 address.
`ip qubes` input jumps to `custom-input` and then drops, so `input.sh`
accepts this port there from `/qubes-gateway`. A separate base chain
cannot accept past that policy. A headerless connection to `127.0.0.1`
would skip the gateway key; this path does not listen there.

project-net is unchanged. New traffic from the project qube still has to
leave through `wg0`. The forward from the netvm's eth0 into the qube is
already allowed, and an established reply can return. There is no
kill-switch exception.

## Binary

These states do not download or install magpie, and they do not store a
gateway key. The pin lives in `salt/magpie/lock.yml`. GitHub Actions
checks yetone/magpie-releases once a day and opens a pull request when
a newer terminal build is published. Merging that pull request does not
copy the file onto a qube.

The CLI on `slchris-project` is the official terminal build
`magpie-cli-linux-amd64` v0.1.4723, not the GTK build:

```
https://github.com/yetone/magpie-releases/releases/download/v0.1.4723/magpie-cli-linux-amd64
57db71246f9555c8af630af5a550078ef63bb0e111a27128bf9cb919df349ed6
```

That digest is the `magpie-cli-linux-amd64` line in the tag's
`SHA256SUMS`. Put the file at `/rw/config/magpie/bin/magpie`, mode
`0755`, owner `user`, then restart the unit. Restarting the unit is
enough: it re-reads the binary, and the Claude login is untouched
because both it and the binary live on the private volume (`/rw`, also
mounted at `/home`), which survives a qube restart. `/usr/bin/magpie` is
only a fallback. With no binary the unit exits 0 and stays stopped.

```
sudo systemctl restart qubes-magpie.service
```

## Keys and the Mac

The unit runs as `user`. Gateway keys and the Claude login belong to
that user. Add the Mac's key in the project qube, not in this repo:

```
magpie gateway-key add mac
```

It prints the key once. On the Mac, with `10.31.0.0/24` left direct:

```
magpie provider add remote-magpie <key> url=http://10.31.0.135:3425 id=slchris
```

The qube lists its own models as `claude/...`. The Mac provider id
prefixes them, so the Mac sees `slchris/claude/...`. Tool calls stay on
the Mac. This publishes the login and the model calls.

Claude Code's picker does not show every provider the local magpie
knows. On this Mac the list is
`workstation.magpie.visibleModels.claude` in
`homelab-infra-as-code/nix/workstations/hosts/keiki/default.nix`.
`slchris` is there next to `myclaw`. After that file changes, rebuild
the keiki flake and reopen the menu-bar Magpie and Claude Code. The
default Claude Code model stays `myclaw/claude-opus-5.5`.

## More than one project

A second published project is another entry in `cfg.magpie.services`. It
can name its `project` and `netvm` inline and needs no `cfg.profiles`
entry — for example a plain agent AppVM with no gpg/pass qube, which is
not a profile. Without an inline `project`/`netvm`, the entry falls back
to the profile of the same key. The project qube and its netvm already
exist. These states do not create either one, and they do not change the
qube's netvm. The qube's live netvm has to equal the service's `netvm`
(or `profiles.<key>.netvm`).

```
  "magpie": {
    "services": {
      "slchris": {"port": 3425},
      "myproject": {
        "port": 3427,
        "project": "myproject-project",
        "netvm": "sys-myproject-net",
      },
    },
  },
```

`netfw` requires this chain:

```
sys-net -> middle qube -> the service's netvm -> the service's project
```

On this host the middle qube is `sys-firewall`. Apply refuses the entry
when the netvm is empty, `none`, `sys-net`, `sys-firewall`, or the project
qube itself, when the port is not an integer from 1 to 65535, when the
port is `22`, `2333`, `6080`, `8080`, `8443`, `8444`, or `18080`, when
two services use the same port, or when two services name the same
project qube.

`example` is not a qube here. It only shows the shape. This one shares
`sys-bwg-mullvad` with slchris, so both publishes use that Mullvad exit.
A different exit is a different netvm that already sits behind
`sys-firewall`. Point `example.netvm` at that gateway, and set the
project qube's live netvm to the same gateway before applying.

```
  "profiles": {
    "slchris": { "...": "unchanged" },
    "example": {
      "netvm": "sys-bwg-mullvad",
      "project": "example-project",
    },
  },

  "magpie": {
    "enabled": True,
    "services": {
      "slchris": {"port": 3425},
      "example": {"port": 3426},
    },
  },
```

A real profile also has email, git, gpg, pass, and the key fields.
Magpie reads `project` and `netvm`. Gateway keys stay out of
`config.jinja` and out of git.

On the new project qube, put the same pinned CLI at
`/rw/config/magpie/bin/magpie`, mode `0755`, owner `user`. From dom0:

```
sudo qubesctl --skip-dom0 --targets=example-project state.apply magpie.serve
```

Inside that qube, as `user`:

```
magpie gateway-key add mac
sudo systemctl restart qubes-magpie.service
```

`mac` is the key's name on that qube only. The add command prints the
key once. A qube restart keeps the login: `.claude/.credentials.json`
and magpie's `logins.json` are on the private volume, not in the root
image. A restart does end any in-flight Claude run and drops the running
unit's memory, so prefer `systemctl restart qubes-magpie.service` when
you only changed the binary or a gateway key.

`magpie.serve` is once per project qube. `magpie.netfw` is once, and
that one apply rewrites every hop for every published port, including
slchris. `sys-net`, `sys-firewall`, and every published netvm have to be
up. Other `default-dvm` disposables should be shut down first. A shared
hop gets one firewall script, with one DNAT per port. Re-apply
`magpie.netfw` when any published qube or hop is recreated and its
address changes.

```
sudo qubesctl state.apply magpie.netfw
```

On the Mac, with `10.31.0.0/24` left direct, add a second provider. The
id is the profile key, and the port is that service's port:

```
magpie provider add remote-magpie <key> url=http://10.31.0.135:3426 id=example
```

The Mac then sees `example/claude/...`. Add `example` beside `myclaw`
and `slchris` in `workstation.magpie.visibleModels.claude`, rebuild the
keiki flake, and reopen the menu-bar Magpie and Claude Code. The default
Claude Code model stays `myclaw/claude-opus-5.5`.

## What else these states do not do

- They do not create a qube, change a netvm, or start a qube. Applying
  `magpie.netfw` does start a disposable hop's DVM template long enough to
  write the firewall block, then shuts that template down. On this host
  that template is `default-dvm`. Before starting it, the state unpauses
  and shuts down paused disposables whose names are `disp` plus digits and
  whose template is that DVM template. `sys-firewall` and `sys-usb` are
  left running.
- They do not add the project qube to `cfg.agents.qubes`.

## Apply

Do not `top.enable magpie`. The project qube is already running. Restarting
it is not required to apply these states (and it would end any in-flight
Claude run); the states update files and restart only the unit.

```
sudo qubesctl --skip-dom0 --targets=slchris-project state.apply magpie.serve
sudo qubesctl state.apply magpie.netfw
```

With more than one service, run the first command once per project qube,
then run `magpie.netfw` once. See above.

Run `magpie.netfw` with `sys-net`, `sys-firewall`, and `sys-bwg-mullvad`
up, and with other `default-dvm` disposables shut down. Re-apply it if
`slchris-project`, `sys-bwg-mullvad`, or `sys-firewall` is recreated and
its address changes. `magpie.serve` restarts the unit. Until the binary
is in place, that restart exits and the unit stays stopped.
