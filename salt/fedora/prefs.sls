{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Set Fedora template management_dispvm to default after mgmt is ready
#}

{%- import slsdotpath ~ "/template.jinja" as template -%}

include:
  - {{ slsdotpath }}.create

"{{ slsdotpath }}-set-{{ template.template }}-management_dispvm-to-default":
  qvm.vm:
    - require:
      - sls: {{ slsdotpath }}.create
    - name: {{ template.template }}
    - prefs:
      - management_dispvm: "*default*"
