{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Configure the sys-http-proxy gateway (runs IN the qube, not dom0).

Creates /rw/config/http-proxy-net/upstream.conf as an empty skeleton, merges
the firewall marker block into /rw/config/qubes-firewall-user-script, and
applies it now. The secret itself is never salt-managed: the operator fills
the skeleton and restarts http-proxy-net-start.service.

Deploy (from dom0):
  sudo qubesctl --skip-dom0 --targets=sys-http-proxy state.apply templates.http-proxy-net.configure
#}

{% if grains['nodename'] != 'dom0' %}

"http-proxy-net-config-dir":
  file.directory:
    - name: /rw/config/http-proxy-net
    - user: root
    - group: root
    - mode: '0700'

# replace: False — an existing upstream.conf is never overwritten by a
# re-apply. The password lives only in this file, on /rw.
"http-proxy-net-upstream-conf":
  file.managed:
    - name: /rw/config/http-proxy-net/upstream.conf
    - user: root
    - group: root
    - mode: '0600'
    - replace: False
    - contents: |
        # SPDX-License-Identifier: MIT — managed by templates.http-proxy-net.configure
        #
        # Upstream HTTP proxy (plain CONNECT, Basic auth). Fill in, then:
        #   sudo /usr/bin/http-proxy-net-start --check
        #   sudo systemctl restart http-proxy-net-start.service
        #
        # PROXY_HOST   hostname or IPv4 literal of the proxy.
        # PROXY_PORT   1-65535.
        # PROXY_USER   no ':' (tinyproxy's credential separator).
        # PROXY_PASS   no '@', whitespace, quotes, '#' or backslash.
        # PROXY_IP     optional IPv4 literal; pin it if PROXY_HOST does not
        #              resolve reliably. It skips the bootstrap lookup.
        # CONNECT_PORTS optional; comma-separated, defaults to 80,443 and
        #              must include 443 (dnscrypt's DoH goes through it).
        #
        # This file is on /rw only. Never commit it.
        #
        #PROXY_HOST=
        #PROXY_PORT=
        #PROXY_USER=
        #PROXY_PASS=
        #PROXY_IP=
        #CONNECT_PORTS=80,443
    - require:
      - file: http-proxy-net-config-dir

"http-proxy-net-firewall-file":
  file.managed:
    - name: /rw/config/qubes-firewall-user-script
    - user: root
    - group: root
    - mode: '0755'
    - replace: False
    - contents: |
        #!/bin/sh

# Two-stage load, same convention as project-net: the static base table
# cannot fail on user input, and --rules is best-effort. This block never
# exits; it is shared with other formulas.
"http-proxy-net-fw-script":
  file.blockreplace:
    - name: /rw/config/qubes-firewall-user-script
    - marker_start: "# >>> http-proxy-net >>>"
    - marker_end: "# <<< http-proxy-net <<<"
    - append_if_not_found: True
    - show_changes: True
    - content: |
        # Managed by templates.http-proxy-net.configure — do not edit between markers.
        # Fail-closed base first; a re-run flushes output-dynamic, so --rules
        # must run every time (not only at boot).
        if [ -f /etc/http-proxy-net/base.nft ]; then
          nft -f /etc/http-proxy-net/base.nft || logger -t http-proxy-net "FAILED to load base ruleset"
        fi
        /usr/bin/http-proxy-net-start --rules || logger -t http-proxy-net "FAILED to rebuild dynamic rules"
    - require:
      - file: http-proxy-net-firewall-file

"http-proxy-net-fw-shebang":
  cmd.run:
    - name: |
        f=/rw/config/qubes-firewall-user-script
        head -n1 "$f" | grep -q '^#!' || sed -i '1i #!/bin/sh' "$f"
        chmod 0755 "$f"
    - runas: root
    - require:
      - file: http-proxy-net-fw-script

# --check fails the state on an invalid non-empty conf (loud), but an empty
# skeleton is fine: the gateway stays closed. The start service is what
# applies the generated rules and daemon configs.
"http-proxy-net-apply-now":
  cmd.run:
    - name: |
        set -eu
        /usr/bin/http-proxy-net-start --check
        /rw/config/qubes-firewall-user-script
        systemctl restart http-proxy-net-start.service
        nft list table inet http-proxy-net >/dev/null
        nft list chain inet http-proxy-net forward | grep -q 'policy drop'
    - runas: root
    - require:
      - cmd: http-proxy-net-fw-shebang
      - file: http-proxy-net-upstream-conf

{% endif %}
