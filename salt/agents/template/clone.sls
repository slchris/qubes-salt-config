{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Clone the base template for the multi-agent dev template.
#}

{% from 'config.jinja' import cfg with context -%}
{% from 'utils/macros/clone-template.sls' import clone_template -%}
{% set t = cfg.agents.template -%}
{{ clone_template(t.source, t.name | replace('tpl-', '', 1)) }}
