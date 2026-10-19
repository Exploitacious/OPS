#!/usr/bin/env python3
"""transcript-usage-test.py: pin bin/transcript-usage.py on fixture transcripts.

transcript-usage.py reads Claude Code transcripts (one JSON object per line) and
prints token totals per file. What must hold, because the numbers feed cost
decisions and the transcripts carry private conversation text:
  - a streamed call (one message.id seen several times) counts once, with its
    last usage, so partials are never double counted
  - --since and --until drop calls outside the window
  - a sub-agent transcript (under subagents/, or named agent-*) is a lane row
  - --gaps reports writes after an idle gap of more than 5 minutes
  - no message text, prompt, or tool input ever reaches the output
  - an unreadable line is skipped, not fatal

Read-only: every file it touches is in its own temporary directory.
Run: python3 ~/OPS/.claude-config/bin/tests/transcript-usage-test.py
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TOOL = Path(__file__).resolve().parents[1] / "transcript-usage.py"
SECRET = "do-not-print-this-prompt-text"


def entry(ts, mid, inp=0, ccr=0, crd=0, out=0, model="claude-sonnet-5-5", text=SECRET, **extra):
    e = {"type": "assistant", "timestamp": ts,
         "message": {"id": mid, "model": model, "content": [{"type": "text", "text": text}],
                     "usage": {"input_tokens": inp, "cache_creation_input_tokens": ccr,
                               "cache_read_input_tokens": crd, "output_tokens": out}}}
    e.update(extra)
    return json.dumps(e)


class TranscriptUsage(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name) / "projects"
        proj = self.root / "-home-u-OPS"
        (proj / "sess" / "subagents").mkdir(parents=True)
        main = [
            json.dumps({"type": "user", "timestamp": "2026-10-01T10:00:00Z",
                        "message": {"role": "user", "content": SECRET}}),
            # A streamed call: two partials and the final usage share message.id m1.
            entry("2026-10-01T10:00:01Z", "m1", inp=10, ccr=1000, crd=0, out=1),
            entry("2026-10-01T10:00:02Z", "m1", inp=10, ccr=1000, crd=0, out=5),
            entry("2026-10-01T10:00:03Z", "m1", inp=10, ccr=1000, crd=0, out=50),
            "{not json",
            # Ten minutes idle, then a large re-write: a cache-TTL miss.
            entry("2026-10-01T10:10:03Z", "m2", inp=5, ccr=60000, crd=2000, out=20),
            # Outside a --until 2026-10-01T23:59:59Z window.
            entry("2026-10-02T09:00:00Z", "m3", inp=7, ccr=0, crd=500, out=3),
        ]
        (proj / "sess.jsonl").write_text("\n".join(main) + "\n")
        lane = [entry("2026-10-01T10:05:00Z", "l1", inp=1, ccr=300, crd=4000, out=9,
                      isSidechain=True)]
        (proj / "sess" / "subagents" / "agent-abc.jsonl").write_text("\n".join(lane) + "\n")

    def run_tool(self, *args):
        r = subprocess.run([sys.executable, str(TOOL), *args, str(self.root)],
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout

    def totals(self, out):
        line = next(l for l in out.splitlines() if l.startswith("TOTALS "))
        return json.loads(line[len("TOTALS "):])

    def test_streamed_call_counts_once_with_its_final_usage(self):
        t = self.totals(self.run_tool("--until", "2026-10-01T23:59:59Z"))
        # m1 once (out 50, ccr 1000), m2, and the lane's l1; m3 is past --until.
        self.assertEqual(t["calls"], 3)
        self.assertEqual(t["ccr"], 1000 + 60000 + 300)
        self.assertEqual(t["out"], 50 + 20 + 9)
        self.assertEqual(t["files"], 2)

    def test_since_and_until_bound_the_window(self):
        t = self.totals(self.run_tool("--since", "2026-10-02T00:00:00Z"))
        self.assertEqual((t["calls"], t["crd"], t["files"]), (1, 500, 1))

    def test_lane_rows_are_subagents(self):
        out = self.run_tool()
        self.assertIn("KIND main files=1 calls=3", out)
        self.assertIn("KIND subagent files=1 calls=1", out)

    def test_gaps_reports_the_write_after_an_idle_gap(self):
        out = self.run_tool("--gaps")
        main = next(l for l in out.splitlines() if l.strip().startswith("main:"))
        self.assertIn("writes_after_5min_gap=60000 (1 calls", main)

    def test_no_message_text_reaches_the_output(self):
        out = self.run_tool("--hourly", "--gaps")
        self.assertNotIn(SECRET, out)


if __name__ == "__main__":
    unittest.main()
