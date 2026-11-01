{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Configure an existing agent AppVM (runs IN the AppVM).

Apply per qube, after it has been restarted from the current tpl-agents:
  sudo qubesctl --skip-dom0 --targets=mvtest state.apply agents.configure

Two per-AppVM settings that the shared template cannot own:

  * timezone and locale — agents.exit stores the NetVM's VPN exit on the qube
    (vm-config.timezone, vm-config.locale). This state runs the boot script
    once so a qube that is already up picks the exit up without a restart.
    The script also runs at every boot.
  * default browser — Qubes AppVMs get a user-level mimeapps.list that points
    http/https at qvm-open-in-dvm.desktop. That overrides the template's
    Chrome default, so OAuth/`xdg-open` from Claude Code or the agents opens a
    DispVM instead of Chrome. Point the user's default at Chrome explicitly.

Chrome must exist in the AppVM (it is in tpl-agents); if it does not, the
state fails with "google-chrome: command not found" — restart the AppVM from
the updated template first.
#}

{% if grains['nodename'] != 'dom0' %}

"agents-exit-script":
  file.exists:
    - name: /usr/lib/qubes-agents/apply-exit.sh

"agents-exit-locale":
  cmd.run:
    - name: /usr/lib/qubes-agents/apply-exit.sh
    - require:
      - file: agents-exit-script

"agents-default-browser":
  cmd.run:
    - name: |
        set -eu
        command -v google-chrome >/dev/null
        export HOME=/home/user
        xdg-settings set default-web-browser com.google.Chrome.desktop
        xdg-mime default com.google.Chrome.desktop x-scheme-handler/http
        xdg-mime default com.google.Chrome.desktop x-scheme-handler/https
        xdg-mime default com.google.Chrome.desktop text/html
    - runas: user
    - shell: /bin/bash

{% endif %}
