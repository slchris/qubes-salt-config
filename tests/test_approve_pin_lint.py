#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Chris Su
# SPDX-License-Identifier: MIT

import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load():
    spec = importlib.util.spec_from_file_location(
        "approve_pin_lint", ROOT / "scripts" / "approve_pin_lint.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


approve = load()
SHA = "abc123"


def run(event, sha, conclusion, status="completed", database_id=1):
    return {
        "databaseId": database_id,
        "event": event,
        "headSha": sha,
        "conclusion": conclusion,
        "status": status,
    }


class ApprovePinLintTest(unittest.TestCase):
    def test_missing_run_keeps_polling(self):
        with self.assertRaises(LookupError):
            approve.waiting_ids([], SHA)

    def test_other_commit_is_ignored(self):
        runs = [run("pull_request", "other", "action_required")]
        with self.assertRaises(LookupError):
            approve.waiting_ids(runs, SHA)

    def test_push_event_is_ignored(self):
        runs = [run("push", SHA, "action_required")]
        with self.assertRaises(LookupError):
            approve.waiting_ids(runs, SHA)

    def test_action_required_is_approved(self):
        runs = [
            run("pull_request", SHA, "success", database_id=1),
            run("pull_request", SHA, "action_required", database_id=2),
        ]
        self.assertEqual(approve.waiting_ids(runs, SHA), [2])

    def test_started_run_needs_nothing(self):
        runs = [run("pull_request", SHA, None, status="in_progress")]
        self.assertEqual(approve.waiting_ids(runs, SHA), [])

    def test_verdict_waits_until_checks_exist(self):
        self.assertEqual(approve.verdict([]), "wait")
        self.assertEqual(approve.verdict([{"bucket": "pending"}]), "wait")

    def test_verdict_passes_only_when_every_check_passed(self):
        checks = [{"bucket": "pass"}, {"bucket": "skipping"}]
        self.assertEqual(approve.verdict(checks), "pass")

    def test_verdict_fails_when_one_check_fails(self):
        checks = [{"bucket": "pass"}, {"bucket": "fail"}]
        self.assertEqual(approve.verdict(checks), "fail")

    def test_two_waiting_workflows_are_both_returned(self):
        runs = [
            run("pull_request", SHA, "action_required", database_id=8),
            run("pull_request", SHA, "action_required", database_id=9),
        ]
        self.assertEqual(approve.waiting_ids(runs, SHA), [8, 9])


if __name__ == "__main__":
    unittest.main()
