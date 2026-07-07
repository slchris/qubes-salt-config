# utils

Utility states and macros for common operations.

## Description

Common utility macros and states that can be included by other modules.

## Macros

### clone-template.sls

Macro for cloning templates from base templates. The base template version
is read from pillar configuration.

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
# (where '13' comes from pillar qvm:debian:version)
{{ clone_template('debian-minimal', 'dev') }}
```

## Version Configuration

Template versions are configured in `/srv/user_pillar/user.sls`:

```yaml
qvm:
  debian:
    version: "13"    # Will use debian-13 and debian-13-minimal
    repo: "qubes-templates-itl"
  fedora:
    version: "42"    # Will use fedora-42 and fedora-42-minimal
    repo: "qubes-templates-itl"
```

## Template Upgrade Workflow

To upgrade templates to a new version:

1. Edit pillar to update version
2. Rename existing templates with `-old` suffix in Qube Manager
3. Refresh pillar: `sudo qubesctl saltutil.refresh_pillar`
4. Rerun formulas

See [Template Upgrade Guide](../../docs/install.md#template-upgrade) for details.

## License

SPDX-License-Identifier: MIT

Copyright 2026 Chris Su
