{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Remove the old Claude/MCP templates.

tpl-agents is the only template that logs into Claude. tpl-ai (and its ai /
dvm-ai qubes) and tpl-mcp (and its mcp / dvm-mcp qubes) were an earlier
workbench on the same job, so they are removed rather than kept beside it.
This drops each AppVM's private volume. Apply on dom0:

  sudo qubesctl state.apply templates.retire-ai-mcp
#}

{% if grains['nodename'] == 'dom0' %}

# AppVMs first, then the DispVM templates, then the TemplateVMs. A template
# cannot be removed while anything still points at it.
"retire-ai-mcp-appvms":
  qvm.absent:
    - names:
      - ai
      - mcp

"retire-ai-mcp-dvms":
  qvm.absent:
    - names:
      - dvm-ai
      - dvm-mcp
    - require:
      - qvm: retire-ai-mcp-appvms

"retire-ai-mcp-templates":
  qvm.absent:
    - names:
      - tpl-ai
      - tpl-mcp
    - require:
      - qvm: retire-ai-mcp-dvms

{% endif %}
