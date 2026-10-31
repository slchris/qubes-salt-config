{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Split GPG 2 and Split SSH policy, one block per cfg.profiles entry.

A profile's project AppVM may use that profile's gpg qube for GPG and SSH.
Its pass qube may use the same gpg qube for GPG, so `pass` can decrypt.
No SshAgent rule for the pass qube. No rule reaches another profile's gpg
qube. qubes.Gpg2 is allow because split-gpg2's server refuses to export
key material.

Service and guivm lines run only when that qube already exists, so listing
a pass qube that has not been created yet does not fail this state.

Apply on dom0, after the gpg qube exists:

  sudo qubesctl state.apply templates.gpg.policy
#}

{% from 'config.jinja' import cfg with context %}

{% if grains['nodename'] == 'dom0' %}

{% set ns = namespace(used=[]) %}
{% for name, profile in cfg.profiles.items() %}
{% for qube in (profile.project, profile.gpg, profile.pass, profile.netvm) %}
{% if qube in ns.used %}
"profile-{{ name }}-collision-{{ qube }}":
  cmd.run:
    - name: echo "profile qube {{ qube }} is used by more than one profile" >&2; exit 1
{% endif %}
{% set _ = ns.used.append(qube) %}
{% endfor %}
{% endfor %}

"gpg-split-policy":
  file.managed:
    - name: /etc/qubes/policy.d/30-user-gpg2.policy
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        # SPDX-License-Identifier: MIT — managed by templates.gpg.policy
        # Each profile's project and pass qubes may use that profile's gpg
        # qube. They cannot export keys. The + form matches the split-gpg2
        # client. The explicit target line matches qrexec-client-vm.
        {%- for name, profile in cfg.profiles.items() %}
        qubes.Gpg2 + {{ profile.project }} @default allow target={{ profile.gpg }}
        qubes.Gpg2 + {{ profile.project }} {{ profile.gpg }} allow
        qubes.Gpg2 + {{ profile.pass }} @default allow target={{ profile.gpg }}
        qubes.Gpg2 + {{ profile.pass }} {{ profile.gpg }} allow
        {%- endfor %}

"gpg-split-ssh-policy":
  file.managed:
    - name: /etc/qubes/policy.d/30-user-ssh-agent.policy
    - user: root
    - group: root
    - mode: '0644'
    - contents: |
        # SPDX-License-Identifier: MIT — managed by templates.gpg.policy
        # Project AppVM only. The auth key stays in that profile's gpg qube.
        {%- for name, profile in cfg.profiles.items() %}
        qubes.SshAgent * {{ profile.project }} {{ profile.gpg }} allow
        {%- endfor %}

{% for name, profile in cfg.profiles.items() %}
"gpg-split-client-{{ name }}-project":
  cmd.run:
    - name: qvm-service {{ profile.project }} split-gpg2-client on
    - unless: test "$(qvm-service {{ profile.project }} split-gpg2-client)" = on
    - onlyif: qvm-check --quiet {{ profile.project }}

"gpg-split-client-{{ name }}-pass":
  cmd.run:
    - name: qvm-service {{ profile.pass }} split-gpg2-client on
    - unless: test "$(qvm-service {{ profile.pass }} split-gpg2-client)" = on
    - onlyif: qvm-check --quiet {{ profile.pass }}

"gpg-split-guivm-{{ name }}":
  cmd.run:
    - name: qvm-prefs {{ profile.gpg }} guivm sys-gui-vnc
    - unless: test "$(qvm-prefs {{ profile.gpg }} guivm)" = sys-gui-vnc
    - onlyif: qvm-check --quiet {{ profile.gpg }}
{% endfor %}

{% endif %}
