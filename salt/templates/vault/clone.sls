{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Clone debian-minimal template for vault environment
#}

{% from 'utils/macros/clone-template.sls' import clone_template -%}
{% set name = sls_path.split('/')[-1] -%}
{{ clone_template('debian-minimal', name) }}
