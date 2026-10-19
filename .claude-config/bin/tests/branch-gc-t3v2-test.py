#!/usr/bin/env python3
"""branch-gc against T3 Code 0.1.0 (Orchestrator V2) state: liveness and fail-closed.

Why pin this: branch-gc is the only silent consumer of T3 state with deletion
authority. After the 0.1.0 upgrade the V1 state.sqlite is frozen, so reading it
reports ok on stale data and the T3 hold quietly decays. These cases pin the
port: when statev2.sqlite sits beside the configured database only it is read
(even with the V1 file at mode 000); archived and imported threads hold their
worktrees; a live run, runtime request, node, subagent, background task or
future snooze is a hard hold that ignores the merged-PR carve-out; and every
doubt about the source (missing table or column, zero threads, a database
missing while a server runtime file exists, a stale source) blocks every
worktree removal and fails the run. The snapshot is computed once per run, and
activity arriving during the GitHub lookup still blocks the removal.

Fixture repos, the gh stub and the trash come from branch-gc-safety-test.py; the
V2 database comes from branch_gc_t3v2_fixture.py. Nothing here reads ~/.t3:
BRANCH_GC_T3_DB always names a temporary directory, and branch-gc looks for
statev2.sqlite and server-runtime.json in that directory only. A quarantine is a
rename inside the temporary directory; run the suite inside the sandbox runner.
Run: python3 -B branch-gc-t3v2-test.py
"""
import os, runpy; runpy.run_path(os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "sandbox_guard.py"))["require"]()
import datetime
import os
import runpy
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from branch_gc_t3v2_fixture import V2Fixture, iso, runtime_file

HELPERS = runpy.run_path(str(HERE / "branch-gc-safety-test.py"))
UTC = datetime.timezone.utc
HELD = "T3 thread still active"


def event_sql(db, stream, event_type, hours_ago=0.0, version=2):
    """Python source for an on-list hook that appends one V2 event to db."""
    return (f"_con = sqlite3.connect({str(db)!r})\n"
            f"import datetime as _dt, uuid as _uuid\n"
            f"_at = (_dt.datetime.now(_dt.timezone.utc) - _dt.timedelta(hours={hours_ago!r}))"
            f".strftime('%Y-%m-%dT%H:%M:%S.000Z')\n"
            f"_con.execute(\"insert into orchestration_events (event_id, aggregate_kind, stream_id, stream_version,"
            f" event_type, occurred_at, actor_kind, payload_json, metadata_json, application_event_version)"
            f" values (?, 'thread', ?, 1000, ?, ?, 'server', '{{}}', '{{}}', {version})\","
            f" (str(_uuid.uuid4()), {stream!r}, {event_type!r}, _at))\n"
            f"_con.commit()\n_con.close()\n")


class T3V2(unittest.TestCase):
    def setUp(self):
        self.c = HELPERS["BranchGcSafety"]()
        self.c.setUp()
        self.addCleanup(self.c.doCleanups)
        self.userdata = self.c.root / "t3home/userdata"
        self.userdata.mkdir(parents=True)
        self.v2db = self.userdata / "statev2.sqlite"
        self.c.env["BRANCH_GC_T3_DB"] = str(self.userdata / "state.sqlite")
        self.c.env.pop("T3CODE_HOME", None)

    # --- helpers -----------------------------------------------------------------
    def fx(self, **kw):
        return V2Fixture(self.v2db, **kw)

    def gc(self, *args):
        return self.c.run_gc(*args)

    def header(self, result):
        return result.stdout.splitlines()[0] if result.stdout else ""

    def out(self, result):
        return result.stdout + result.stderr

    def assertQuarantined(self, wt, result):
        self.assertEqual(result.returncode, 0, self.out(result))
        self.assertFalse(wt.exists(), self.out(result))
        self.assertFalse(self.c.has_branch(), self.out(result))

    def assertHeld(self, wt, result, reason=HELD):
        self.assertTrue(wt.exists(), self.out(result))
        self.assertTrue(self.c.has_branch(), self.out(result))
        self.assertIn(reason, result.stdout)

    def assertUnreadable(self, wt, result, why):
        self.assertNotEqual(result.returncode, 0, self.out(result))
        self.assertTrue(wt.exists(), self.out(result))
        self.assertTrue(self.c.has_branch(), self.out(result))
        self.assertIn("T3=unreadable", self.header(result))
        self.assertIn("T3 state unreadable", result.stdout)
        self.assertIn(why, self.c.log())

    def merged_v2(self, merged_h=30, active_h=40):
        """A worktree whose PR merged merged_h ago and whose thread was last active active_h ago."""
        wt, _ = self.c.worktree()
        now = datetime.datetime.now(UTC)
        # GitHub spells mergedAt without fractional seconds.
        self.c.prs[0]["mergedAt"] = (now - datetime.timedelta(hours=merged_h)).strftime("%Y-%m-%dT%H:%M:%SZ")
        fx = self.fx()
        fx.thread("thr-1", wt, updated_h=active_h)
        return wt, fx

    # --- which file is read -------------------------------------------------------
    def test_v2_sibling_is_the_only_source_even_with_v1_at_mode_000(self):
        wt, _ = self.c.worktree()
        # The V1 file says the thread is active right now and cannot be opened:
        # reading it would either hold the worktree or report unreadable.
        self.c.t3(wt, datetime.datetime.now(UTC).isoformat()).close()
        v1 = self.userdata / "state.sqlite"
        v1.chmod(0)
        self.addCleanup(v1.chmod, 0o600)
        if os.access(v1, os.R_OK):
            self.skipTest("running as a user that reads mode-000 files")
        fx = self.fx()
        fx.thread("thr-1", wt, updated_h=100)
        fx.close()
        result = self.gc("--apply")
        self.assertQuarantined(wt, result)
        self.assertIn("T3=ok (v2 ", self.header(result))
        self.assertIn("statev2.sqlite", self.header(result))
        self.assertIn("T3 v2 snapshot: event high-water", self.c.log())

    def test_v2_sibling_wins_when_v1_says_stale(self):
        wt, _ = self.c.worktree()
        self.c.t3(wt).close()   # V1: idle since 2020
        fx = self.fx()
        fx.thread("thr-1", wt, updated_h=1)
        fx.close()
        result = self.gc("--apply")
        self.assertHeld(wt, result)
        self.assertIn("thread thr-1 last active", result.stdout)

    def test_v2_sibling_wins_beside_a_symlinked_v1(self):
        for dangling in (False, True):
            with self.subTest(dangling=dangling):
                self.setUp()
                wt, _ = self.c.worktree()
                target = self.c.root / "old-v1.sqlite"
                if not dangling:
                    configured = self.c.env["BRANCH_GC_T3_DB"]
                    self.c.env["BRANCH_GC_T3_DB"] = str(target)
                    self.c.t3(wt).close()
                    self.c.env["BRANCH_GC_T3_DB"] = configured
                (self.userdata / "state.sqlite").symlink_to(target)
                fx = self.fx()
                fx.thread("thr-1", wt, updated_h=1)
                fx.close()
                result = self.gc("--apply")
                self.assertHeld(wt, result)
                self.assertIn("T3=ok (v2 ", self.header(result))

    def test_explicit_statev2_path_is_read(self):
        wt, _ = self.c.worktree()
        fx = self.fx()
        fx.thread("thr-1", wt, updated_h=1)
        fx.close()
        self.c.env["BRANCH_GC_T3_DB"] = str(self.v2db)
        self.assertHeld(wt, self.gc("--apply"))

    def test_v1_alone_is_rollback_mode(self):
        wt, _ = self.c.worktree()
        self.c.t3(wt, datetime.datetime.now(UTC).isoformat()).close()
        result = self.gc("--apply")
        self.assertHeld(wt, result)
        self.assertIn("T3=ok (v1 ", self.header(result))

    def test_dangling_statev2_link_is_unreadable_not_a_v1_fallback(self):
        wt, _ = self.c.worktree()
        self.c.t3(wt).close()   # V1 would let it go
        self.v2db.symlink_to(self.userdata / "gone.sqlite")
        self.assertUnreadable(wt, self.gc("--apply"), "unreadable, all worktree removals blocked")

    def test_v1_reader_refuses_a_v2_database_under_another_name(self):
        wt, _ = self.c.worktree()
        other = self.c.root / "copies/copy.sqlite"
        fx = V2Fixture(other)
        fx.thread("thr-1", wt, updated_h=100)
        fx.close()
        self.c.env["BRANCH_GC_T3_DB"] = str(other)
        self.assertUnreadable(wt, self.gc("--apply"), "is a T3 V2 database; its V1 tables are a frozen copy")

    def test_v1_schema_named_statev2_is_unreadable(self):
        wt, _ = self.c.worktree()
        self.c.env["BRANCH_GC_T3_DB"] = str(self.v2db)
        self.c.t3(wt).close()   # the V1 builder writes V1 tables at statev2.sqlite
        self.assertUnreadable(wt, self.gc("--apply"), "T3 V2 schema: table orchestration_events is missing")

    # --- liveness -----------------------------------------------------------------
    def test_archived_thread_active_within_72h_holds(self):
        wt, _ = self.c.worktree()
        fx = self.fx()
        fx.thread("thr-1", wt, updated_h=10, archived_h=5)
        fx.close()
        result = self.gc("--apply")
        self.assertHeld(wt, result)
        self.assertIn(", archived", result.stdout)

    def test_archived_thread_idle_past_72h_lets_go(self):
        wt, _ = self.c.worktree()
        fx = self.fx()
        fx.thread("thr-1", wt, updated_h=100, archived_h=90)
        fx.close()
        self.assertQuarantined(wt, self.gc("--apply"))

    def test_unhydrated_import_uses_source_updated_at(self):
        for source_h, held in ((5, True), (200, False)):
            with self.subTest(source_h=source_h):
                self.setUp()
                wt, _ = self.c.worktree()
                fx = self.fx()
                fx.thread("thr-imp", wt, updated_h=200, archived_h=150)
                fx.legacy_import("thr-imp", source_h=source_h)
                fx.close()
                result = self.gc("--apply")
                if held:
                    self.assertHeld(wt, result)
                else:
                    self.assertQuarantined(wt, result)

    def test_newest_message_and_run_times_count(self):
        cases = {"message created": lambda fx: fx.message("thr-1", created_h=2),
                 "message updated": lambda fx: fx.message("thr-1", created_h=200, updated_h=2),
                 "run requested": lambda fx: fx.run("thr-1", "completed", requested_h=2, completed_h=150),
                 "run completed": lambda fx: fx.run("thr-1", "completed", requested_h=150, completed_h=2)}
        for name, add in cases.items():
            with self.subTest(name):
                self.setUp()
                wt, _ = self.c.worktree()
                fx = self.fx()
                fx.thread("thr-1", wt, updated_h=200)
                add(fx)
                fx.close()
                self.assertHeld(wt, self.gc("--apply"))

    def test_ui_visit_is_not_activity(self):
        wt, _ = self.c.worktree()
        fx = self.fx()
        fx.thread("thr-1", wt, updated_h=100, last_visited_h=0.1)
        fx.close()
        self.assertQuarantined(wt, self.gc("--apply"))

    def test_deleted_thread_does_not_hold(self):
        wt, _ = self.c.worktree()
        fx = self.fx()
        fx.thread("thr-1", wt, updated_h=1, deleted_h=0.5)
        fx.close()
        self.assertQuarantined(wt, self.gc("--apply"))

    def test_merged_pr_carve_out_still_applies_without_a_hard_hold(self):
        wt, fx = self.merged_v2()
        fx.run("thr-1", "completed", requested_h=41, completed_h=40)
        # Every status in the 0.1.0 server's settledNodeStatuses lets go; a node
        # anywhere else does not.
        for status in ("completed", "interrupted", "failed", "cancelled", "rolled_back"):
            fx.node("thr-1", status=status)
        # A live node on a thread with no worktree holds nothing here: the node
        # read is per worktree thread.
        fx.thread("thr-no-worktree", None, updated_h=100)
        fx.node("thr-no-worktree", status="running")
        fx.subagent("thr-1", status="completed")
        fx.runtime_request("thr-1", status="resolved")
        fx.turn_item("thr-1", status="completed")
        fx.close()
        result = self.gc("--apply")
        self.assertQuarantined(wt, result)
        self.assertIn("newest activity predates the merge; not holding", self.c.log())

    def test_hard_holds_ignore_the_merged_pr_carve_out(self):
        future = iso(datetime.datetime.now(UTC) + datetime.timedelta(days=1))
        cases = {
            "run running": (lambda fx: fx.run("thr-1", "running", requested_h=41), "run running"),
            "run queued": (lambda fx: fx.run("thr-1", "queued", requested_h=41), "run queued"),
            "run status unknown": (lambda fx: fx.run("thr-1", "paused-someday", requested_h=41), "run paused-someday"),
            "runtime request": (lambda fx: fx.runtime_request("thr-1"), "runtime request pending"),
            "live node": (lambda fx: fx.node("thr-1", kind="tool_call", status="waiting"), "node tool_call waiting"),
            "pending node": (lambda fx: fx.node("thr-1", kind="tool_call", status="pending"), "node tool_call pending"),
            # Not terminal in the 0.1.0 schema's settled set, and not in the live index.
            "idle node": (lambda fx: fx.node("thr-1", kind="root_turn", status="idle"), "node root_turn idle"),
            # A status the 0.1.0 schema does not know (a review's reproduction in
            # another T3 reader); the live-index predicate read it as settled.
            "node status unknown": (lambda fx: fx.node("thr-1", kind="subagent", status="paused"),
                                    "node subagent paused"),
            "subagent": (lambda fx: fx.subagent("thr-1", status="running"), "subagent running"),
            "background command": (lambda fx: fx.turn_item("thr-1", "command_execution", "running"),
                                   "background command_execution running"),
            "snoozed": (lambda fx: fx.con.execute(
                "update orchestration_v2_projection_threads set payload_json ="
                " json_set(payload_json, '$.snoozedUntil', ?)", (future,)), "snoozed"),
            "unparseable message time": (lambda fx: fx.message("thr-1", created_h=41, updated_at="0000-invalid"),
                                         "unparseable timestamp"),
            "unparseable snooze": (lambda fx: fx.con.execute(
                "update orchestration_v2_projection_threads set payload_json ="
                " json_set(payload_json, '$.snoozedUntil', 'tomorrow')"), "unparseable timestamp"),
        }
        for name, (add, reason) in cases.items():
            with self.subTest(name):
                self.setUp()
                wt, fx = self.merged_v2()
                add(fx)
                fx.close()
                result = self.gc("--apply")
                self.assertHeld(wt, result)
                self.assertIn(reason, result.stdout)

    def test_subagent_holds_its_child_threads_worktree(self):
        wt, _ = self.c.worktree()
        fx = self.fx()
        fx.thread("thr-parent", None, updated_h=1)
        fx.thread("thread:provider:claudeAgent:native-thread:child1", wt, updated_h=100)
        fx.subagent("thr-parent", status="running", child="thread:provider:claudeAgent:native-thread:child1")
        fx.close()
        result = self.gc("--apply")
        self.assertHeld(wt, result, "subagent running")

    def test_unknown_node_status_on_a_child_thread_holds_its_worktree(self):
        # The node read is per worktree thread: a subagent child id (with colons)
        # that owns the worktree is read like any other thread.
        wt, _ = self.c.worktree()
        child = "thread:provider:claudeAgent:native-thread:child2"
        fx = self.fx()
        fx.thread(child, wt, updated_h=100)
        fx.node(child, kind="tool_call", status="suspended")
        fx.close()
        result = self.gc("--apply")
        self.assertHeld(wt, result, "node tool_call suspended")

    # --- fail closed ----------------------------------------------------------------
    def test_missing_table_is_unreadable(self):
        wt, _ = self.c.worktree()
        fx = self.fx()
        fx.thread("thr-1", wt, updated_h=100)
        fx.con.execute("drop table orchestration_v2_projection_nodes")
        fx.close()
        self.assertUnreadable(wt, self.gc("--apply"), "T3 V2 schema: table orchestration_v2_projection_nodes is missing")

    def test_missing_column_is_unreadable(self):
        wt, _ = self.c.worktree()
        fx = self.fx()
        fx.thread("thr-1", wt, updated_h=100)
        fx.con.execute("alter table orchestration_v2_projection_runs drop column completed_at")
        fx.close()
        self.assertUnreadable(wt, self.gc("--apply"),
                              "T3 V2 schema: orchestration_v2_projection_runs has no column completed_at")

    def test_zero_threads_is_unreadable(self):
        wt, _ = self.c.worktree()
        self.fx().close()
        self.assertUnreadable(wt, self.gc("--apply"), "zero threads")

    def test_missing_database_with_a_server_runtime_file_is_unreadable(self):
        wt, _ = self.c.worktree()
        runtime_file(self.userdata, started_h=1)
        self.assertUnreadable(wt, self.gc("--apply"), "server-runtime.json exists but neither")

    def test_no_database_and_no_server_is_absent(self):
        wt, _ = self.c.worktree()
        result = self.gc("--apply")
        self.assertQuarantined(wt, result)
        self.assertIn("T3=absent", self.header(result))

    def test_stale_source_canary(self):
        for event_h, started_h, ok in ((5, 1, False), (0.5, 1, True)):
            with self.subTest(event_h=event_h, started_h=started_h):
                self.setUp()
                wt, _ = self.c.worktree()
                fx = self.fx(event_h=event_h)
                fx.thread("thr-1", wt, updated_h=100)
                fx.close()
                runtime_file(self.userdata, started_h=started_h)
                result = self.gc("--apply")
                if ok:
                    self.assertQuarantined(wt, result)
                else:
                    self.assertUnreadable(wt, result, "stale source: the newest event")

    def test_unreadable_runtime_file_is_unreadable(self):
        for raw in ("not json", "[]", '{"pid": 1}', '{"startedAt": "soon"}'):
            with self.subTest(raw=raw):
                self.setUp()
                wt, _ = self.c.worktree()
                fx = self.fx()
                fx.thread("thr-1", wt, updated_h=100)
                fx.close()
                runtime_file(self.userdata, raw=raw)
                self.assertUnreadable(wt, self.gc("--apply"), "has no readable startedAt")

    def test_newest_event_not_v2_is_unreadable(self):
        wt, _ = self.c.worktree()
        fx = self.fx()
        fx.thread("thr-1", wt, updated_h=100)
        fx.event("thr-1", "thread.turn-start-requested", version=1)
        fx.close()
        self.assertUnreadable(wt, self.gc("--apply"), "application_event_version 1, not 2")

    def test_bad_thread_payloads_are_unreadable(self):
        cases = {"payload not JSON": {"payload": "{not json"},
                 "payload array": {"payload": "[]"},
                 "payload null": {"payload": "null"},
                 "payload scalar": {"payload": "7"},
                 "relative worktreePath": {"payload": {"worktreePath": "relative/wt"}},
                 "worktreePath not a string": {"payload": {"worktreePath": 7}}}
        for name, kw in cases.items():
            with self.subTest(name):
                self.setUp()
                wt, _ = self.c.worktree()
                fx = self.fx()
                fx.thread("thr-bad", wt, updated_h=100, **kw)
                fx.thread("thr-1", wt, updated_h=100)
                fx.close()
                self.assertUnreadable(wt, self.gc("--apply"), "unreadable, all worktree removals blocked")

    # --- once per run, and the recheck ----------------------------------------------
    def test_snapshot_runs_once_per_run(self):
        wt_a, _ = self.c.worktree("landed")
        wt_b, _ = self.c.worktree("landed-b")
        fx = self.fx()
        fx.thread("thr-a", wt_a, updated_h=100)
        fx.thread("thr-b", wt_b, updated_h=100)
        fx.close()
        calls = self.c.root / "python-calls"
        wrapper = self.c.bin / "py-wrap"
        wrapper.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "' + str(calls) + '"\nexec "'
                           + sys.executable + '" "$@"\n')
        wrapper.chmod(0o755)
        self.c.env["BRANCH_GC_PYTHON"] = str(wrapper)
        result = self.gc("--apply")
        self.assertEqual(result.returncode, 0, self.out(result))
        self.assertFalse(wt_a.exists() or wt_b.exists(), self.out(result))
        lines = calls.read_text().splitlines()
        snapshots = [l for l in lines if l.endswith("/t3.hw")]
        rechecks = [l for l in lines if l.startswith("- " + str(self.v2db) + " ") and not l.endswith("/t3.hw")]
        self.assertEqual(len(snapshots), 1, lines)
        # Two candidates, each checked once in evaluation and once under the lock.
        self.assertEqual(len(rechecks), 4, lines)
        self.assertEqual(self.c.log().count("T3 v2 snapshot:"), 1)

    def test_activity_arriving_during_github_lookup_blocks_removal(self):
        wt, _ = self.c.worktree()
        fx = self.fx()
        fx.thread("thr-1", wt, updated_h=100, archived_h=90)
        fx.close()
        self.c.on_list(event_sql(self.v2db, "thr-1", "thread.unarchived"))
        result = self.gc("--apply")
        self.assertHeld(wt, result, "changed after this run's T3 snapshot")

    def test_new_thread_on_the_worktree_during_lookup_blocks_removal(self):
        wt, _ = self.c.worktree()
        fx = self.fx()
        fx.thread("thr-old", wt, updated_h=100)
        fx.close()
        self.c.on_list(
            f"_c = sqlite3.connect({str(self.v2db)!r})\n"
            f"_c.execute(\"insert into orchestration_v2_projection_threads (thread_id, project_id, title,"
            f" default_provider, runtime_mode, interaction_mode, created_at, updated_at, payload_json) values"
            f" ('thr-new', 'p', 't', 'claudeAgent', 'full-access', 'default', '2026-01-01T00:00:00.000Z',"
            f" '2026-01-01T00:00:00.000Z', json_object('worktreePath', ?))\", ({str(wt)!r},))\n"
            f"_c.commit()\n_c.close()\n" + event_sql(self.v2db, "thr-new", "thread.created"))
        self.assertHeld(wt, self.gc("--apply"), "thread thr-new changed after this run's T3 snapshot")

    def test_visit_during_lookup_does_not_block(self):
        wt, _ = self.c.worktree()
        fx = self.fx()
        fx.thread("thr-1", wt, updated_h=100)
        fx.close()
        self.c.on_list(event_sql(self.v2db, "thr-1", "thread.visited"))
        self.assertQuarantined(wt, self.gc("--apply"))

    def test_unprojected_thread_event_during_lookup_blocks_removal(self):
        wt, _ = self.c.worktree()
        fx = self.fx()
        fx.thread("thr-1", wt, updated_h=100)
        fx.close()
        self.c.on_list(event_sql(self.v2db, "thr-unknown", "run.created"))
        self.assertHeld(wt, self.gc("--apply"), "has no projection row")

    def test_database_gone_during_lookup_is_unreadable(self):
        wt, _ = self.c.worktree()
        fx = self.fx()
        fx.thread("thr-1", wt, updated_h=100)
        fx.close()
        self.c.on_list(f"import glob\nfor _p in glob.glob({str(self.v2db)!r} + '*'):\n"
                       f"    os.rename(_p, _p + '.aside')\n")
        self.assertUnreadable(wt, self.gc("--apply"), "T3 recheck of")

    def test_t3_appearing_during_lookup_is_unreadable(self):
        for source in ("v2", "v1", "runtime"):
            with self.subTest(source=source):
                self.setUp()
                wt, _ = self.c.worktree()
                other = self.c.root / "new-state.sqlite"
                if source == "v2":
                    fx = V2Fixture(other)
                    fx.thread("thr-1", wt, updated_h=1)
                    fx.close()
                    target = self.v2db
                elif source == "v1":
                    target = Path(self.c.env["BRANCH_GC_T3_DB"])
                    self.c.env["BRANCH_GC_T3_DB"] = str(other)
                    self.c.t3(wt, datetime.datetime.now(UTC).isoformat()).close()
                    self.c.env["BRANCH_GC_T3_DB"] = str(target)
                else:
                    other = runtime_file(self.c.root, started_h=1)
                    target = self.userdata / "server-runtime.json"
                self.c.on_list(f"os.rename({str(other)!r}, {str(target)!r})\n")
                self.assertUnreadable(wt, self.gc("--apply"), "T3 source appeared")

    def test_v2_appearing_during_v1_lookup_is_unreadable(self):
        wt, _ = self.c.worktree()
        self.c.t3(wt).close()
        other = self.c.root / "new-state.sqlite"
        fx = V2Fixture(other)
        fx.thread("thr-1", wt, updated_h=1)
        fx.close()
        self.c.on_list(f"os.rename({str(other)!r}, {str(self.v2db)!r})\n")
        self.assertUnreadable(wt, self.gc("--apply"), "appeared beside")

    def test_database_replaced_during_lookup_is_unreadable(self):
        wt, _ = self.c.worktree()
        fx = self.fx()
        fx.thread("thr-1", wt, updated_h=100)
        fx.close()
        other = self.c.root / "replacement.sqlite"
        fx = V2Fixture(other)
        fx.thread("thr-1", wt, updated_h=1)
        fx.close()
        self.c.on_list(f"os.replace({str(other)!r}, {str(self.v2db)!r})\n")
        self.assertUnreadable(wt, self.gc("--apply"), "T3 V2 source changed")

    def test_server_restarted_during_lookup_is_unreadable(self):
        wt, _ = self.c.worktree()
        fx = self.fx(event_h=0.5)
        fx.thread("thr-1", wt, updated_h=100)
        fx.close()
        runtime_file(self.userdata, started_h=1)
        self.c.on_list(
            f"import datetime, json\n"
            f"pathlib.Path({str(self.userdata / 'server-runtime.json')!r}).write_text("
            f"json.dumps({{'startedAt': datetime.datetime.now(datetime.timezone.utc).isoformat()}}))\n")
        self.assertUnreadable(wt, self.gc("--apply"), "stale source")

    def test_event_high_water_rewind_during_lookup_is_unreadable(self):
        wt, _ = self.c.worktree()
        fx = self.fx()
        fx.thread("thr-1", wt, updated_h=100)
        fx.event("thr-1")
        fx.close()
        self.c.on_list(
            f"_c = sqlite3.connect({str(self.v2db)!r})\n"
            f"_c.execute('delete from orchestration_events where sequence > 1')\n_c.commit()\n_c.close()\n")
        self.assertUnreadable(wt, self.gc("--apply"), "event high-water regressed")

    def test_non_v2_event_during_lookup_is_unreadable(self):
        wt, _ = self.c.worktree()
        fx = self.fx()
        fx.thread("thr-1", wt, updated_h=100)
        fx.close()
        self.c.on_list(event_sql(self.v2db, "thr-1", "thread.metadata-updated", version=1))
        self.assertUnreadable(wt, self.gc("--apply"), "application_event_version")

    def test_invalid_worktree_path_during_lookup_is_unreadable(self):
        for path in ("relative/wt", "/ambiguous\tworktree"):
            with self.subTest(path=path):
                self.setUp()
                wt, _ = self.c.worktree()
                fx = self.fx()
                fx.thread("thr-1", wt, updated_h=100)
                fx.close()
                self.c.on_list(
                    f"_c = sqlite3.connect({str(self.v2db)!r})\n"
                    f"_c.execute(\"update orchestration_v2_projection_threads set payload_json ="
                    f" json_set(payload_json, '$.worktreePath', ?)\", ({path!r},))\n_c.commit()\n_c.close()\n"
                    + event_sql(self.v2db, "thr-1", "thread.metadata-updated"))
                self.assertUnreadable(wt, self.gc("--apply"), "ambiguous worktreePath")

    def test_subagent_started_during_lookup_holds_its_child_worktree(self):
        wt, _ = self.c.worktree()
        fx = self.fx()
        fx.thread("thr-parent", None, updated_h=100)
        fx.thread("thr-child", wt, updated_h=100)
        fx.subagent("thr-parent", status="completed", child="thr-child")
        fx.close()
        self.c.on_list(
            f"_c = sqlite3.connect({str(self.v2db)!r})\n"
            f"_c.execute(\"update orchestration_v2_projection_subagents set status = 'running'\")\n"
            f"_c.commit()\n_c.close()\n" + event_sql(self.v2db, "thr-parent", "thread.turn-start-requested"))
        self.assertHeld(wt, self.gc("--apply"), "thread thr-chil changed after this run's T3 snapshot")

    def test_transient_recheck_failure_blocks_every_later_worktree(self):
        wt_a, _ = self.c.worktree()
        wt_b, _ = self.c.worktree("landed-b")
        fx = self.fx()
        fx.thread("thr-a", wt_a, updated_h=100)
        fx.thread("thr-b", wt_b, updated_h=100)
        fx.close()
        calls = self.c.root / "rechecks"
        wrapper = self.c.bin / "py-wrap"
        wrapper.write_text(
            f"#!{sys.executable}\nimport os, pathlib, sys\n"
            f"calls = pathlib.Path({str(calls)!r})\n"
            f"if len(sys.argv) == 8 and sys.argv[2] == {str(self.v2db)!r}:\n"
            f"    previous = calls.read_text() if calls.exists() else ''\n"
            f"    calls.write_text(previous + 'recheck\\n')\n"
            f"    if not previous:\n"
            f"        sys.stderr.write('transient read failure')\n        sys.exit(1)\n"
            f"os.execv({sys.executable!r}, [{sys.executable!r}, *sys.argv[1:]])\n")
        wrapper.chmod(0o755)
        self.c.env["BRANCH_GC_PYTHON"] = str(wrapper)
        result = self.gc("--apply")
        self.assertUnreadable(wt_a, result, "transient read failure")
        self.assertTrue(wt_b.exists(), self.out(result))
        self.assertTrue(self.c.has_branch("landed-b"), self.out(result))
        self.assertEqual(calls.read_text(), "recheck\n")


if __name__ == "__main__":
    unittest.main()
