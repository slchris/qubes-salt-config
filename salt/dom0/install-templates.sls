{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Install required base templates in dom0.
This must be run first before any other states.

Template names are derived from the pillar-configured versions via each
template.jinja, so bumping qvm:fedora:version / qvm:debian:version in pillar is
enough — there are no hardcoded template versions to keep in sync here.
#}

{%- import "fedora-minimal/template.jinja" as fedora_minimal -%}
{%- import "debian-minimal/template.jinja" as debian_minimal -%}

{% if grains['nodename'] == 'dom0' %}

# Minimal Fedora (for mgmt and vpn)
"install-{{ fedora_minimal.template }}":
  cmd.run:
    - name: qubes-dom0-update --clean qubes-template-{{ fedora_minimal.template }}
    - unless: qvm-check {{ fedora_minimal.template }}

# Minimal Debian (for most templates)
"install-{{ debian_minimal.template }}":
  cmd.run:
    - name: qubes-dom0-update --clean qubes-template-{{ debian_minimal.template }}
    - unless: qvm-check {{ debian_minimal.template }}

{% endif %}
