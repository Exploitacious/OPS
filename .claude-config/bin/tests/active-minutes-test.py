#!/usr/bin/env python3
"""Behavior tests for bin/active-minutes: billable working minutes from a session transcript.

Standard library only (unittest): no pytest is installed in CI, and a pytest
module run as `python3 <file>` prints nothing and exits 0, a vacuous green. This
file runs its tests under `python3 <file>` and exits non-zero on a failure; one
case below proves that by running the file itself.

Offline. The script runs as a subprocess on a synthetic transcript in a
temporary directory, so nothing here reads a real session transcript. Every run
gets TZ=UTC unless a case says otherwise, so no result depends on the box's own
zone.

Three groups. The display zone of the contiguous work blocks: the blocks print on
a time entry's Time line, so a wrong offset puts a wrong window on a billed
entry. The defect these tests pin: a fixed UTC-4 display read every block an hour
late once US Eastern went back to UTC-5 (an 18:05 ET start printed as 19:05).
The ACTIVE total never depended on the display zone, and one case holds that so
a later change cannot make it start to. The gap rule: every silent stretch over
the threshold is classified and printed with its cause, because a billed
figure that silently drops or silently adds an hour is a wrong bill. And the
hook mode (--since-last-entry --brief) with its --time-tool option.

The two Eastern changes the zone cases straddle (UTC instants):
  fall back   2026-11-01 06:00Z  02:00 EDT -> 01:00 EST
  spring fwd  2027-03-14 07:00Z  02:00 EST -> 03:00 EDT
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "active-minutes"
BLOCK = re.compile(r"^  (\d\d-\d\d \d\d:\d\d(?: [A-Za-z+\-0-9]{2,6})?) -> (\d\d-\d\d \d\d:\d\d(?: [A-Za-z+\-0-9]{2,6})?)  \(([\d.]+) min\)$")
NY = ("--zone", "America/New_York")
TIME_TOOL_NAME = "mcp__example-psa__psa__time_manage"
# Ticket forms: a ticket number (T plus eight digits, a dot, a sequence) and a numeric id.
# Built from parts: a literal in this shape reads as a real ticket number to a scanner.
TICKET_NO = "T" + "20260101" + ".0001"
TICKET_NO_OTHER = "T" + "20260101" + ".0099"
TICKET_ID = "10001"
TICKET_ID_OTHER = "10002"


def base_env(**extra):
    """The test process's environment with TZ pinned to UTC, then EXTRA on top."""
    env = {k: v for k, v in os.environ.items() if k != "TZ"}
    env.update(TZ="UTC", PYTHONDONTWRITEBYTECODE="1")
    env.update(extra)
    return env


def run(tmp_path, stamps, *args, env=None):
    """Run the script on a transcript of the given UTC stamps; return the
    CompletedProcess (text)."""
    transcript = tmp_path / "t.jsonl"
    transcript.write_text("".join(json.dumps({"timestamp": s}) + "\n" for s in stamps))
    return subprocess.run(
        [sys.executable, str(SCRIPT), str(transcript), *args],
        capture_output=True, text=True, env=env or base_env(), timeout=60,
    )


def every(start_hhmm_utc, count, step_min, day="2026-11-01"):
    """UTC stamps from a start time, one every step_min minutes (always under
    the 30 minute gap, so they form one block)."""
    h, m = map(int, start_hhmm_utc.split(":"))
    base = h * 60 + m
    return [f"{day}T{(base + i * step_min) // 60:02d}:{(base + i * step_min) % 60:02d}:00Z" for i in range(count)]


def active_line(proc):
    return next(l for l in proc.stdout.splitlines() if l.startswith("ACTIVE"))


# --- the gap rule: classify every gap, print its cause -----------------------
#
# An interactive session counts its whole span, pauses included. A gap that ends
# with a prompt the operator typed counts; a usage-limit hold, an overnight stop
# and an idle wait for a scheduled check do not, because a hold is not work and a
# break needs evidence. Records below carry the shapes real transcripts carry: a
# T3 queue-operation enqueue, a user message, an assistant message, an API error.

GAP_LINE = re.compile(r"^  (COUNTED|EXCLUDED) +([\d.]+) min  (.+?) -> (.+?)  \[([\dT:-]+)\]  (.*)$")


def iso(day_hhmm):
    """'11-06 14:10' -> a UTC stamp on 2026-11-06 (the cases stay in one month)."""
    day, hhmm = day_hhmm.split()
    return f"2026-{day}T{hhmm}:00Z"


def assistant(at, text="ok", **extra):
    return {"timestamp": iso(at), "type": "assistant", "message": {"content": [{"type": "text", "text": text}]}, **extra}


def human(at, text):
    return {"timestamp": iso(at), "type": "user", "promptSource": "sdk", "message": {"role": "user", "content": text}}


def tool_result(at):
    return {"timestamp": iso(at), "type": "user", "toolUseResult": {}, "message": {"content": [{"type": "tool_result", "tool_use_id": "x", "content": "ok"}]}}


def queued(at, text):
    return {"timestamp": iso(at), "type": "queue-operation", "operation": "enqueue", "content": text}


def api_error(at, error="rate_limit", text="You've hit your limit · resets 3am"):
    return {"timestamp": iso(at), "type": "assistant", "isApiErrorMessage": True, "error": error,
            "message": {"content": [{"type": "text", "text": text}]}}


def launch(at, tool_id):
    return {"timestamp": iso(at), "type": "assistant", "message": {"content": [{"type": "tool_use", "id": tool_id, "name": "Workflow", "input": {}}]}}


def notice(tool_id):
    return f"<task-notification>\n<task-id>w1</task-id>\n<tool-use-id>{tool_id}</tool-use-id>\n<status>completed</status>\n</task-notification>"


def time_create(at, ticket, tool=TIME_TOOL_NAME):
    return {"timestamp": iso(at), "type": "assistant", "message": {"content": [{"type": "tool_use", "id": "toolu_T" + at.replace(" ", "").replace(":", ""),
            "name": tool, "input": {"mode": "create", "ticket": ticket}}]}}


def overnight_task_records():
    # A background watcher launched at 20:05 whose notice arrives at 10:00 the
    # next morning: the transcript holds a launch record and nothing else.
    return [human("11-05 20:00", "watch the build"), launch("11-05 20:05", "toolu_NIGHT"), assistant("11-05 20:06", "Watching in the background."),
            queued("11-06 10:00", notice("toolu_NIGHT")), assistant("11-06 10:01", "It exited.")]


class ActiveMinutesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="active-minutes-test.")
        self.addCleanup(self.tmp.cleanup)
        self.tmp_path = Path(self.tmp.name)

    # --- helpers bound to this test's directory -----------------------------

    def run_stamps(self, stamps, *args, env=None):
        return run(self.tmp_path, stamps, *args, env=env)

    def parsed(self, proc):
        """(header, blocks) from stdout, blocks as (start, end, minutes) strings;
        asserts the run succeeded so a crash never reads as 'no blocks'."""
        self.assertEqual(proc.returncode, 0, proc.stderr)
        lines = proc.stdout.splitlines()
        header = next(l for l in lines if l.startswith("contiguous work blocks"))
        blocks = [BLOCK.match(l).groups() for l in lines[lines.index(header) + 1:] if l.strip()]
        return header, blocks

    def run_records(self, records, *args, name="t.jsonl", env=None):
        path = self.tmp_path / name
        path.write_text("".join(json.dumps(r) + "\n" for r in records))
        return subprocess.run([sys.executable, str(SCRIPT), str(path), *args], capture_output=True, text=True,
                              env=env or base_env(), timeout=60)

    def gaps_of(self, proc):
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return [GAP_LINE.match(l).groups() for l in proc.stdout.splitlines() if GAP_LINE.match(l)]

    def active_minutes(self, proc):
        return float(re.search(r"ACTIVE.*?: ([\d.]+) min", proc.stdout).group(1))

    # --- the display zone: converted per timestamp ---------------------------

    def test_block_before_the_fall_change_prints_in_edt(self):
        # 22:05Z to 22:35Z on 10-31 is 18:05 to 18:35 EDT (UTC-4).
        header, blocks = self.parsed(self.run_stamps(["2026-10-31T22:05:00Z", "2026-10-31T22:20:00Z", "2026-10-31T22:35:00Z"], *NY))
        self.assertEqual(header, "contiguous work blocks (America/New_York):")
        self.assertEqual(blocks, [("10-31 18:05 EDT", "10-31 18:35 EDT", "30.0")])

    def test_block_after_the_fall_change_prints_in_est(self):
        # The reported defect: 23:05Z on 11-02 is 18:05 EST (UTC-5), and used to
        # print as 19:05.
        _, blocks = self.parsed(self.run_stamps(["2026-11-02T23:05:00Z", "2026-11-02T23:20:00Z", "2026-11-02T23:35:00Z"], *NY))
        self.assertEqual(blocks, [("11-02 18:05 EST", "11-02 18:35 EST", "30.0")])

    def test_block_spanning_the_fall_change_prints_each_end_in_its_own_offset(self):
        # 04:30Z is 00:30 EDT; 07:00Z is 02:00 EST. The elapsed time is 150 min,
        # not the 90 min the two wall-clock readings alone suggest.
        _, blocks = self.parsed(self.run_stamps(every("04:30", 8, 20) + ["2026-11-01T07:00:00Z"], *NY))
        self.assertEqual(blocks, [("11-01 00:30 EDT", "11-01 02:00 EST", "150.0")])

    def test_block_spanning_the_spring_change_prints_each_end_in_its_own_offset(self):
        # 06:30Z is 01:30 EST; 07:30Z is 03:30 EDT (the 02:00 hour does not exist).
        stamps = ["2027-03-14T06:30:00Z", "2027-03-14T07:00:00Z", "2027-03-14T07:30:00Z"]
        _, blocks = self.parsed(self.run_stamps(stamps, *NY))
        self.assertEqual(blocks, [("03-14 01:30 EST", "03-14 03:30 EDT", "60.0")])

    def test_fall_back_hour_prints_distinct_times_for_distinct_instants(self):
        # 05:30Z and 06:30Z are one hour apart yet both read 01:30 on the wall; the
        # zone tag is what keeps the two ends of the block apart.
        _, blocks = self.parsed(self.run_stamps(["2026-11-01T05:30:00Z", "2026-11-01T06:00:00Z", "2026-11-01T06:30:00Z"], *NY))
        self.assertEqual(blocks, [("11-01 01:30 EDT", "11-01 01:30 EST", "60.0")])

    def test_two_blocks_either_side_of_the_change_each_use_their_own_offset(self):
        # A gap over 30 minutes splits the blocks; the 10-31 block is EDT, the
        # 11-02 block is EST.
        stamps = ["2026-10-31T22:05:00Z", "2026-10-31T22:30:00Z", "2026-11-02T23:05:00Z", "2026-11-02T23:30:00Z"]
        _, blocks = self.parsed(self.run_stamps(stamps, *NY))
        self.assertEqual(blocks, [
            ("10-31 18:05 EDT", "10-31 18:30 EDT", "25.0"),
            ("11-02 18:05 EST", "11-02 18:30 EST", "25.0"),
        ])

    def test_host_time_zone_does_not_change_the_display(self):
        # A named --zone is the display zone, never the box's own TZ. (The default
        # without --zone does follow TZ: the cases below.)
        env = base_env(TZ="Asia/Tokyo")
        _, blocks = self.parsed(self.run_stamps(["2026-11-02T23:05:00Z", "2026-11-02T23:35:00Z"], *NY, env=env))
        self.assertEqual(blocks, [("11-02 18:05 EST", "11-02 18:35 EST", "30.0")])

    # --- the zone default: --zone, then TZ, then the machine, then UTC --------

    def test_default_zone_follows_a_valid_tz(self):
        stamps = ["2026-11-02T23:05:00Z", "2026-11-02T23:35:00Z"]
        header, blocks = self.parsed(self.run_stamps(stamps, env=base_env(TZ="America/New_York")))
        self.assertEqual(header, "contiguous work blocks (America/New_York):")
        self.assertEqual(blocks, [("11-02 18:05 EST", "11-02 18:35 EST", "30.0")])
        header, blocks = self.parsed(self.run_stamps(stamps, env=base_env(TZ="Asia/Tokyo")))
        self.assertEqual(header, "contiguous work blocks (Asia/Tokyo):")
        self.assertEqual(blocks, [("11-03 08:05 JST", "11-03 08:35 JST", "30.0")])

    def test_zone_option_beats_tz_and_names_the_header(self):
        stamps = ["2026-11-02T23:05:00Z", "2026-11-02T23:35:00Z"]
        header, blocks = self.parsed(self.run_stamps(stamps, "--zone", "Europe/London", env=base_env(TZ="Asia/Tokyo")))
        self.assertEqual(header, "contiguous work blocks (Europe/London):")
        self.assertEqual(blocks, [("11-02 23:05 GMT", "11-02 23:35 GMT", "30.0")])

    def machine_expectation(self):
        """The first block's start as this box's own zone prints it, asked of a
        fresh interpreter with TZ unset, so the case holds on any host zone."""
        code = ("import datetime; print(datetime.datetime(2026, 11, 2, 23, 5, tzinfo=datetime.timezone.utc)"
                ".astimezone().strftime('%m-%d %H:%M %Z'))")
        env = {k: v for k, v in base_env().items() if k != "TZ"}
        out = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, env=env, timeout=30)
        self.assertEqual(out.returncode, 0, out.stderr)
        return out.stdout.strip()

    def test_unset_or_invalid_tz_falls_back_to_the_machine_zone(self):
        stamps = ["2026-11-02T23:05:00Z", "2026-11-02T23:35:00Z"]
        want = self.machine_expectation()
        unset = {k: v for k, v in base_env().items() if k != "TZ"}
        _, blocks = self.parsed(self.run_stamps(stamps, env=unset))
        self.assertEqual(blocks[0][0], want)
        # A TZ that names no zone is ignored, not an error: the machine zone is used.
        _, blocks = self.parsed(self.run_stamps(stamps, env=base_env(TZ="Not/AZone")))
        self.assertEqual(blocks[0][0], want)

    def test_no_machine_zone_falls_back_to_utc(self):
        # Hide /etc/localtime from the script (a container or a platform without it):
        # with no zone anywhere the display is UTC, never a guessed city.
        transcript = self.tmp_path / "t.jsonl"
        transcript.write_text("".join(json.dumps({"timestamp": s}) + "\n" for s in ["2026-11-02T23:05:00Z", "2026-11-02T23:35:00Z"]))
        snippet = (
            "import builtins, os, runpy, sys\n"
            "real_open = builtins.open\n"
            "def fake_open(path, *a, **k):\n"
            "    if str(path) == '/etc/localtime': raise FileNotFoundError(path)\n"
            "    return real_open(path, *a, **k)\n"
            "builtins.open = fake_open\n"
            "def no_link(path, *a, **k): raise OSError('no link')\n"
            "os.readlink = no_link\n"
            "sys.argv = [%r, %r]\n"
            "runpy.run_path(%r, run_name='__main__')\n" % (str(SCRIPT), str(transcript), str(SCRIPT)))
        for tz in (None, "Not/AZone"):
            with self.subTest(tz=tz):
                env = {k: v for k, v in base_env().items() if k != "TZ"}
                if tz:
                    env["TZ"] = tz
                proc = subprocess.run([sys.executable, "-c", snippet], capture_output=True, text=True, env=env, timeout=60)
                header, blocks = self.parsed(proc)
                self.assertEqual(header, "contiguous work blocks (UTC):")
                self.assertEqual(blocks, [("11-02 23:05 UTC", "11-02 23:35 UTC", "30.0")])

    def test_zone_and_tz_offset_cannot_be_combined_and_an_unknown_zone_stops_the_run(self):
        stamps = ["2026-11-02T23:05:00Z", "2026-11-02T23:35:00Z"]
        both = self.run_stamps(stamps, "--zone", "America/New_York", "--tz-offset", "-5")
        self.assertEqual(both.returncode, 2)
        self.assertIn("not allowed with", both.stderr)
        unknown = self.run_stamps(stamps, "--zone", "Not/AZone")
        self.assertEqual(unknown.returncode, 2)
        self.assertEqual(len(unknown.stderr.strip().splitlines()), 1, unknown.stderr)
        self.assertIn("Not/AZone", unknown.stderr)
        self.assertNotIn("contiguous work blocks", unknown.stdout)

    # --- --tz-offset: the explicit fixed-offset override ----------------------

    def test_tz_offset_override_is_fixed_and_labeled(self):
        # -4 kept on purpose for post-change data: an operator who asks for it
        # gets it, with no zone tag, and the header says what was used.
        header, blocks = self.parsed(self.run_stamps(["2026-11-02T23:05:00Z", "2026-11-02T23:35:00Z"], "--tz-offset", "-4"))
        self.assertEqual(header, "contiguous work blocks (tz-offset -4):")
        self.assertEqual(blocks, [("11-02 19:05", "11-02 19:35", "30.0")])

    def test_tz_offset_override_applies_one_offset_across_the_change(self):
        # Fixed means fixed: both ends of the spanning block use -5.
        stamps = every("04:30", 8, 20) + ["2026-11-01T07:00:00Z"]
        header, blocks = self.parsed(self.run_stamps(stamps, "--tz-offset", "-5"))
        self.assertEqual(header, "contiguous work blocks (tz-offset -5):")
        self.assertEqual(blocks, [("10-31 23:30", "11-01 02:00", "150.0")])

    def test_tz_offset_zero_and_fractional_are_honored(self):
        stamps = ["2026-11-02T23:05:00Z", "2026-11-02T23:35:00Z"]
        header, blocks = self.parsed(self.run_stamps(stamps, "--tz-offset", "0"))
        self.assertEqual(header, "contiguous work blocks (tz-offset +0):")
        self.assertEqual(blocks, [("11-02 23:05", "11-02 23:35", "30.0")])
        header, blocks = self.parsed(self.run_stamps(stamps, "--tz-offset", "5.5"))
        self.assertEqual(header, "contiguous work blocks (tz-offset +5.5):")
        self.assertEqual(blocks, [("11-03 04:35", "11-03 05:05", "30.0")])

    def test_tz_offset_out_of_range_stops_the_run(self):
        # An unusable override must stop the run, never fall back to another zone
        # and print blocks the operator did not ask for.
        for bad in ["24", "-24", "30", "nan", "inf"]:
            with self.subTest(bad=bad):
                proc = self.run_stamps(["2026-11-02T23:05:00Z", "2026-11-02T23:35:00Z"], f"--tz-offset={bad}")
                self.assertEqual(proc.returncode, 2)
                self.assertIn("--tz-offset: need hours strictly between -24 and 24", proc.stderr)
                self.assertNotIn("contiguous work blocks", proc.stdout)

    # --- the display zone never touches the measurement ------------------------

    def test_active_total_and_gap_rule_are_identical_in_every_display_zone(self):
        # Two blocks (25 min each) around a 30 min+ gap: the total counts the
        # blocks and drops the gap, whatever zone prints them.
        stamps = ["2026-10-31T22:05:00Z", "2026-10-31T22:30:00Z", "2026-11-02T23:05:00Z", "2026-11-02T23:30:00Z"]
        default = self.run_stamps(stamps, *NY)
        self.assertIn("50.0 min = 0.8333 h -> 0.83 h", active_line(default))
        self.assertIn("excluded gaps     : 1", default.stdout)
        for offset in ("-4", "-5", "0", "5.5", "-12", "13"):
            fixed = self.run_stamps(stamps, "--tz-offset", offset)
            self.assertEqual(active_line(fixed), active_line(default), offset)
            self.assertIn("excluded gaps     : 1", fixed.stdout, offset)
        for zone in ("Asia/Tokyo", "Europe/London", "UTC"):
            named = self.run_stamps(stamps, "--zone", zone)
            self.assertEqual(active_line(named), active_line(default), zone)

    def test_a_bad_option_exits_2_even_when_the_transcript_is_too_short(self):
        # The zone and offset are checked before the transcript is read, so a bad
        # --tz-offset is a usage error (2), not the short-transcript exit (1).
        proc = self.run_stamps(["2026-11-02T23:05:00Z"], "--tz-offset", "99")
        self.assertEqual(proc.returncode, 2)
        self.assertIn("--tz-offset: need hours strictly between -24 and 24", proc.stderr)

    def test_billable_hours_round_to_the_nearest_hundredth(self):
        proc = self.run_stamps(["2026-11-06T10:00:00Z", "2026-11-06T10:20:00Z", "2026-11-06T10:40:00Z"])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("40.0 min = 0.6667 h -> 0.67 h", active_line(proc))
        boundary = self.run_stamps(["2026-11-06T10:00:00Z", "2026-11-06T10:06:00Z"])
        self.assertIn("6.0 min = 0.1000 h -> 0.10 h", active_line(boundary))

    # --- failure and help -----------------------------------------------------

    def test_missing_zone_database_stops_the_run_and_names_the_override(self):
        # With no system tz database and no tzdata package, a named zone cannot
        # load. That must be one named line pointing at --tz-offset, not blocks
        # printed in a guessed zone. PYTHONTZPATH empties the system search path,
        # and a stub tzdata package that fails to import shadows any installed one
        # (zoneinfo reads an ImportError from tzdata as "no zone"), so this case
        # runs on every machine instead of skipping where tzdata is installed.
        empty = self.tmp_path / "no-zoneinfo"
        empty.mkdir()
        stub = self.tmp_path / "stub" / "tzdata"
        stub.mkdir(parents=True)
        (stub / "__init__.py").write_text('raise ImportError("tzdata hidden by the test")\n')
        pythonpath = os.pathsep.join(filter(None, [str(stub.parent), os.environ.get("PYTHONPATH")]))
        stamps = ["2026-11-02T23:05:00Z", "2026-11-02T23:35:00Z"]
        # Both ways to name a zone hit it: the option, and the TZ variable.
        for label, args, tz in (("--zone", NY, "UTC"), ("TZ", (), "America/New_York")):
            with self.subTest(named_by=label):
                env = base_env(TZ=tz, PYTHONTZPATH=str(empty), PYTHONPATH=pythonpath)
                proc = self.run_stamps(stamps, *args, env=env)
                self.assertEqual(proc.returncode, 2)
                self.assertEqual(len(proc.stderr.strip().splitlines()), 1, proc.stderr)
                self.assertIn("time zone database", proc.stderr)
                self.assertTrue("America/New_York" in proc.stderr or "UTC" in proc.stderr)
                self.assertIn("--tz-offset", proc.stderr)
                self.assertNotIn("contiguous work blocks", proc.stdout)
        # The documented escape works on the same machine.
        env = base_env(TZ="America/New_York", PYTHONTZPATH=str(empty), PYTHONPATH=pythonpath)
        _, blocks = self.parsed(self.run_stamps(stamps, "--tz-offset", "-5", env=env))
        self.assertEqual(blocks, [("11-02 18:05", "11-02 18:35", "30.0")])

    def test_help_and_docstring_describe_the_zone_default(self):
        out = subprocess.run([sys.executable, str(SCRIPT), "--help"], capture_output=True, text=True, env=base_env(), timeout=60)
        self.assertEqual(out.returncode, 0)
        flat = " ".join(out.stdout.split())
        self.assertIn("--zone NAME", flat)
        self.assertIn("$TZ", flat)
        self.assertIn("daylight saving", flat)
        self.assertIn("--time-tool NAME", flat)
        self.assertNotIn("default -4", flat)   # the old fixed default
        self.assertNotIn("US Eastern DST", flat)
        doc = " ".join(SCRIPT.read_text().split('"""')[1].split())
        for needle in ("--zone NAME", "--tz-offset H", "--time-tool NAME", "else UTC"):
            self.assertIn(needle, doc, needle)

    # --- the gap rule -----------------------------------------------------------

    def test_a_45_minute_interactive_pause_counts_as_work(self):
        # The operator reads a report and works a console for 45 minutes, then types
        # the next message. The whole span is billed, pauses included. 10 min of
        # chat before, the 45 min pause, 10 min of chat after.
        records = [human("11-06 14:00", "run the audit"), assistant("11-06 14:10", "Audit done; check the portal and tell me what it shows."),
                   human("11-06 14:55", "The portal shows two failures."), assistant("11-06 15:05", "Fixed.")]
        proc = self.run_records(records)
        self.assertEqual(self.active_minutes(proc), 65.0)           # 10 + 45 + 10
        self.assertIn("counted gaps      : 1, total 45.0 min", proc.stdout)
        self.assertIn("excluded gaps     : 0", proc.stdout)
        [(verdict, mins, _, _, _, cause)] = self.gaps_of(proc)
        self.assertEqual((verdict, mins), ("COUNTED", "45.0"))
        self.assertTrue(cause.startswith("attended pause"))
        self.assertIn("The portal shows two failures", cause)
        _, blocks = self.parsed(proc)
        self.assertEqual(len(blocks), 1)                      # the counted gap does not split the block

    def test_the_same_45_minutes_are_excluded_under_the_strict_old_rule(self):
        records = [human("11-06 14:00", "run the audit"), assistant("11-06 14:10"), human("11-06 14:55", "ok"), assistant("11-06 15:05")]
        proc = self.run_records(records, "--strict")
        self.assertEqual(self.active_minutes(proc), 20.0)
        self.assertEqual([g[0] for g in self.gaps_of(proc)], ["EXCLUDED"])

    def test_a_usage_limit_hold_is_excluded_with_its_cause_even_when_a_typed_prompt_ends_it(self):
        # The agent hits a limit at 23:17 and the operator types "continue" at 09:30.
        # Nobody worked in between and a hold needs evidence of work to count, so
        # the 10 h 13 min are listed and left out.
        records = [human("11-05 22:50", "keep going"), assistant("11-05 23:10", "Working."), api_error("11-05 23:17"),
                   human("11-06 09:30", "continue"), assistant("11-06 09:40", "Resumed.")]
        proc = self.run_records(records)
        [(verdict, mins, _, _, _, cause)] = self.gaps_of(proc)
        self.assertTrue(verdict == "EXCLUDED" and mins == "613.0")
        self.assertTrue(cause.startswith("usage-limit hold"))
        self.assertIn("hit your limit", cause)
        self.assertEqual(self.active_minutes(proc), 27.0 + 10.0)   # 22:50 to 23:17, then 09:30 to 09:40
        _, blocks = self.parsed(proc)
        self.assertEqual(len(blocks), 2)

    def test_another_provider_error_hold_is_excluded_by_its_error_name(self):
        records = [assistant("11-06 10:00"), api_error("11-06 10:05", error="authentication_failed", text="OAuth session expired"),
                   human("11-06 11:30", "I re-logged in"), assistant("11-06 11:35")]
        [(verdict, _, _, _, _, cause)] = self.gaps_of(self.run_records(records))
        self.assertEqual(verdict, "EXCLUDED")
        self.assertIn("provider error hold (authentication_failed)", cause)

    def test_a_limit_hold_ended_by_a_fleet_notice_is_still_a_hold(self):
        records = [assistant("11-06 08:00"), api_error("11-06 08:05"), queued("11-06 12:00", "Automated fleet notice: capacity cleared, continue."), assistant("11-06 12:01")]
        [(verdict, _, _, _, _, cause)] = self.gaps_of(self.run_records(records))
        self.assertEqual(verdict, "EXCLUDED")
        self.assertTrue(cause.startswith("usage-limit hold"))

    def test_an_overnight_gap_over_the_attended_ceiling_is_listed_and_excluded(self):
        records = [human("11-05 21:00", "go"), assistant("11-05 21:20", "Done."), human("11-06 08:10", "Morning, next one."), assistant("11-06 08:20")]
        proc = self.run_records(records)
        [(verdict, mins, _, _, key, cause)] = self.gaps_of(proc)
        self.assertEqual(verdict, "EXCLUDED")
        self.assertIn("over 4 h", cause)
        self.assertIn("Morning, next one", cause)
        self.assertEqual(self.active_minutes(proc), 30.0)
        # --keep, given by the operator's evidence, counts exactly that gap.
        kept = self.run_records(records, "--keep", key)
        self.assertEqual([g[0] for g in self.gaps_of(kept)], ["COUNTED"])
        self.assertEqual(self.active_minutes(kept), 30.0 + float(mins))
        self.assertIn("kept", self.gaps_of(kept)[0][5])
        # So does a higher ceiling.
        self.assertEqual([g[0] for g in self.gaps_of(self.run_records(records, "--attended-max", "12"))], ["COUNTED"])

    def test_the_ceiling_is_inclusive_at_exactly_four_hours(self):
        records = [assistant("11-06 10:00"), human("11-06 14:00", "back at it"), assistant("11-06 14:05")]
        self.assertEqual([g[0] for g in self.gaps_of(self.run_records(records))], ["COUNTED"])
        records = [assistant("11-06 10:00"), human("11-06 14:01", "back at it"), assistant("11-06 14:05")]
        self.assertEqual([g[0] for g in self.gaps_of(self.run_records(records))], ["EXCLUDED"])

    def test_a_stated_break_before_the_gap_is_excluded_and_quoted(self):
        records = [human("11-06 12:00", "Going to lunch, back in an hour"), assistant("11-06 12:05", "Understood."),
                   human("11-06 13:20", "ok what did you find"), assistant("11-06 13:25")]
        [(verdict, _, _, _, _, cause)] = self.gaps_of(self.run_records(records))
        self.assertEqual(verdict, "EXCLUDED")
        self.assertIn("operator-stated break", cause)
        self.assertIn("Going to lunch", cause)

    def test_a_break_remark_older_than_an_hour_does_not_excuse_the_gap(self):
        # "lunch" was said at 09:00; the gap starts at 11:00 after real work.
        records = [human("11-06 09:00", "Going to lunch soon, just do the audit"), assistant("11-06 09:20"), assistant("11-06 09:50"),
                   assistant("11-06 10:20"), assistant("11-06 10:50"), assistant("11-06 11:00", "Audit done."),
                   human("11-06 11:50", "thanks, now the next one"), assistant("11-06 11:55")]
        [(verdict, _, _, _, _, cause)] = self.gaps_of(self.run_records(records))
        self.assertTrue(verdict == "COUNTED" and cause.startswith("attended pause"))

    def test_a_stated_break_when_the_operator_returns_is_excluded(self):
        records = [assistant("11-06 12:00", "Report posted."), human("11-06 13:10", "I'm back, what do you need from me?"), assistant("11-06 13:15")]
        [(verdict, _, _, _, _, cause)] = self.gaps_of(self.run_records(records))
        self.assertEqual(verdict, "EXCLUDED")
        self.assertIn("when the operator returned", cause)

    def test_a_curly_apostrophe_in_the_return_remark_still_matches(self):
        records = [assistant("11-06 12:00"), human("11-06 13:10", "I’m back"), assistant("11-06 13:15")]
        self.assertEqual([g[0] for g in self.gaps_of(self.run_records(records))], ["EXCLUDED"])

    def test_a_gap_ended_by_a_harness_message_is_idle_time(self):
        # Each shape is text OPS or T3 itself sends into a thread as if typed.
        cases = [
            ("Automated fleet notice: pool capacity cleared", "fleet notice"),
            ("Context handoff (manual_context): Provider context handoff. Thread: abc", "context handoff"),
            ("/compact", "compact command"),
            ("Delegated task node:delegated-task:x reached a terminal state.", "delegated-task notice"),
            ("FYI from the example foreman thread: the port is live", "cross-thread message"),
            ("Scheduled one-time check from the example thread abc", "scheduled check"),
            ("This session is being continued from a previous conversation.", "session continuation"),
            ("Continue the standing work. Read the freshest durable anchor, then execute NEXT ACTION.", "resume baton"),
            ("## RESUME PROTOCOL (updated 2026-11-06 12:00Z)", "resume baton"),
        ]
        for prompt, label in cases:
            with self.subTest(label=label, prompt=prompt):
                records = [assistant("11-06 10:00", "Waiting for the window."), queued("11-06 12:00", prompt), human("11-06 12:00", prompt), assistant("11-06 12:05")]
                [(verdict, mins, _, _, _, cause)] = self.gaps_of(self.run_records(records))
                self.assertTrue(verdict == "EXCLUDED" and mins == "120.0")
                self.assertTrue(cause.startswith(f"idle until {label}"), cause)

    def test_a_compaction_summary_is_not_a_typed_prompt(self):
        summary = {"timestamp": iso("11-06 12:00"), "type": "user", "isCompactSummary": True, "isVisibleInTranscriptOnly": True,
                   "message": {"role": "user", "content": "The summarized conversation included..."}}
        records = [assistant("11-06 10:00"), summary, assistant("11-06 12:01")]
        [(verdict, _, _, _, _, cause)] = self.gaps_of(self.run_records(records))
        self.assertEqual(verdict, "EXCLUDED")
        self.assertIn("compaction summary", cause)

    def test_a_long_tool_call_with_no_prompt_is_listed_with_a_cause_that_says_what_it_could_be(self):
        # A call, its result 45 minutes later and nothing between looks the same
        # whether a foreground call ran, a permission prompt waited or a hold went
        # unrecorded, and counting it would bill holds. It stays EXCLUDED, but the
        # cause must not read as if the agent simply resumed: it names the three
        # shapes and the way to settle it.
        records = [human("11-06 14:00", "run the long check"), launch("11-06 14:01", "toolu_FG"), tool_result("11-06 14:46"), assistant("11-06 14:47", "Done.")]
        proc = self.run_records(records)
        [(verdict, mins, _, _, _, cause)] = self.gaps_of(proc)
        self.assertTrue(verdict == "EXCLUDED" and mins == "45.0" and cause.startswith("no prompt evidence"))
        for needle in ("long tool call", "permission wait", "--also", "--keep"):
            self.assertIn(needle, cause)
        self.assertEqual(self.active_minutes(proc), 2.0)

    def test_a_tool_result_is_not_a_prompt(self):
        # Nobody typed anything: the gap ends with a tool result, then the agent.
        records = [assistant("11-06 10:00"), tool_result("11-06 11:00"), assistant("11-06 11:01")]
        [(verdict, _, _, _, _, cause)] = self.gaps_of(self.run_records(records))
        self.assertTrue(verdict == "EXCLUDED" and cause.startswith("no prompt evidence"))

    def test_a_background_task_that_ran_through_the_gap_counts_as_unattended_agent_work(self):
        # The foreman launched a workflow at 10:00 and waited; its notice arrived at
        # 11:10. Unattended agent time counts like attended time.
        records = [human("11-06 09:50", "run the sweep"), launch("11-06 10:00", "toolu_AAA"), assistant("11-06 10:01", "Running in the background."),
                   queued("11-06 11:10", notice("toolu_AAA")), assistant("11-06 11:11", "Finished.")]
        proc = self.run_records(records)
        [(verdict, mins, _, _, _, cause)] = self.gaps_of(proc)
        self.assertTrue(verdict == "COUNTED" and mins == "69.0" and cause.startswith("background task"))

    def test_a_task_notice_with_no_launch_in_the_transcript_needs_evidence(self):
        records = [assistant("11-06 10:00"), queued("11-06 11:10", notice("toolu_ZZZ")), assistant("11-06 11:11")]
        [(verdict, _, _, _, _, cause)] = self.gaps_of(self.run_records(records))
        self.assertEqual(verdict, "EXCLUDED")
        self.assertIn("launch is not in this transcript", cause)
        self.assertIn("--also", cause)

    def test_an_overnight_background_task_with_only_a_launch_record_is_listed_not_counted(self):
        # The launch-only branch once billed 14 hours. The measure bills work that
        # ran, not elapsed time, so past the 4 h ceiling a launch record is not
        # enough.
        proc = self.run_records(overnight_task_records())
        [(verdict, mins, _, _, _, cause)] = self.gaps_of(proc)
        self.assertTrue(verdict == "EXCLUDED" and mins == "834.0")
        for needle in ("launch record is not work", "--also", "--keep"):
            self.assertIn(needle, cause)
        self.assertEqual(self.active_minutes(proc), 7.0)          # 20:00 to 20:06, then 10:00 to 10:01

    def test_an_overnight_background_task_counts_with_keep_evidence(self):
        records = overnight_task_records()
        [(_, _, _, _, key, _)] = self.gaps_of(self.run_records(records))
        kept = self.run_records(records, "--keep", key)
        self.assertEqual([g[0] for g in self.gaps_of(kept)], ["COUNTED"])
        self.assertEqual(self.active_minutes(kept), 841.0)

    def test_an_overnight_background_task_counts_when_lane_trace_shows_work_inside_the_gap(self):
        # The lane transcripts (--also) show the task working through the night: an
        # event every 20 minutes, so there is no gap left to classify and the whole
        # span is work, counted once.
        records = overnight_task_records()
        lane = self.tmp_path / "lane.jsonl"
        stamps = ["2026-11-05T20:25:00Z"]
        while stamps[-1] < "2026-11-06T09:45:00Z":
            h, m = int(stamps[-1][11:13]), int(stamps[-1][14:16]) + 20
            day = stamps[-1][:10]
            if m >= 60: h, m = h + 1, m - 60
            if h >= 24: h, day = h - 24, "2026-11-06"
            stamps.append(f"{day}T{h:02d}:{m:02d}:00Z")
        lane.write_text("".join(json.dumps({"timestamp": t}) + "\n" for t in stamps))
        with_lane = self.run_records(records, "--also", str(lane))
        self.assertEqual(self.gaps_of(with_lane), [])
        self.assertEqual(self.active_minutes(with_lane), 841.0)

    def test_a_background_task_gap_is_counted_up_to_the_ceiling_and_listed_past_it(self):
        # Inclusive at exactly 4 h, as for a typed prompt; one minute more is listed.
        def records(hhmm):
            # The gap runs from the 06:06 assistant record to the notice at hhmm.
            h, m = map(int, hhmm.split(":"))
            return [human("11-06 06:00", "run it"), launch("11-06 06:05", "toolu_C"), assistant("11-06 06:06", "Running."),
                    queued(f"11-06 {hhmm}", notice("toolu_C")), assistant(f"11-06 {h:02d}:{m + 1:02d}")]
        self.assertEqual([g[0] for g in self.gaps_of(self.run_records(records("10:06")))], ["COUNTED"])
        self.assertEqual([g[0] for g in self.gaps_of(self.run_records(records("10:07")))], ["EXCLUDED"])
        # The ceiling is the same option as the attended pause's.
        self.assertEqual([g[0] for g in self.gaps_of(self.run_records(records("10:07"), "--attended-max", "5"))], ["COUNTED"])

    def test_lane_transcripts_passed_with_also_fill_the_gap_with_real_trace(self):
        # The foreman is silent from 10:00 to 11:10 but a workflow lane worked the
        # whole time: no gap, the hour counts, and nothing is double-counted.
        main = [human("11-06 09:50", "run the sweep"), assistant("11-06 10:00"), assistant("11-06 11:10")]
        lane = self.tmp_path / "lane.jsonl"
        lane.write_text("".join(json.dumps({"timestamp": iso(f"11-06 {h:02d}:{m:02d}")}) + "\n" for h, m in [(10, 5), (10, 25), (10, 45), (11, 5)]))
        plain = self.run_records(main)
        with_lane = self.run_records(main, "--also", str(lane))
        self.assertEqual([g[0] for g in self.gaps_of(plain)], ["EXCLUDED"])       # alone, the silence is a gap
        self.assertEqual(self.gaps_of(with_lane), [])
        self.assertEqual(self.active_minutes(with_lane), 80.0)     # 09:50 to 11:10, once

    def test_an_unreadable_also_file_stops_the_run(self):
        proc = self.run_records([assistant("11-06 10:00"), assistant("11-06 10:05")], "--also", str(self.tmp_path / "missing.jsonl"))
        self.assertTrue(proc.returncode == 2 and "--also" in proc.stderr)

    def test_drop_forces_an_attended_gap_out(self):
        records = [assistant("11-06 10:00"), human("11-06 10:50", "ok"), assistant("11-06 10:55")]
        [(_, _, _, _, key, _)] = self.gaps_of(self.run_records(records))
        dropped = self.run_records(records, "--drop", key)
        self.assertEqual([g[0] for g in self.gaps_of(dropped)], ["EXCLUDED"])
        self.assertIn("--drop", self.gaps_of(dropped)[0][5])
        self.assertEqual(self.active_minutes(dropped), 5.0)

    def test_every_excluded_gap_is_listed_with_its_cause_and_none_hides(self):
        records = [assistant("11-06 08:00"), api_error("11-06 08:05"), human("11-06 10:00", "continue"), assistant("11-06 10:05"),
                   queued("11-06 12:00", "Scheduled one-time check from the example thread x"), assistant("11-06 12:01"), human("11-06 13:00", "next"), assistant("11-06 13:05")]
        proc = self.run_records(records)
        excl = [g for g in self.gaps_of(proc) if g[0] == "EXCLUDED"]
        n = int(re.search(r"excluded gaps     : (\d+)", proc.stdout).group(1))
        self.assertTrue(n == len(excl) == 2 and all(g[5] for g in excl))

    def test_gaps_at_or_under_the_threshold_are_never_classified(self):
        records = [assistant("11-06 10:00"), assistant("11-06 10:30"), assistant("11-06 11:00")]
        proc = self.run_records(records)
        self.assertEqual(self.gaps_of(proc), [])
        self.assertEqual(self.active_minutes(proc), 60.0)
        self.assertNotIn("gaps over", proc.stdout)

    def test_the_gap_threshold_option_still_moves_the_classification_line(self):
        records = [assistant("11-06 10:00"), human("11-06 10:20", "ok"), assistant("11-06 10:21")]
        self.assertEqual(self.gaps_of(self.run_records(records)), [])
        self.assertEqual([g[0] for g in self.gaps_of(self.run_records(records, "--gap", "600"))], ["COUNTED"])

    def test_an_old_api_error_does_not_excuse_a_later_gap(self):
        # The error at 08:05 was retried and the session went on; the later pause is
        # an ordinary attended one.
        records = [assistant("11-06 08:00"), api_error("11-06 08:05"), human("11-06 08:10", "retry"), assistant("11-06 08:15", "Done."),
                   human("11-06 09:10", "next"), assistant("11-06 09:15")]
        [(verdict, _, _, _, _, cause)] = self.gaps_of(self.run_records(records))
        self.assertTrue(verdict == "COUNTED" and cause.startswith("attended pause"))

    # --- hook mode: --since-last-entry --brief ---------------------------------

    def test_brief_reports_unlogged_minutes_since_the_last_time_create(self):
        records = [human("11-06 09:00", "start"), assistant("11-06 09:20"), time_create("11-06 09:25", TICKET_NO),
                   assistant("11-06 09:30"), assistant("11-06 09:45"), assistant("11-06 10:00")]
        proc = self.run_records(records, "--since-last-entry", "--brief", "--ticket", TICKET_NO, "--now", iso("11-06 10:01"))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        line = proc.stdout.strip()
        self.assertEqual(line.count("\n"), 0)
        self.assertIn("unlogged_min=35.0", line)                      # 09:25 to 10:00
        self.assertIn("last_entry=2026-11-06T09:25:00+00:00", line)
        self.assertIn("ticket_entry_age_min=36.0", line)              # 09:25 to 10:01

    def test_brief_with_no_prior_entry_measures_from_the_first_event(self):
        records = [human("11-06 09:00", "start"), assistant("11-06 09:20"), assistant("11-06 09:40")]
        proc = self.run_records(records, "--since-last-entry", "--brief", "--now", iso("11-06 09:41"))
        for needle in ("unlogged_min=40.0", "last_entry=none", "ticket_entry_age_min=none"):
            self.assertIn(needle, proc.stdout)

    def test_a_failed_time_create_does_not_reset_the_unlogged_window(self):
        create = time_create("11-06 09:25", TICKET_NO)
        failure = tool_result("11-06 09:26")
        result = failure["message"]["content"][0]
        result.update(tool_use_id=create["message"]["content"][0]["id"], is_error=True, content="create failed")
        records = [human("11-06 09:00", "start"), assistant("11-06 09:20"), create,
                   failure, assistant("11-06 09:40")]
        proc = self.run_records(records, "--since-last-entry", "--brief", "--ticket", TICKET_NO)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        for needle in ("unlogged_min=40.0", "last_entry=none", "ticket_entry_age_min=none"):
            self.assertIn(needle, proc.stdout)

    def test_a_create_without_a_ticket_does_not_reset_the_unlogged_window(self):
        records = [human("11-06 09:00", "start"), assistant("11-06 09:20"),
                   time_create("11-06 09:25", None), assistant("11-06 09:40")]
        proc = self.run_records(records, "--since-last-entry", "--brief")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("unlogged_min=40.0", proc.stdout)
        self.assertIn("last_entry=none", proc.stdout)

    def test_brief_only_matches_the_ticket_asked_about(self):
        records = [assistant("11-06 09:00"), time_create("11-06 09:05", TICKET_NO_OTHER), assistant("11-06 09:10")]
        proc = self.run_records(records, "--since-last-entry", "--brief", "--ticket", TICKET_NO, "--now", iso("11-06 09:11"))
        self.assertIn("last_entry=2026-11-06T09:05:00+00:00", proc.stdout)
        self.assertIn("ticket_entry_age_min=none", proc.stdout)

    def test_brief_does_not_treat_a_time_list_or_overview_as_a_create(self):
        listing = {"timestamp": iso("11-06 09:05"), "type": "assistant", "message": {"content": [{"type": "tool_use", "id": "toolu_L",
                   "name": TIME_TOOL_NAME, "input": {"mode": "overview"}}]}}
        records = [assistant("11-06 09:00"), listing, assistant("11-06 09:10")]
        proc = self.run_records(records, "--since-last-entry", "--brief", "--now", iso("11-06 09:11"))
        self.assertIn("last_entry=none", proc.stdout)

    def brief_for(self, logged, closing):
        records = [human("11-06 09:00", "start"), assistant("11-06 09:20"), time_create("11-06 09:25", logged),
                   assistant("11-06 09:40"), assistant("11-06 10:00")]
        proc = self.run_records(records, "--since-last-entry", "--brief", "--ticket", closing, "--now", iso("11-06 10:01"))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return proc.stdout.strip()

    def test_brief_reports_an_entry_logged_under_the_other_ticket_form(self):
        # A ticketing tool can take a ticket number or a numeric id, so a thread can
        # log under one and close under the other. The script cannot map them (it
        # makes no ticketing lookup), so it reports the other-form entry's age and
        # a hook stays silent rather than claim nothing was logged.
        line = self.brief_for(TICKET_NO, TICKET_ID)
        self.assertIn("ticket_entry_age_min=none", line)
        self.assertIn("other_form_entry_age_min=36.0", line)
        line = self.brief_for(TICKET_ID, TICKET_NO)
        self.assertIn("ticket_entry_age_min=none", line)
        self.assertIn("other_form_entry_age_min=36.0", line)

    def test_brief_same_form_entries_are_matched_by_name_not_reported_as_other_form(self):
        line = self.brief_for(TICKET_NO, TICKET_NO)
        self.assertIn("ticket_entry_age_min=36.0", line)
        self.assertIn("other_form_entry_age_min=none", line)
        line = self.brief_for(TICKET_NO, TICKET_NO.lower())     # case does not make a different ticket
        self.assertIn("ticket_entry_age_min=36.0", line)
        self.assertIn("other_form_entry_age_min=none", line)
        line = self.brief_for(TICKET_ID, TICKET_ID)
        self.assertIn("ticket_entry_age_min=36.0", line)
        self.assertIn("other_form_entry_age_min=none", line)

    def test_brief_a_different_ticket_in_the_same_form_is_neither(self):
        # Two numeric ids that differ are two tickets: nothing is logged for this
        # one, so the hook may speak.
        line = self.brief_for(TICKET_ID, TICKET_ID_OTHER)
        self.assertIn("ticket_entry_age_min=none", line)
        self.assertIn("other_form_entry_age_min=none", line)

    def test_brief_keeps_the_other_form_key_when_the_transcript_is_too_short(self):
        proc = self.run_records([assistant("11-06 09:00")], "--since-last-entry", "--brief", "--ticket", TICKET_ID, "--now", iso("11-06 09:01"))
        self.assertTrue(proc.returncode == 0 and "other_form_entry_age_min=none" in proc.stdout)

    def test_brief_without_since_last_entry_is_a_usage_error(self):
        proc = self.run_records([assistant("11-06 09:00"), assistant("11-06 09:05")], "--brief")
        self.assertTrue(proc.returncode == 2 and "--since-last-entry" in proc.stderr)

    def test_a_single_event_transcript_is_still_exit_1_without_brief_and_zero_with_it(self):
        one = [assistant("11-06 09:00")]
        self.assertEqual(self.run_records(one).returncode, 1)
        brief = self.run_records(one, "--since-last-entry", "--brief", "--now", iso("11-06 09:01"))
        self.assertTrue(brief.returncode == 0 and "unlogged_min=0.0" in brief.stdout)

    # --- --time-tool: which tool call is the time-entry tool ---------------------

    def test_time_tool_option_names_the_time_entry_tool(self):
        # A ticketing system whose time tool is not called time_manage: the default
        # does not see its creates, and --time-tool NAME does. A time_manage call is
        # in turn not a create once another name is asked for.
        other = "mcp__example-tickets__tickets__log_hours"
        records = [human("11-06 09:00", "start"), assistant("11-06 09:20"), time_create("11-06 09:25", TICKET_NO, tool=other),
                   assistant("11-06 09:40"), assistant("11-06 10:00")]
        brief = ("--since-last-entry", "--brief", "--ticket", TICKET_NO, "--now", iso("11-06 10:01"))
        default = self.run_records(records, *brief)
        self.assertIn("last_entry=none", default.stdout)
        self.assertIn("unlogged_min=60.0", default.stdout)
        named = self.run_records(records, *brief, "--time-tool", "log_hours")
        self.assertIn("last_entry=2026-11-06T09:25:00+00:00", named.stdout)
        self.assertIn("unlogged_min=35.0", named.stdout)
        self.assertIn("ticket_entry_age_min=36.0", named.stdout)
        # The full tool name works too, and the default name stops matching.
        full = self.run_records(records, *brief, "--time-tool", other)
        self.assertIn("last_entry=2026-11-06T09:25:00+00:00", full.stdout)
        psa = [human("11-06 09:00", "start"), assistant("11-06 09:20"), time_create("11-06 09:25", TICKET_NO),
               assistant("11-06 09:40"), assistant("11-06 10:00")]
        self.assertIn("last_entry=2026-11-06T09:25:00+00:00", self.run_records(psa, *brief).stdout)
        self.assertIn("last_entry=none", self.run_records(psa, *brief, "--time-tool", "log_hours").stdout)

    def test_an_empty_time_tool_name_is_refused(self):
        # An empty name ends every tool name, so every call would read as a time entry.
        proc = self.run_records([assistant("11-06 09:00"), assistant("11-06 09:05")], "--time-tool", "")
        self.assertEqual(proc.returncode, 2)
        self.assertIn("--time-tool", proc.stderr)

    # --- the docstring and the file itself ---------------------------------------

    def test_docstring_names_the_rules_and_the_hold_rule(self):
        text = SCRIPT.read_text()
        doc = " ".join(text.split('"""')[1].split())
        for needle in ("30 minutes or less", "Unattended agent time counts like attended time", "usage-limit hold",
                       "--keep", "--also", "--strict"):
            self.assertIn(needle, doc, needle)
        self.assertNotIn(chr(0x2014), text)    # no em or en dashes
        self.assertNotIn(chr(0x2013), text)

    def test_running_the_file_directly_runs_the_tests_and_cannot_pass_vacuously(self):
        here = Path(__file__)
        env = base_env()
        one = subprocess.run([sys.executable, str(here), "ActiveMinutesTest.test_a_45_minute_interactive_pause_counts_as_work"],
                             capture_output=True, text=True, env=env, timeout=120)
        self.assertTrue(one.returncode == 0 and "Ran 1 test" in one.stderr and "OK" in one.stderr, one.stdout + one.stderr)
        # A selection that matches nothing must fail, not pass.
        nothing = subprocess.run([sys.executable, str(here), "ActiveMinutesTest.no_test_has_this_name"],
                                 capture_output=True, text=True, env=env, timeout=120)
        self.assertNotEqual(nothing.returncode, 0)
        if sys.version_info >= (3, 12):
            # unittest's -k filter exits 5 when it ran no test at all.
            none_ran = subprocess.run([sys.executable, str(here), "-k", "no_test_has_this_name"],
                                      capture_output=True, text=True, env=env, timeout=120)
            self.assertNotEqual(none_ran.returncode, 0)
        # A failing test must fail the run: append one to a copy and run only it.
        copy = self.tmp_path / "test_copy.py"
        text = here.read_text()
        marker = 'if __name__ == "__main__":\n'
        at = text.rindex(marker)          # the real block is the last one; this test names the marker too
        copy.write_text(text[:at] + "class ForcedFailure(unittest.TestCase):\n    def test_forced_failure(self):\n        self.fail('forced')\n\n\n" + text[at:])
        failed = subprocess.run([sys.executable, str(copy), "ForcedFailure.test_forced_failure"],
                                capture_output=True, text=True, env=env, timeout=120)
        self.assertTrue(failed.returncode == 1 and "FAILED" in failed.stderr, failed.stdout + failed.stderr)


if __name__ == "__main__":
    unittest.main()
