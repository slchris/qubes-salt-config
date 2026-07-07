{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Install debian-minimal template from repository
#}

{%- import slsdotpath ~ "/template.jinja" as template -%}

"{{ template.template }}-template-installed":
  qvm.template_installed:
    - name: {{ template.template }}
    - fromrepo: {{ template.repo }}
