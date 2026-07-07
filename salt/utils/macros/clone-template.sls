{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Clone template macro - based on qusal project patterns

Usage:
1: Import this template:
{% from 'utils/macros/clone-template.sls' import clone_template -%}

2: Set template to clone from and the clone name:
{{ clone_template('debian-minimal', sls_path) }}

This will:
- Include the source template's create state
- Clone the source template to tpl-<name>

Advanced usage with multiple sources:
{{ clone_template(['debian-minimal', 'fedora-minimal'], sls_path) }}

Parameters:
- source: Template to clone from (string or list of strings)
- name: Name for the cloned template (typically use sls_path)
- prefix: Prefix for the clone name (default: 'tpl-')
- include_create: Whether to include the source's create state (default: True)
#}

{% macro clone_template(source, name, prefix='tpl-', include_create=True) -%}

{# Handle list of source templates #}
{% if source is iterable and (source is not string and source is not mapping) -%}

{%- import source[0] ~ "/template.jinja" as template -%}
{% set source_create = source | map('regex_replace', '$', '.create') | list %}
{% if include_create -%}
include: {{ source_create }}
{% endif %}
{% set source = source[0] -%}

{% else %}

{%- import source ~ "/template.jinja" as template -%}
{% if include_create -%}
include:
  - {{ source }}.create
{% endif %}

{% endif %}

{% from 'utils/macros/update-admin.sls' import update_admin -%}
{{ update_admin(source, prefix + name) }}

"{{ prefix }}{{ name }}-clone":
  qvm.clone:
{% if include_create %}
    - require:
      - sls: {{ source }}.create
{% endif %}
    - source: {{ template.template }}
    - name: {{ prefix }}{{ name }}

{% endmacro -%}
