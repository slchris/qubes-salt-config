#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Chris Su
# SPDX-License-Identifier: MIT
"""Open a pull request when a pinned Qubes template is near upstream EOL.

The successor has to be a minimal template Qubes OS 4.3 actually publishes,
and that upstream release has to still be supported. A newer Fedora number
that Qubes has not shipped is ignored. sys-gui-vnc is not retargeted.

shortcut: Qubes R4.3 templates-itl index only, point RPM_INDEX at the new
release when this tree targets another Qubes OS.
"""

import datetime
import json
import re
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RPM_INDEX = "https://yum.qubes-os.org/r4.3/templates-itl/rpm/"
NOTICE_DAYS = 40
MINIMAL_RE = re.compile(r"qubes-template-(fedora|debian)-(\d+)-minimal-")
# Debian's endoflife.date "eol" is later than regular security support.
# Qubes stops at regular support, which that feed calls "support".
DISTROS = (
    ("fedora", "https://endoflife.date/api/fedora.json", "eol"),
    ("debian", "https://endoflife.date/api/debian.json", "support"),
)


def fetch(url):
    request = urllib.request.Request(url, headers={"User-Agent": "qubes-salt-config-pin-bump"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()


def published_minimal(html):
    found = {"fedora": set(), "debian": set()}
    for distro, version in MINIMAL_RE.findall(html):
        found[distro].add(int(version))
    return found


def cycles_from(payload, field):
    if not isinstance(payload, list):
        raise SystemExit("release feed is not a list")
    cycles = {}
    for item in payload:
        cycle = str(item.get("cycle") or "")
        raw = item.get(field)
        if not cycle.isdigit() or not isinstance(raw, str) or len(raw) < 10:
            continue
        cycles[int(cycle)] = datetime.date.fromisoformat(raw[:10])
    if not cycles:
        raise SystemExit("release feed has no " + field + " dates")
    return cycles


def plan_distro(current, today, cycles, published, notice_days=NOTICE_DAYS):
    current_eol = cycles.get(current)
    if current_eol is not None and (current_eol - today).days > notice_days:
        return None
    candidates = [
        version for version, eol in cycles.items()
        if version > current and eol > today and version in published
    ]
    if not candidates:
        return None
    return min(candidates)


def current_version(text, distro):
    found = re.findall(r'qvm_' + distro + r'_version = "(\d+)"', text)
    if len(found) != 1:
        raise SystemExit("config.jinja has " + str(len(found)) + " " + distro + " pins")
    return int(found[0])


def rewrite(text, distro, old, new):
    old = str(old)
    new = str(new)
    marker = distro + "-" + old + "-xfce"
    xfce = text.count(marker)
    updated = text.replace(distro + "-" + old + "-minimal", distro + "-" + new + "-minimal")
    updated = updated.replace(
        'qvm_' + distro + '_version = "' + old + '"',
        'qvm_' + distro + '_version = "' + new + '"',
    )
    updated = updated.replace(
        "cfg.qvm." + distro + ".get('version', '" + old + "')",
        "cfg.qvm." + distro + ".get('version', '" + new + "')",
    )
    updated = updated.replace(
        '"' + distro + '": {"version": "' + old + '"',
        '"' + distro + '": {"version": "' + new + '"',
    )
    if updated.count(marker) != xfce:
        raise SystemExit("refusing to retarget " + distro + " xfce")
    return updated


def apply_versions(root, distro, old, new):
    root = Path(root)
    required = (
        root / "salt" / "config.jinja",
        root / "salt" / distro / "template.jinja",
    )
    optional = (
        root / "readme.md",
        root / "salt" / "utils" / "README.md",
        root / "docs" / "deploy-checklist.md",
    )
    for path in required + optional:
        if not path.is_file():
            if path in required:
                raise SystemExit("missing " + str(path))
            continue
        updated = rewrite(path.read_text(), distro, old, new)
        if path in required and updated == path.read_text():
            raise SystemExit(str(path) + " has no " + distro + " " + str(old) + " pin")
        if updated != path.read_text():
            path.write_text(updated)


def pr_body(changes):
    lines = [
        "A pinned base template is at or inside the upstream maintenance window "
        "(" + str(NOTICE_DAYS) + " days). The replacement is the oldest version "
        "Qubes OS 4.3 still publishes whose upstream support continues.",
        "",
    ]
    for change in changes:
        lines.append(
            "- " + change["distro"] + " " + str(change["old"])
            + " (upstream end " + change["eol"] + ") -> " + str(change["new"])
            + " (supported through " + change["successor_eol"] + ")"
        )
    lines.extend([
        "",
        "`sys-gui-vnc` stays on `fedora-43-xfce`. Its KasmVNC package is the "
        "Fedora 43 RPM. `gh`, `kubectl`, `kustomize`, and `age` keep following "
        "whatever Debian template this pin selects.",
        "",
        "Merging does not install a template or switch a running qube. On the "
        "machine, use the clean install in `docs/install.md`: rename the cloned "
        "template with an `-old` suffix, re-apply its formula, test, then remove "
        "the old template. The Fedora clone in this tree is `tpl-vpn`.",
        "",
    ])
    return "\n".join(lines)


def collect(today=None):
    today = today or datetime.date.today()
    published = published_minimal(fetch(RPM_INDEX).decode("utf-8", "replace"))
    config = (ROOT / "salt" / "config.jinja").read_text()
    changes = []
    for distro, url, field in DISTROS:
        cycles = cycles_from(json.loads(fetch(url).decode()), field)
        current = current_version(config, distro)
        new = plan_distro(current, today, cycles, published[distro])
        if new is None:
            eol = cycles.get(current)
            if eol is not None and (eol - today).days <= NOTICE_DAYS:
                print(distro + " " + str(current) + " is due and no successor template is published")
            continue
        changes.append({
            "distro": distro,
            "old": current,
            "new": new,
            "eol": cycles[current].isoformat() if current in cycles else "unknown",
            "successor_eol": cycles[new].isoformat(),
        })
    return changes


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    summary = None
    if argv[:1] == ["--summary"]:
        if len(argv) != 2:
            raise SystemExit("usage: bump_templates.py --summary PATH")
        summary = Path(argv[1])
    elif argv:
        raise SystemExit("usage: bump_templates.py [--summary PATH]")
    changes = collect()
    if summary is not None:
        summary.write_text(pr_body(changes) if changes else "template pins are current\n")
    if not changes:
        print("template pins are current")
        return 0
    for change in changes:
        apply_versions(ROOT, change["distro"], change["old"], change["new"])
        print(
            "template pin " + change["distro"] + " "
            + str(change["old"]) + " -> " + str(change["new"])
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
