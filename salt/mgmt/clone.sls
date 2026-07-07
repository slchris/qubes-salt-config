{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Clone fedora-minimal template for management environment
#}

{%- import "fedora-minimal/template.jinja" as template -%}

include:
  - fedora-minimal.clone

"tpl-mgmt-clone":
  qvm.clone:
    - require:
      - sls: fedora-minimal.clone
    - source: {{ template.template }}
    - name: tpl-mgmt
