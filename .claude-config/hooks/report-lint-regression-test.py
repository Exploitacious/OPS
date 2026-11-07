"""Offline tests for report-lint.py: the shape rules, the transcript reader and the state.

The rules were calibrated on real foreman messages; the fixtures here are written fresh,
in the same shapes, with invented names, so the suite needs no database and no client data.
All credentials and paths are fake.
"""
import hashlib
import importlib.util
import json
import os
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

SPEC = importlib.util.spec_from_file_location("report_lint", Path(__file__).with_name("report-lint.py"))
lint = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lint)


def numbered_decisions(n, ids=False):
    """A long list shape: numbered bold-led items, each with a recommendation line."""
    out = ["Reply \"all as recommended\" and I'll act on everything. Or answer by number.", "",
           "## A. Yes or no approvals; I do the work", ""]
    for i in range(1, n + 1):
        tag = f" (#{1300 + i})" if ids else ""
        out.append(f"{i}. **Item {i} of the device rollout{tag}.** Should the rollout use the staged ring or the fast ring for wave {i}?")
        out.append("   - **Recommendation:** the staged ring, because it matches how the last wave went.")
    return "\n".join(out)


STATUS_WITH_IDS = (
    "Everything planned for this window is merged. #1296, #1316 and #1329 are verified live and closed, "
    "#1452 (the #1316 build) merged as 9b799c0 and deployed, and #1511 waits on its second review. "
    "The failed run on #1513 was a timing flake and passed on rerun. Ticket ENG-1001 closed after its check "
    "and ENG-1002 stays open until Friday. Version 1.9.4 of the census is live on every box, 1.10.0 is queued."
    + " The rest of the window was routine: backups ran, the nightly checks passed and nothing needs attention."
)
ASK_CARD = """I need three things from you; everything else is handled.

**Asks**
1. **Incident clearing.** Whether clearing an incident should need an approval each time. I recommend the plan-then-execute token only, because it matches user disable and device actions. If you say nothing, I keep the approval-page grant required.
2. **One scratch publish in the wiki.** Approve one create-and-publish on a throwaway document. I recommend yes. If you say nothing, the publish option stays off.
3. **Reboot census gate date.** Whether the gate goes live Friday or Monday. I recommend Friday. If you say nothing, it goes live Monday.

**Decided**
- The read fix ships on its own today.
- The recycle-bin bug is not posted anywhere public.
- The stale-device change stays switched off until its dry run is clean.

**I'm handling**
- The dependency bump on the gateway.
- The two stale branches in the tools repo.
- The vault backup rename, before the Sunday window.
- The nightly census report, checked each morning.
- The docs updates for the new tool options.
"""
DEFERRAL = (
    "I'm going to leave the second half of the cleanup until tomorrow, since the window is closed tonight. "
    "The remaining work is mechanical and I'll do it later in the week once the merge train has cleared. "
    "I'm deferring the docs pass to next week, and the monitoring change waits until the weekend. "
    "Nothing here needs you. The follow-up checks are scheduled for Monday morning and I will report then. "
    "If something changes before that, I will pick it back up straight away and post the result in this thread. "
    "For now the state is stable and nothing is running that could be harmed by waiting."
)
DECISION_TABLE = """The six candidates are below, with my view on each.

| Ticket | Finding | Recommendation |
|---|---|---|
| Reboot gate | Safe to ship | Approve |
| Incident tool | Needs a live test | Approve one test |
| Wiki publish | Never sent live | Approve one scratch run |
| Attachments | Unproven | Approve one email |
| Recycle bin | Upstream bug | Do not file |
| Device reconcile | Dry run first | Approve dry run |

Everything else on the board is unchanged since this morning, and the nightly checks passed on every box.
"""


class ShapeTests(unittest.TestCase):
    def setUp(self):
        self.env = mock.patch.dict(os.environ, {}, clear=False)
        self.env.start()
        os.environ.pop("REPORT_LINT_MAX_ASKS", None)
        os.environ.pop("REPORT_LINT_TICKET_RE", None)
        self.addCleanup(self.env.stop)

    def kind(self, text):
        verdict = lint.judge(text)
        return verdict[0] if verdict else None

    def test_a_long_numbered_decision_list_goes_back(self):
        verdict = lint.judge(numbered_decisions(24))
        self.assertEqual(verdict[0], "asks")
        self.assertGreaterEqual(verdict[1]["asks"], 20)

    def test_the_cap_is_three_so_a_fourth_ask_goes_back(self):
        # More than three decision items goes back; a first build that drew the line at five
        # let exactly four through.
        self.assertIsNone(self.kind(numbered_decisions(3)))
        self.assertEqual(self.kind(numbered_decisions(4)), "asks")
        self.assertEqual(self.kind(numbered_decisions(5)), "asks")

    def test_the_cap_can_be_moved_and_a_bad_value_is_ignored(self):
        with mock.patch.dict(os.environ, {"REPORT_LINT_MAX_ASKS": "2"}):
            self.assertEqual(self.kind(numbered_decisions(3)), "asks")
        with mock.patch.dict(os.environ, {"REPORT_LINT_MAX_ASKS": "6"}):
            self.assertIsNone(self.kind(numbered_decisions(5)))
        for bad in ("nonsense", "0", "-1"):
            with self.subTest(value=bad), mock.patch.dict(os.environ, {"REPORT_LINT_MAX_ASKS": bad}):
                self.assertIsNone(self.kind(numbered_decisions(3)))
                self.assertEqual(self.kind(numbered_decisions(4)), "asks")

    def test_a_decision_table_goes_back_even_with_few_asks(self):
        verdict = lint.judge(DECISION_TABLE)
        self.assertEqual(verdict[0], "table")
        self.assertEqual(verdict[1]["rows"], 6)

    def test_a_data_table_is_not_a_decision_table(self):
        text = ("Where the overnight runs landed:\n\n| Host | Result | Minutes |\n|---|---|---|\n| MAIN | OK | 1 |\n"
                "| SLOW | OK | 3 |\n| WEST | OK | 4 |\n\n" + "Nothing needs you. " * 25)
        self.assertIsNone(self.kind(text))
        two_rows = "| Ticket | Recommendation |\n|---|---|\n| A | yes |\n| B | no |\n" + "Context line. " * 40
        self.assertIsNone(self.kind(two_rows))

    def test_bare_ids_inside_asks_go_back_but_a_status_paragraph_does_not(self):
        text = ("Two calls for you.\n\n## Decisions for you\n\n"
                "1. **#1395 D3.** Should clearing an incident need a grant? I recommend the token only.\n"
                "2. **#375 and 9b799c0.** Flip the reconcile flag after the dry run? I recommend yes, per ENG-1001.\n"
                + "Everything else is on track and nothing is blocked today. " * 6)
        verdict = lint.judge(text)
        self.assertEqual(verdict[0], "ids")
        self.assertGreaterEqual(verdict[1]["ids"], 3)
        self.assertIsNone(self.kind(STATUS_WITH_IDS))

    def test_ids_with_their_names_beside_them_are_fine(self):
        # A ticket number with its title next to it is not a bare ID. Three asks, three IDs,
        # each with a name: a first build sent this back as "bare IDs".
        text = ("Three calls for you.\n\n## Needs you\n\n"
                "1. **Printer rollout (ENG-1001)** is overdue. Should I log today's time on it? I recommend yes.\n"
                "2. **Seat expansion (ENG-1002)** is waiting. Should I close it out? I recommend yes.\n"
                "3. ENG-1003: license audit is ready. Should I send it? I recommend yes.\n"
                + "Everything else is on track and nothing is blocked today. " * 6)
        analysis = lint.analyze(text)
        self.assertEqual(analysis["asks"], 3)
        self.assertEqual(analysis["ids"], [])
        self.assertIsNone(lint.judge(text))

    def test_ids_that_stand_alone_go_back_but_a_name_beside_one_clears_it(self):
        cases = (
            ("Should I close ENG-1001? I recommend yes.", ["ENG-1001"]),
            ("**#375 and 9b799c0.** Approve both? I recommend yes.", ["#375", "9b799c0"]),
            ("Flip the flag after the dry run? I recommend yes, per ENG-1001.", ["ENG-1001"]),
            ("**#1395 D3.** Should clearing an incident need a grant?", ["#1395"]),
            ("Approve 1.10.0? I recommend yes.", ["1.10.0"]),
            ("**Printer rollout (ENG-1001)** is overdue. Should I log time?", []),
            ("Close ENG-1001 (Seat expansion)? I recommend yes.", []),
            ("Census 1.10.0: should the paste go ahead?", []),
            ("Should I merge the staged-ring change, #1452?", []),
        )
        for text, want in cases:
            with self.subTest(text=text):
                self.assertEqual(lint.bare_ids([[text]]), want)
        # Named in one ask, bare in another: it is named, and listed once.
        self.assertEqual(lint.bare_ids([["Approve ENG-1001?"], ["Seat expansion (ENG-1001) ok?"]]), [])
        # A name in the next ask or the next line does not reach back across the sentence.
        self.assertEqual(lint.bare_ids([["Approve #1452.", "Printer cleanup is the other one."]]), ["#1452"])

    def test_three_bare_ids_in_three_asks_go_back_and_the_reason_says_so(self):
        text = ("Three calls for you.\n\n## Needs you\n\n"
                "1. Should I close ENG-1001? I recommend yes.\n"
                "2. Approve #1452 and 9b799c0? I recommend yes.\n"
                "3. Ship ENG-1002? I recommend yes.\n" + "Everything else is on track. " * 12)
        verdict = lint.judge(text)
        self.assertEqual(verdict[0], "ids")
        self.assertIn("by number", lint.reason_for(*verdict))
        self.assertIn("ENG-1001", lint.reason_for(*verdict))

    def test_the_ticket_pattern_is_a_generic_tracker_id_and_can_be_replaced(self):
        # The default is two to eight capitals, a dash and two to six digits. A team with a different
        # numbering sets REPORT_LINT_TICKET_RE; a bad pattern or an empty-matching one is ignored.
        text = "Should I close ENG-1001 and OPS-22? I recommend yes."
        self.assertEqual(lint.bare_ids([[text]]), ["ENG-1001", "OPS-22"])
        self.assertEqual(lint.bare_ids([["Should I close JOB/777 today? I recommend yes."]]), [])
        with mock.patch.dict(os.environ, {"REPORT_LINT_TICKET_RE": r"\bJOB/\d{3}\b"}):
            self.assertEqual(lint.bare_ids([["Should I close JOB/777 today? I recommend yes."]]), ["JOB/777"])
            self.assertEqual(lint.bare_ids([[text]]), [])
        for broken in ("(", "[", ""):
            with self.subTest(pattern=broken), mock.patch.dict(os.environ, {"REPORT_LINT_TICKET_RE": broken}):
                self.assertEqual(lint.bare_ids([[text]]), ["ENG-1001", "OPS-22"])
        with mock.patch.dict(os.environ, {"REPORT_LINT_TICKET_RE": "x*"}):
            self.assertEqual(lint.id_spans("abc"), [])

    def test_a_heading_that_asks_someone_else_is_not_a_list_of_asks_for_the_operator(self):
        # A message of questions to put to a scooter seller was sent back as "asks for five
        # decisions" because its heading began with the word Ask.
        questions = "\n".join(f"- Has the unit with serial number {i} ever been in a crash, and what was fixed?" for i in range(1, 6))
        tail = "\n\n" + "Context. " * 30
        for heading in ("Ask every seller:", "**Ask every seller**", "## Questions for the seller", "Questions to ask the dealer:",
                        "Questions about the listing:"):
            with self.subTest(heading=heading):
                self.assertIsNone(self.kind(heading + "\n" + questions + tail))
        for heading in ("Questions for you:", "## Asks for you", "Ask card:", "## Decisions for you", "**Needs you**",
                        "Questions for the Operator:"):
            with self.subTest(heading=heading):
                self.assertEqual(self.kind(heading + "\n" + questions + tail), "asks")
        self.assertEqual(lint.ask_heading_kind("Ask every seller"), "third")
        self.assertEqual(lint.ask_heading_kind("Asks"), "ask")
        self.assertIsNone(lint.ask_heading_kind("Where things landed"))

    def test_the_ask_card_shape_passes(self):
        # What the block asks for must not be blocked in turn: three asks, a bucket of eight lines.
        self.assertGreaterEqual(len(ASK_CARD), lint.MIN_CHARS)
        self.assertIsNone(self.kind(ASK_CARD))

    def test_deferral_language_is_never_judged(self):
        self.assertGreaterEqual(len(DEFERRAL), lint.MIN_CHARS)
        self.assertIsNone(self.kind(DEFERRAL))
        for word in ("later", "tomorrow", "defer", "next week", "until", "wait"):
            self.assertNotIn(word, lint.reason_for("asks", {"asks": 9}).lower())
        self.assertNotIn(chr(0x2014), lint.reason_for("asks", {"asks": 9}))
        self.assertNotIn(chr(0x2013), lint.reason_for("asks", {"asks": 9}))

    def test_buckets_and_mentions_of_decisions_do_not_count(self):
        text = ("Nothing needed from you. Production is green.\n\n**Decisions I made (veto any):**\n"
                "- **Rule one:** its pages wait a week.\n- **Rule two:** a confirm with a bad tag is refused.\n"
                "- **Rule three:** not built.\n- **Rule four:** warnings start 11-30.\n- **Rule five:** limits rise together.\n\n"
                "All of your decisions are now in motion:\n- the proxy lift\n- the discover answer\n- the monitoring probe\n"
                "- the script change\n- the key restore\n\n" + "Routine. " * 30)
        self.assertIsNone(self.kind(text))

    def test_an_option_menu_counts_each_option(self):
        text = ("Two things for you.\n\n**New things for you:**\n- **The seat-pool change.** It is yours in the console.\n"
                "- **The skills copies.** Pick one.\n\n**The copies, explained:**\n"
                "- **Option 1, delete the copies:** clean but another tool loses them.\n"
                "- **Option 2, automate the sync:** a day behind.\n"
                "- **Option 3 (recommended):** point both at the shared repo.\n" + "Detail. " * 30)
        self.assertEqual(self.kind(text), "asks")

    def test_fenced_code_urls_and_inline_links_are_ignored(self):
        text = ("Build is green.\n\n```\n$ git log --oneline\n9b799c0 fix?\n3ec8ca1 other?\n#1 #2 #3 #4 #5\n```\n"
                "See [the dashboard](https://example.invalid/a?b=c&d=e?) and https://example.invalid/x?y?z? for detail. "
                + "Routine status. " * 30)
        self.assertIsNone(self.kind(text))

    def test_questions_in_prose_count_when_on_their_own_line(self):
        questions = "\n".join(f"Should we move job number {i} to the new box this week?" for i in range(1, 7))
        self.assertEqual(self.kind("A few questions.\n\n" + questions + "\n\n" + "Context. " * 40), "asks")

    def test_version_strings_count_only_inside_asks_and_only_when_bare(self):
        bare = ("Calls for you:\n\n1. Approve 1.10.0? I recommend yes.\n"
                "2. Approve 3.63.1 and 3.64.2? I recommend yes.\n" + "Routine. " * 40)
        verdict = lint.judge(bare)
        self.assertEqual(verdict[0], "ids")
        named = ("Calls for you:\n\n1. **Census 1.10.0.** Should the paste go ahead? I recommend yes.\n"
                 "2. **Rules bump.** Approve the bump from 3.63.1 to 3.64.2? I recommend yes.\n" + "Routine. " * 40)
        self.assertIsNone(lint.judge(named))


class HookFileTests(unittest.TestCase):
    def test_no_hook_file_carries_an_em_or_en_dash(self):
        # The writing rule: no em dashes, and no en dashes standing in for them, in anything
        # these hooks print into a session or ship in their own text.
        here = Path(__file__).parent
        names = [n for n in os.listdir(here) if n.startswith(("report-lint", "askuser-cancel"))]
        self.assertTrue(names)
        for name in names:
            with self.subTest(file=name):
                text = (here / name).read_text(encoding="utf-8")
                self.assertNotIn(chr(0x2014), text)
                self.assertNotIn(chr(0x2013), text)


def record(kind, content, **extra):
    base = {"type": kind, "isSidechain": False, "message": {"role": kind, "content": content}}
    base.update(extra)
    return base


def text_block(text):
    return [{"type": "text", "text": text}]


class TranscriptTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def write(self, records, name="t.jsonl", junk=False):
        path = Path(self.tmp.name) / name
        lines = [json.dumps(r) for r in records]
        if junk:
            lines.insert(1, "not json {")
            lines.insert(0, "")
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return str(path)

    def test_the_turn_is_everything_since_the_last_real_prompt(self):
        path = self.write([
            record("user", "an earlier prompt"),
            record("assistant", text_block("EARLIER TURN " + "x" * 500)),
            record("user", "the real prompt"),
            record("assistant", [{"type": "thinking", "thinking": "hm"}]),
            record("assistant", text_block("FIRST " + "a" * 500)),
            record("assistant", [{"type": "tool_use", "id": "t1", "name": "Bash", "input": {}}]),
            record("user", [{"type": "tool_result", "tool_use_id": "t1", "content": "ok"}]),
            record("assistant", text_block("CLOSING")),
        ], junk=True)
        messages = lint.turn_messages(path)
        self.assertEqual([m[:7] for m in messages], ["FIRST a", "CLOSING"])

    def test_sidechains_and_meta_records_do_not_open_or_fill_a_turn(self):
        path = self.write([
            record("user", "prompt"),
            record("assistant", text_block("MAIN ONE")),
            record("assistant", text_block("LANE TEXT"), isSidechain=True),
            record("user", "injected note", isMeta=True),
            record("user", "a side lane prompt", isSidechain=True),
            record("assistant", text_block("MAIN TWO")),
        ])
        self.assertEqual(lint.turn_messages(path), ["MAIN ONE", "MAIN TWO"])

    def test_a_prompt_with_text_blocks_opens_a_turn(self):
        path = self.write([
            record("assistant", text_block("OLD")),
            record("user", [{"type": "text", "text": "a prompt as blocks"}]),
            record("assistant", text_block("NEW")),
        ])
        self.assertEqual(lint.turn_messages(path), ["NEW"])

    def test_a_long_turn_widens_the_tail_until_the_prompt_is_found(self):
        filler = [record("assistant", text_block("m%d " % i + "y" * 2000)) for i in range(40)]
        path = self.write([record("user", "prompt")] + filler + [record("assistant", text_block("LAST"))])
        with mock.patch.object(lint, "TAIL_BYTES", 8192):
            messages = lint.turn_messages(path)
        self.assertEqual(len(messages), 41)
        self.assertEqual(messages[-1], "LAST")

    def test_the_final_message_is_the_payload_copy_when_there_is_one(self):
        # Only the message the Operator reads last is judged. Claude Code's Stop payload carries it
        # as last_assistant_message and that wins over the transcript (which can lag a write).
        path = self.write([record("user", "p"), record("assistant", text_block("EARLIER " + "x" * 500)),
                           record("assistant", text_block("IN TRANSCRIPT"))])
        self.assertEqual(lint.final_message({"transcript_path": path, "last_assistant_message": "NOT YET WRITTEN"}), "NOT YET WRITTEN")
        self.assertEqual(lint.final_message({"last_assistant_message": "ONLY THIS"}), "ONLY THIS")

    def test_without_a_payload_copy_the_final_message_is_the_last_text_block_of_the_turn(self):
        path = self.write([
            record("user", "an earlier prompt"),
            record("assistant", text_block("EARLIER TURN")),
            record("user", "the prompt"),
            record("assistant", text_block("NARRATION " + "x" * 500)),
            record("assistant", [{"type": "tool_use", "id": "t1", "name": "Bash", "input": {}}]),
            record("user", [{"type": "tool_result", "tool_use_id": "t1", "content": "ok"}]),
            record("assistant", text_block("THE FINAL ONE")),
            record("assistant", text_block("  ")),
        ])
        self.assertEqual(lint.final_message({"transcript_path": path}), "THE FINAL ONE")
        # A blank payload copy falls back to the transcript.
        self.assertEqual(lint.final_message({"transcript_path": path, "last_assistant_message": "   "}), "THE FINAL ONE")

    def test_a_turn_with_no_text_yet_and_a_missing_transcript_have_no_final_message(self):
        path = self.write([record("assistant", text_block("OLD TURN")), record("user", "prompt"),
                           record("assistant", [{"type": "tool_use", "id": "t1", "name": "Bash", "input": {}}])])
        self.assertIsNone(lint.final_message({"transcript_path": path}))
        self.assertIsNone(lint.final_message({"transcript_path": "/nonexistent/x.jsonl"}))
        self.assertIsNone(lint.final_message({}))

    def test_narration_earlier_in_the_turn_is_not_judged_when_the_final_message_is_clean(self):
        path = self.write([record("user", "p"), record("assistant", text_block(numbered_decisions(24))),
                           record("assistant", text_block("The decisions are above. I saved the list to the resume note."))])
        final = lint.final_message({"transcript_path": path})
        self.assertIsNone(lint.judge(final))
        self.assertEqual(lint.judge(numbered_decisions(24))[0], "asks")


class StateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        env = mock.patch.dict(os.environ, {"OPS_STATE_DIR": self.tmp.name})
        env.start()
        self.addCleanup(env.stop)

    def test_a_blocked_message_is_remembered_per_session(self):
        key = hashlib.sha256(b"m").hexdigest()[:32]
        self.assertFalse(lint.blocked_before("s1", key))
        lint.remember_block("s1", key)
        self.assertTrue(lint.blocked_before("s1", key))
        self.assertFalse(lint.blocked_before("s2", key))
        self.assertFalse(lint.blocked_before("s1", "other"))

    def test_only_the_last_twenty_keys_are_kept(self):
        for i in range(30):
            lint.remember_block("s1", "k%d" % i)
        data = json.loads(lint.session_state_file("s1").read_text())
        self.assertEqual(len(data["blocked"]), 20)
        self.assertEqual(data["blocked"][-1], "k29")

    def test_odd_session_ids_become_safe_names(self):
        root = lint.session_state_file("x").parent
        for odd in ("../../etc/passwd", "a/b", "x" * 200):
            self.assertEqual(lint.session_state_file(odd).parent, root)

    def test_state_older_than_a_week_is_pruned_once_a_day(self):
        lint.remember_block("fresh", "k")
        root = lint.session_state_file("fresh").parent
        old = root / "old.json"
        old.write_text("{}")
        now = time.time()
        os.utime(old, (now - 8 * 86400, now - 8 * 86400))
        (root / ".pruned").unlink(missing_ok=True)
        lint.prune_state(root, now)
        self.assertFalse(old.exists())
        self.assertTrue(lint.session_state_file("fresh").exists())
        again = root / "again.json"
        again.write_text("{}")
        os.utime(again, (now - 9 * 86400, now - 9 * 86400))
        lint.prune_state(root, now + 60)
        self.assertTrue(again.exists())

    def test_the_record_is_kept_per_session_else_per_transcript_else_in_one_bucket(self):
        # Once-per-message must hold with no session_id.
        self.assertEqual(lint.state_scope({"session_id": "s-1", "transcript_path": "/a"}), "s-1")
        self.assertEqual(lint.state_scope({"session_id": "x" * 200}), "x" * 64)
        by_path = lint.state_scope({"transcript_path": "/a/t.jsonl"})
        self.assertTrue(by_path.startswith("t-"))
        self.assertEqual(by_path, lint.state_scope({"session_id": "", "transcript_path": "/a/t.jsonl"}))
        self.assertNotEqual(by_path, lint.state_scope({"transcript_path": "/a/other.jsonl"}))
        self.assertEqual(lint.state_scope({}), "no-session")
        key = hashlib.sha256(b"m").hexdigest()[:32]
        lint.remember_block(by_path, key)
        self.assertTrue(lint.blocked_before(by_path, key))
        self.assertFalse(lint.blocked_before(lint.state_scope({"transcript_path": "/a/other.jsonl"}), key))

    def test_a_corrupt_state_file_reads_as_not_blocked(self):
        path = lint.session_state_file("s1")
        path.parent.mkdir(parents=True)
        path.write_text("not json {")
        self.assertFalse(lint.blocked_before("s1", "k"))
        lint.remember_block("s1", "k")
        self.assertTrue(lint.blocked_before("s1", "k"))

    def test_the_state_dir_defaults_to_the_ops_state_directory(self):
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("OPS_STATE_DIR", None)
            self.assertEqual(lint.state_dir(), Path.home() / ".local/state/ops")


class LaneTests(unittest.TestCase):
    def stub(self, directory, body):
        path = Path(directory) / "lane-class"
        path.write_text("#!/bin/sh\n" + body + "\n")
        path.chmod(0o755)
        return path

    def lane(self, path):
        with mock.patch.object(lint, "lane_class_path", return_value=path):
            return lint.lane_of(b'{"session_id":"s"}')

    def test_lane_answers_and_fallbacks(self):
        with tempfile.TemporaryDirectory() as directory:
            for body, want in (("echo t3-lane", "t3-lane"), ("echo agent-lane", "agent-lane"), ("echo foreman", "foreman"),
                               ("echo nonsense", "foreman"), ("exit 3", "foreman")):
                with self.subTest(body=body):
                    self.assertEqual(self.lane(self.stub(directory, body)), want)

    def test_a_hung_lane_class_is_cut_off_and_counts_as_foreman(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self.stub(directory, "sleep 5 &\nsleep 5\necho t3-lane")
            start = time.monotonic()
            self.assertEqual(self.lane(path), "foreman")
            self.assertLess(time.monotonic() - start, 1.5)

    def test_no_script_means_foreman(self):
        self.assertEqual(self.lane(None), "foreman")
        path = lint.lane_class_path()
        self.assertTrue(path is None or path == Path(lint.__file__).resolve().parent.parent / "bin" / "lane-class")


if __name__ == "__main__":
    unittest.main()
