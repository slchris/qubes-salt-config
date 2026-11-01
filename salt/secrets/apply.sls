{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Decrypt this profile's file from the private sops checkout and write it.

The state runs in the profile's project AppVM. The file is
cfg.secrets.profile_file with "{profile}" replaced by that profile's key.
A pass qube, a gpg qube, or an agent AppVM that is not a profile project
is skipped. The checkout is not part of this repository. When it is
absent the state succeeds and changes nothing.

Decrypt runs here, as user, so split-gpg2 can reach that profile's card.
dom0 never sees the plaintext. See salt/secrets/README.md.

  sudo qubesctl --skip-dom0 --targets=slchris-project state.apply secrets.apply
#}

{%- from 'config.jinja' import cfg with context -%}
{%- set secrets = cfg.get('secrets', {}) -%}
{%- set checkout = secrets.get('checkout', '/home/user/src/qubes-salt-secrets') -%}
{%- set profile_file = secrets.get('profile_file', 'secrets/profiles/{profile}.yaml') -%}
{%- set qube = grains['nodename'] -%}
{%- set found = namespace(name='') -%}
{%- for name, profile in cfg.profiles.items() -%}
{%- if profile.project == qube -%}
{%- set found.name = name -%}
{%- endif -%}
{%- endfor -%}
{%- set rel = profile_file.replace('{profile}', found.name) %}

{% if found.name %}

"secrets-apply":
  cmd.script:
    - source: salt://secrets/files/apply_qube_secrets.py
    - args: "{{ checkout }} {{ rel }}"
    - cwd: /home/user
    - runas: user
    - stateful: True
    - timeout: 180

{% else %}

"secrets-apply-skip":
  test.succeed_without_changes:
    - name: {{ qube }} is not a profile project qube

{% endif %}
