{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Qubes RPC Policy Template

Usage:

UNSET POLICY:
-------------
{% from 'utils/macros/policy.sls' import policy_unset with context -%}
{{ policy_unset(sls_path, '80') }}

SET POLICY:
-----------
{% from 'utils/macros/policy.sls' import policy_set with context -%}
{{ policy_set(sls_path, '80') }}

FULL CONTROL:
-------------
{% from 'utils/macros/policy.sls' import policy_set_full with context -%}
{{ policy_set_full('project', '/etc/qubes/policy.d/80-project.policy', 'salt://project/files/admin/policy/default.policy') }}
#}

{% macro policy_set(name, priority) -%}
{{ policy_set_full(name, '/etc/qubes/policy.d/' ~ priority ~ '-' ~ name ~ '.policy', 'salt://' ~ name ~ '/files/admin/policy/default.policy') }}
{%- endmacro %}

{% macro policy_set_full(name, path, source) -%}
"{{ name }}-policy-set":
  file.managed:
    - name: {{ path }}
    - source: {{ source }}
    - mode: '0644'
    - user: root
    - group: root
    - makedirs: True
{%- endmacro %}

{% macro policy_unset(name, priority) -%}
{{ policy_unset_full(name, '/etc/qubes/policy.d/' ~ priority ~ '-' ~ name ~ '.policy') }}
{%- endmacro %}

{% macro policy_unset_full(name, path) -%}
"{{ name }}-policy-unset":
  file.absent:
    - name: {{ path }}
{%- endmacro %}
