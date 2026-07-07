#!/bin/bash
# SPDX-FileCopyrightText: 2026 Chris Su
# SPDX-License-Identifier: MIT
#
# Run the same linters CI runs, locally.
#
#   ./scripts/lint.sh            # run all linters
#   ./scripts/lint.sh yaml       # run only yamllint
#   ./scripts/lint.sh salt       # run only salt-lint
#
# Install the tools with:
#   pip install --user yamllint salt-lint

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

rc=0

run_yamllint() {
    if ! command -v yamllint >/dev/null 2>&1; then
        echo "==> yamllint not found (pip install --user yamllint), skipping" >&2
        return 0
    fi
    echo "==> yamllint (pure YAML only)"
    # Only pure-YAML files. The Jinja-templated Salt states under salt/** are
    # not valid standalone YAML and are handled by salt-lint below.
    if ! yamllint -c .yamllint \
        pillar/top.sls pillar/user.sls salt/top.sls \
        .yamllint .salt-lint .github/workflows/lint.yml; then
        rc=1
    fi
}

run_saltlint() {
    if ! command -v salt-lint >/dev/null 2>&1; then
        echo "==> salt-lint not found (pip install --user salt-lint), skipping" >&2
        return 0
    fi
    echo "==> salt-lint (Salt states and top files)"
    if ! find salt \( -name '*.sls' -o -name '*.top' \) \
        -print0 | xargs -0 salt-lint -c .salt-lint; then
        rc=1
    fi
}

case "${1:-all}" in
    yaml) run_yamllint ;;
    salt) run_saltlint ;;
    all)  run_yamllint; run_saltlint ;;
    *)    echo "Usage: ${0##*/} [all|yaml|salt]" >&2; exit 2 ;;
esac

if [ "$rc" -eq 0 ]; then
    echo "==> All lint checks passed"
else
    echo "==> Lint checks reported issues" >&2
fi
exit "$rc"
