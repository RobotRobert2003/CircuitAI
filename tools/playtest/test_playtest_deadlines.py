"""Replay buffered log batches: polling must not forgive late milestones."""
import argparse
import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import playtest


class DeadlineTests(unittest.TestCase):
    def test_invalid_directory_fails_before_staging(self):
        for directory in ("", " ", str(playtest.REPO), str(playtest.REPO.parent)):
            with self.subTest(directory=directory), patch.object(playtest.shutil, "copy2") as copy:
                with self.assertRaises(SystemExit):
                    playtest.stage(argparse.Namespace(dir=directory))
                copy.assert_not_called()

    def test_missing_exact_map_fails_before_team_selection(self):
        args = argparse.Namespace(game="BAR test", map="Tundra Continents v1.1")
        with patch.object(playtest, "read_prod_script", return_value=({}, {})), \
                patch.object(playtest, "map_archive_present", return_value=False), \
                patch.object(playtest, "map_spots") as spots, \
                contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                playtest.write_script(args, Path("unused"))
            spots.assert_not_called()

    def test_zero_frame_exit_fails_without_waiting(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "infolog.txt").write_text("engine setup failed\n")
            checks = root / "checks.json"
            checks.write_text('{"expect": []}')
            args = argparse.Namespace(dir=directory, checks=str(checks), role="TECH",
                minutes=3, wall_minutes=1, keep_going=True, no_stop=True,
                poll=0, print_report=False, timeline_lines=10)
            with patch.object(playtest, "engine_alive", return_value=False), \
                    patch.object(playtest.time, "sleep") as sleep, \
                    contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(playtest.watch(args), 1)
                sleep.assert_not_called()
            self.assertIn("engine exited before the game started",
                (root / "report.md").read_text(encoding="utf-8"))

    def judge(self, event_frame, deadline=20, prefix=""):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            # Both lines arrive in one read, after the simulation has finished.
            (root / "infolog.txt").write_text(
                prefix + f"[f={event_frame:07d}] fusion finished\n[f=0041400] end\n")
            checks = root / "checks.json"
            checks.write_text(json.dumps({"expect": [{"key": "fusion",
                "pattern": "fusion finished", "scope": "any", "by_minute": deadline}]}))
            args = argparse.Namespace(dir=directory, checks=str(checks), role="AIR",
                minutes=23, wall_minutes=1, keep_going=True, no_stop=True,
                poll=0, print_report=False, timeline_lines=10)
            with patch.object(playtest, "engine_alive", return_value=False), contextlib.redirect_stdout(io.StringIO()):
                result = playtest.watch(args)
            return result, (root / "report.md").read_text(encoding="utf-8")

    def test_buffered_late_event_fails_deadline(self):
        result, report = self.judge(36075)
        self.assertEqual(result, 1)
        self.assertIn("not seen by 20.0 min", report)

    def test_event_exactly_at_deadline_passes(self):
        self.assertEqual(self.judge(36000)[0], 0)

    def test_early_event_in_batch_after_deadline_passes(self):
        self.assertEqual(self.judge(33643)[0], 0)

    def test_event_without_deadline_passes(self):
        self.assertEqual(self.judge(36075, None)[0], 0)

    def test_delayed_timely_record_uses_its_own_frame(self):
        self.assertEqual(self.judge(33643, prefix="[f=0041400] newer record\n")[0], 0)

    def test_event_after_missed_predecessor_fails_without_crashing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            info = root / "infolog.txt"
            info.write_text("[f=0036001] progress\n")
            checks = root / "checks.json"
            checks.write_text(json.dumps({"expect": [
                {"key": "first", "pattern": "first event", "scope": "any", "by_minute": 20},
                {"key": "second", "pattern": "second event", "scope": "any", "after_key": "first"}]}))
            args = argparse.Namespace(dir=directory, checks=str(checks), role="AIR",
                minutes=23, wall_minutes=1, keep_going=True, no_stop=True,
                poll=0, print_report=False, timeline_lines=10)
            def next_batch(_):
                with info.open("a") as stream:
                    stream.write("[f=0041400] second event\n")
            with patch.object(playtest, "engine_alive", return_value=True), \
                    patch.object(playtest.time, "sleep", side_effect=next_batch), \
                    contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(playtest.watch(args), 1)
            self.assertIn("came before 'first'", (root / "report.md").read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
