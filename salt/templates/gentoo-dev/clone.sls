{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Clone the Gentoo base template into tpl-gentoo-dev for ebuild/package
development. Requires an installed Gentoo template (see salt/gentoo).
#}

{% from 'utils/macros/clone-template.sls' import clone_template -%}
{% set name = sls_path.split('/')[-1] -%}
{{ clone_template('gentoo', name) }}
