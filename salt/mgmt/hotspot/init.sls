{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Set up a Wi-Fi hotspot on sys-net (dom0-driven), in two idempotent parts:

  1. NetworkManager connection — CREATE it only if it does not already exist
     (so re-running never touches a hotspot you are currently using), with the
     full parameter set required for clients to actually connect (AP mode,
     wpa-psk, PMF). Missing any of these makes the SSID visible but unjoinable.
  2. Firewall — MERGE DHCP/DNS custom-input accept rules into sys-net's
     /rw/config/qubes-firewall-user-script inside a `# >>> hotspot >>>` block,
     coexisting with the remote-debug block (does not clobber it).

This does NOT bring the connection up — after a firewall reload you run
`nmcli con up <con_name>` yourself. See salt/mgmt/hotspot/README.md.

Apply (dom0):  sudo qubesctl state.apply mgmt.hotspot
Run BEFORE mgmt.remote-debug.netfw so both firewall blocks land in the file.
#}

{%- from 'config.jinja' import cfg with context -%}
{%- set hs = cfg.get('hotspot', {}) -%}
{%- set qube = hs.get('qube', 'sys-net') -%}
{%- set accept = hs.get('accept', ['udp/67', 'udp/68', 'udp/53', 'tcp/53']) -%}
{%- set con = hs.get('con_name', 'thinkpad-x1') -%}
{%- set ifname = hs.get('ifname', '') -%}
{%- set ssid = hs.get('ssid', con) -%}
{%- set password = hs.get('password', '') -%}
{%- set band = hs.get('band', 'bg') -%}

{% if grains['nodename'] == 'dom0' %}

{#- Part 1: create the NM hotspot connection, only if it does not exist yet.
    The whole thing runs inside the qube via one qvm-run so the `nmcli con show`
    existence check and the create are atomic; if it exists we exit 0 untouched. -#}
{% if ifname and password %}
"hotspot-nmcli-create":
  cmd.run:
    - name: |
        qvm-run --pass-io -u root -- {{ qube }} 'set -e; \
          if nmcli -t -f NAME con show 2>/dev/null | grep -qx "{{ con }}"; then \
            echo "hotspot: connection {{ con }} already exists — leaving it untouched"; exit 0; fi; \
          nmcli device wifi hotspot ifname {{ ifname }} con-name {{ con }} ssid {{ ssid }} password "{{ password }}" band {{ band }}; \
          nmcli con modify {{ con }} 802-11-wireless.mode ap 802-11-wireless.band {{ band }} ipv4.method shared; \
          nmcli con modify {{ con }} wifi-sec.key-mgmt wpa-psk; \
          nmcli con modify {{ con }} wifi-sec.psk "{{ password }}"; \
          nmcli con modify {{ con }} 802-11-wireless-security.pmf 1; \
          echo "hotspot: created {{ con }} (bring it up with: nmcli con up {{ con }})"'
    - onlyif: qvm-check --running {{ qube }}
{% endif %}

{#- Part 2: firewall accept rules, merged (see netfw for the same pattern). -#}
{%- set staged = '/tmp/hotspot-fw.sh' -%}

"hotspot-fw-stage":
  file.managed:
    - name: {{ staged }}
    - mode: '0644'
    - contents: |
        # >>> hotspot (managed by mgmt.hotspot — do not edit) >>>
        {%- for rule in accept %}
        {%- set proto = rule.split('/')[0] %}
        {%- set port = rule.split('/')[1] %}
        nft add rule ip qubes custom-input {{ proto }} dport {{ port }} counter accept
        {%- endfor %}
        # <<< hotspot <<<

"hotspot-fw-merge":
  cmd.run:
    - name: |
        cat {{ staged }} | qvm-run --pass-io -u root -- {{ qube }} 'F=/rw/config/qubes-firewall-user-script; NEW=$(cat); [ -f "$F" ] || printf "#!/bin/sh\n" > "$F"; grep -q "^#!" "$F" || sed -i "1i #!/bin/sh" "$F"; sed -i "/# >>> hotspot/,/# <<< hotspot <<</d" "$F"; printf "%s\n" "$NEW" >> "$F"; chmod 0755 "$F"'
    - onlyif: qvm-check --running {{ qube }}
    - require:
      - file: hotspot-fw-stage

"hotspot-fw-apply-now":
  cmd.run:
    - name: qvm-run --pass-io -u root -- {{ qube }} /rw/config/qubes-firewall-user-script
    - onlyif: qvm-check --running {{ qube }}
    - require:
      - cmd: hotspot-fw-merge

{% endif %}
