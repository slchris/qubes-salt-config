#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Chris Su
# SPDX-License-Identifier: MIT
#
# Enforce the qusal-style convention that every orchestratable Salt state has a
# matching .top file (install.sls <-> install.top, create.sls <-> create.top,
# init.sls <-> init.top). Run by CI and usable locally:
#
#     python3 scripts/check_top_pairing.py
#
# Some states are intentionally NOT top-orchestrated and are excluded below.

import glob
import os
import sys

# States that are applied on demand with an explicit --targets=<qube> (their
# target is arbitrary/grain-driven), plus library macros and the global salt
# top file. These deliberately have no paired .top.
EXCLUDE_EXACT = {
    "salt/top.sls",              # global Salt top, not a state
    "salt/utils/update.sls",     # applied against any template on demand
    "salt/dotfiles/init.sls",    # dotfiles are applied per-AppVM via --targets
    "salt/dotfiles/git.sls",
    "salt/dotfiles/shell.sls",
}


def is_excluded(path: str) -> bool:
    if "/macros/" in path:
        return True
    if path.startswith("salt/test/"):
        return True
    return path in EXCLUDE_EXACT


def main() -> int:
    missing = []
    considered = 0
    for sls in sorted(glob.glob("salt/**/*.sls", recursive=True)):
        if is_excluded(sls):
            continue
        considered += 1
        top = sls[:-4] + ".top"
        if not os.path.exists(top):
            missing.append((sls, top))

    # Also flag orphan .top files with no matching .sls (except init.top which
    # aggregates includes, and the standalone test.top).
    orphan_top = []
    for top in sorted(glob.glob("salt/**/*.top", recursive=True)):
        base = os.path.basename(top)
        if base in ("init.top", "test.top"):
            continue
        sls = top[:-4] + ".sls"
        if not os.path.exists(sls):
            orphan_top.append(top)

    print(f"Checked {considered} orchestratable state(s).")
    if missing:
        print("\nERROR: state .sls files missing a matching .top:")
        for sls, top in missing:
            print(f"  {sls}  ->  expected {top}")
    if orphan_top:
        print("\nERROR: .top files with no matching .sls:")
        for top in orphan_top:
            print(f"  {top}")

    if missing or orphan_top:
        return 1
    print("All states have a matching .top file. ✓")
    return 0


if __name__ == "__main__":
    sys.exit(main())
