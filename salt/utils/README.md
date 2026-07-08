# utils

Utility states and macros for common operations.

## Description

Common utility macros and states that can be included by other modules.

## Macros

### clone-template.sls

Macro for cloning templates from base templates. The base template version
is read from config.jinja (cfg.qvm.debian.version).

**Usage:**

```jinja
{% from 'utils/macros/clone-template.sls' import clone_template -%}
{{ clone_template('debian-minimal', sls_path) }}
```

**Parameters:**

| Parameter | Description | Default |
|-----------|-------------|---------|
| source | Base template name (e.g., 'debian-minimal', 'fedora-minimal') | Required |
| name | Name for the cloned template | Required |
| prefix | Prefix for the cloned template name | 'tpl-' |
| include_create | Whether to include the source's clone state | True |

**Example:**

```jinja
# Creates tpl-dev by cloning from debian-13-minimal
# (where '13' comes from cfg.qvm.debian.version in config.jinja)
{{ clone_template('debian-minimal', 'dev') }}
```

## Version Configuration

Template versions are configured in `salt/config.jinja` under `cfg.qvm`:

```jinja
"qvm": {
  "debian": {"version": "13", "repo": "qubes-templates-itl"},  # debian-13 / debian-13-minimal
  "fedora": {"version": "43", "repo": "qubes-templates-itl"},  # fedora-43 / fedora-43-minimal
},
```

## Template Upgrade Workflow

To upgrade templates to a new version:

1. Edit `config.jinja` to update the version under `cfg.qvm`
2. Rename existing templates with `-old` suffix in Qube Manager
3. Rerun formulas (config.jinja is read at apply time — no pillar refresh)

See [Template Upgrade Guide](../../docs/install.md#template-upgrade) for details.

## License

SPDX-License-Identifier: MIT

Copyright 2026 Chris Su
