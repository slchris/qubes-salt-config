{#
SPDX-FileCopyrightText: 2026 Chris Su
SPDX-License-Identifier: MIT

Clone the Gentoo base template into tpl-gentoo-dev for ebuild/package
development. Requires an installed Gentoo template.

The base Gentoo template comes in flavors (gentoo-minimal, gentoo-xfce, ...).
The main desktop qubes use cfg.qvm.gentoo.flavor (default xfce); the dev
template is derived from cfg.qvm.gentoo.dev_flavor (default minimal) — the dev
box wants the lean base and pulls in exactly the ebuild/overlay toolchain via
install.sls, not a full desktop. We clone the installed source template
directly (bypassing gentoo/template.jinja's flavor resolution, and without an
include of gentoo-<flavor>.create since the base template is built externally
with qubes-builder, not created by Salt) so the dev flavor stays independent of
the desktop flavor.
#}

{% from 'config.jinja' import cfg with context -%}
{% set name = slsdotpath.split('.')[-1] -%}
{% set dev_flavor = cfg.qvm.get('gentoo', {}).get('dev_flavor', 'minimal') -%}
{% set source = 'gentoo' ~ ('-' ~ dev_flavor if dev_flavor else '') -%}

{% from 'utils/macros/update-admin.sls' import update_admin with context -%}
{{ update_admin(source, 'tpl-' ~ name) }}

"tpl-{{ name }}-clone":
  qvm.clone:
    - source: {{ source }}
    - name: tpl-{{ name }}
