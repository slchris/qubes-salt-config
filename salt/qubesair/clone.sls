{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Clone the base template into the DEDICATED console template (runs IN dom0).

A dedicated template — rather than reusing tpl-dev or mgmt-jump's template —
because the console qube built from it holds the PVE API token, the agent CA
private key and the terraform state for the whole remote fleet. Every package
in this template is attack surface for those secrets, so the template gets
exactly the console's prerequisites and nothing else.

Deploy (from dom0):
  sudo qubesctl top.enable qubesair.clone
  sudo qubesctl state.apply qubesair.clone
  sudo qubesctl top.disable qubesair.clone
#}

{%- from 'config.jinja' import cfg with context -%}
{%- set qa = cfg.get('qubesair', {}) -%}
{%- set source = qa.get('template_source', 'debian-minimal') -%}
{%- set template = qa.get('template', 'tpl-qubesair') -%}

{% if qa.get('enabled', False) %}

{% from 'utils/macros/clone-template.sls' import clone_template -%}
{#- The other modules pass a bare name and let the macro prepend "tpl-".
    Here cfg.qubesair.template is the authoritative FULL name — create.sls,
    install.top and configure.sls all key off it — so it is passed whole with
    an empty prefix. Splitting the name across a config value and a macro
    default is exactly how the clone and the create end up disagreeing, which
    presents as an AppVM silently built on the wrong (un-provisioned)
    template. #}
{{ clone_template(source, template, prefix='') }}

{% else %}

"qubesair-clone-disabled-note":
  test.show_notification:
    - text: |
        qubesair.clone: cfg.qubesair.enabled is False — not cloning
        {{ template }}. Set qubesair.enabled in salt/config.jinja.

{% endif %}
