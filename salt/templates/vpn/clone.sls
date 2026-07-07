{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Clone fedora-minimal template for VPN gateway environment
#}

{% from 'utils/macros/clone-template.sls' import clone_template -%}
{% set name = sls_path.split('/')[-1] -%}
{{ clone_template('fedora-minimal', name) }}
