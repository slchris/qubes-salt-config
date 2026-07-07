{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Ensure a Gentoo base template is available in dom0.

Unlike debian/fedora, Qubes OS does not ship a ready-to-clone Gentoo template
in the default ITL repositories (the prebuilt gentoo-minimal was removed from
the Template Manager in 2026). Gentoo is a source distribution and the template
must be built with qubes-builder or installed from a community repository.

Behaviour:
  - If pillar qvm:gentoo:repo is set, try to install the template from that
    repo via qubes-dom0-update (best effort; only works if the repo provides
    a qubes-template-<flavor> package).
  - Otherwise, verify the template already exists and FAIL LOUDLY with build
    instructions if it does not. We never silently pretend to have Gentoo.

See salt/gentoo/README.md for how to build the template with qubes-builder.
#}

{%- from 'config.jinja' import cfg with context -%}
{%- import slsdotpath ~ "/template.jinja" as template -%}
{%- set repo = cfg.qvm.get('gentoo', {}).get('repo', '') -%}

{% if grains['nodename'] == 'dom0' %}

{% if repo %}
"install-{{ template.template }}-from-repo":
  cmd.run:
    - name: >-
        qubes-dom0-update --clean --enablerepo={{ repo }}
        qubes-template-{{ template.template }}
    - unless: qvm-check {{ template.template }}
{% else %}
"require-{{ template.template }}-present":
  cmd.run:
    - name: >-
        echo "ERROR: template '{{ template.template }}' is not installed.
        Qubes does not ship a clone-ready Gentoo template. Build it with
        qubes-builder (qubes-template-configs) or set pillar qvm:gentoo:repo
        to a community repo that provides it. See salt/gentoo/README.md." >&2;
        exit 1
    - unless: qvm-check {{ template.template }}
{% endif %}

{% endif %}
