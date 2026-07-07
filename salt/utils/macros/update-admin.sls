{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Update Admin macro - updates management_dispvm for templates

This ensures templates are properly managed by the admin VM.

Usage:
{% from 'utils/macros/update-admin.sls' import update_admin -%}
{{ update_admin('debian-minimal', 'tpl-myapp') }}
#}

{% macro update_admin(source, target) -%}
{#
Only update if management_dispvm is set and the target is a template.
This is a no-op placeholder that can be extended for admin VM management.
#}
{% endmacro -%}
