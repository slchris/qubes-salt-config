{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Clone the base template for the agent build qube.
#}

{% from 'config.jinja' import cfg with context -%}
{% from 'utils/macros/clone-template.sls' import clone_template -%}
{% set b = cfg.agents.build -%}
{{ clone_template(b.template_source, b.template | replace('tpl-', '', 1)) }}
