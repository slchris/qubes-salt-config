{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Clone debian-minimal for the AI agent workbench (Claude Desktop + Claude Code).
#}

{% from 'utils/macros/clone-template.sls' import clone_template -%}
{% set name = slsdotpath.split('.')[-1] -%}
{{ clone_template('debian-minimal', name) }}
