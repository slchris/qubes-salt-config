#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Chris Su
# SPDX-License-Identifier: MIT
"""Approve the lint run GitHub holds on a pin pull request.

A pull request opened with GITHUB_TOKEN creates pull_request workflows in
the action_required state. The same token can approve the run for the
commit it just pushed. Other commits are left alone.
"""

import argparse
import json
import os
import subprocess
import time


def waiting_ids(runs, sha):
    """Return lint run ids to approve for this commit.

    An empty list means a pull_request run for this commit already started.
    LookupError means no pull_request run for this commit is visible yet.
    """
    ours = [
        run for run in runs
        if run.get("event") == "pull_request" and run.get("headSha") == sha
    ]
    if not ours:
        raise LookupError(sha)
    waiting = [
        run["databaseId"] for run in ours
        if run.get("conclusion") == "action_required"
    ]
    if waiting:
        return waiting
    started = (
        "queued", "in_progress", "success", "failure", "cancelled",
        "skipped", "neutral", "timed_out", "startup_failure",
    )
    if any(run.get("status") in started or run.get("conclusion") in started for run in ours):
        return []
    raise LookupError(sha)


def _gh_json(args):
    out = subprocess.check_output(["gh", *args], text=True)
    return json.loads(out) if out.strip() else None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--branch", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--attempts", type=int, default=15)
    parser.add_argument("--interval", type=float, default=3)
    args = parser.parse_args()
    repo = os.environ.get("GITHUB_REPOSITORY")
    if not repo:
        repo = _gh_json(["repo", "view", "--json", "nameWithOwner"])["nameWithOwner"]
    fields = "databaseId,conclusion,status,event,headSha"
    for _ in range(args.attempts):
        runs = _gh_json([
            "run", "list", "--repo", repo, "--branch", args.branch,
            "--limit", "20", "--json", fields,
        ])
        try:
            ids = waiting_ids(runs, args.sha)
        except LookupError:
            time.sleep(args.interval)
            continue
        for run_id in ids:
            subprocess.check_call([
                "gh", "api", "-X", "POST",
                f"repos/{repo}/actions/runs/{run_id}/approve",
            ])
            print(f"approved lint run {run_id}")
        if not ids:
            print(f"lint already started for {args.sha}")
        return
    raise SystemExit(f"lint run for {args.sha} did not appear")


if __name__ == "__main__":
    main()
