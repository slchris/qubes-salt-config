#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Chris Su
# SPDX-License-Identifier: MIT
"""Approve the lint run GitHub holds on a pin pull request, then merge it.

A pull request opened with GITHUB_TOKEN creates pull_request workflows in
the action_required state. The same token can approve the run for the
commit it just pushed. Other commits are left alone. With --merge, the
pull request merges after every check has passed. Merging does not install
anything on a qube.
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


def verdict(checks):
    """Return pass, fail, or wait. No checks yet means wait."""
    if not checks:
        return "wait"
    buckets = {(check.get("bucket") or "").lower() for check in checks}
    if buckets & {"fail", "cancel"}:
        return "fail"
    if buckets <= {"pass", "skipping"}:
        return "pass"
    return "wait"


def _gh_json(args):
    out = subprocess.check_output(["gh", *args], text=True)
    return json.loads(out) if out.strip() else None


def _gh_checks(repo, branch):
    proc = subprocess.run(
        ["gh", "pr", "checks", branch, "--repo", repo, "--json", "bucket,name,state"],
        text=True, capture_output=True,
    )
    # 0 passed, 1 failed or not reported yet, 8 still running.
    if proc.returncode not in (0, 1, 8):
        raise subprocess.CalledProcessError(
            proc.returncode, proc.args, proc.stdout, proc.stderr)
    if not proc.stdout.strip():
        return []
    return json.loads(proc.stdout)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--branch", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--merge", action="store_true")
    parser.add_argument("--attempts", type=int, default=15)
    parser.add_argument("--merge-attempts", type=int, default=40)
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
        break
    else:
        raise SystemExit(f"lint run for {args.sha} did not appear")
    if not args.merge:
        return
    for _ in range(args.merge_attempts):
        state = verdict(_gh_checks(repo, args.branch))
        if state == "wait":
            time.sleep(args.interval)
            continue
        if state == "fail":
            raise SystemExit(f"lint failed for {args.sha}")
        subprocess.check_call([
            "gh", "pr", "merge", args.branch, "--repo", repo, "--merge",
            "--match-head-commit", args.sha,
        ])
        print(f"merged {args.branch} {args.sha}")
        return
    raise SystemExit(f"lint did not finish for {args.sha}")


if __name__ == "__main__":
    main()
