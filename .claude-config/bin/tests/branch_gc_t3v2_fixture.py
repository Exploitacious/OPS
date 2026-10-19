"""Synthetic T3 Code 0.1.0 (Orchestrator V2) state for the branch-gc suites.

The tables, columns and indexes below are the ones branch-gc's V2 reader uses,
copied from the CREATE statements of the live statev2.sqlite of T3 0.1.0 (read
with mode=ro and PRAGMA query_only on 2026-10-17). Every row a test writes is
synthetic: ids, titles and paths come from the test, never from a live thread.

    fx = V2Fixture(userdata / "statev2.sqlite")
    fx.thread("t1", worktree, updated_h=1, archived_h=50)
    fx.run("t1", "running", requested_h=0.5)
    fx.close()
    runtime_file(userdata, started_h=2)

The database is WAL, like the live one, so the reader's mode=ro open is exercised
against a WAL file. A fresh fixture holds one V2 event `event_h` hours old (default
0, now): the stale-source canary needs a newest event, and tests that pin the
canary move it.
"""
import datetime
import json
import sqlite3
from pathlib import Path

SCHEMA = """
CREATE TABLE orchestration_v2_projection_threads (
      thread_id TEXT PRIMARY KEY,
      project_id TEXT NOT NULL,
      title TEXT NOT NULL,
      default_provider TEXT NOT NULL,
      runtime_mode TEXT NOT NULL,
      interaction_mode TEXT NOT NULL,
      active_provider_thread_id TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      archived_at TEXT,
      deleted_at TEXT,
      payload_json TEXT NOT NULL
    , provider_instance_id TEXT);
CREATE TABLE orchestration_v2_legacy_imports (
      thread_id TEXT PRIMARY KEY,
      source_updated_at TEXT NOT NULL,
      shell_imported_at TEXT NOT NULL,
      transcript_imported_at TEXT,
      imported_message_count INTEGER NOT NULL DEFAULT 0,
      last_error TEXT
    );
CREATE TABLE orchestration_v2_projection_messages (
      message_id TEXT PRIMARY KEY,
      thread_id TEXT NOT NULL,
      run_id TEXT,
      node_id TEXT,
      role TEXT NOT NULL,
      streaming INTEGER NOT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      payload_json TEXT NOT NULL
    );
CREATE TABLE orchestration_v2_projection_runs (
      run_id TEXT PRIMARY KEY,
      thread_id TEXT NOT NULL,
      ordinal INTEGER NOT NULL,
      provider TEXT NOT NULL,
      provider_thread_id TEXT,
      status TEXT NOT NULL,
      requested_at TEXT NOT NULL,
      completed_at TEXT,
      payload_json TEXT NOT NULL
    , provider_instance_id TEXT);
CREATE TABLE orchestration_v2_projection_runtime_requests (
      runtime_request_id TEXT PRIMARY KEY,
      thread_id TEXT NOT NULL,
      node_id TEXT NOT NULL,
      provider_turn_id TEXT,
      kind TEXT NOT NULL,
      status TEXT NOT NULL,
      created_at TEXT NOT NULL,
      resolved_at TEXT,
      payload_json TEXT NOT NULL
    );
CREATE TABLE orchestration_v2_projection_nodes (
      node_id TEXT PRIMARY KEY,
      thread_id TEXT NOT NULL,
      run_id TEXT,
      parent_node_id TEXT,
      root_node_id TEXT NOT NULL,
      kind TEXT NOT NULL,
      status TEXT NOT NULL,
      provider_thread_id TEXT,
      provider_turn_id TEXT,
      runtime_request_id TEXT,
      checkpoint_scope_id TEXT,
      started_at TEXT,
      completed_at TEXT,
      payload_json TEXT NOT NULL
    );
CREATE TABLE orchestration_v2_projection_subagents (
      subagent_id TEXT PRIMARY KEY,
      thread_id TEXT NOT NULL,
      run_id TEXT,
      parent_node_id TEXT NOT NULL,
      provider TEXT NOT NULL,
      provider_thread_id TEXT,
      child_thread_id TEXT,
      origin TEXT NOT NULL,
      status TEXT NOT NULL,
      started_at TEXT,
      completed_at TEXT,
      updated_at TEXT NOT NULL,
      payload_json TEXT NOT NULL
    , driver TEXT, provider_instance_id TEXT);
CREATE TABLE orchestration_v2_projection_turn_items (
      turn_item_id TEXT PRIMARY KEY,
      thread_id TEXT NOT NULL,
      run_id TEXT,
      node_id TEXT,
      provider_thread_id TEXT,
      provider_turn_id TEXT,
      parent_item_id TEXT,
      ordinal INTEGER NOT NULL,
      type TEXT NOT NULL,
      status TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      payload_json TEXT NOT NULL
    );
CREATE TABLE orchestration_events (
      sequence INTEGER PRIMARY KEY AUTOINCREMENT,
      event_id TEXT NOT NULL UNIQUE,
      aggregate_kind TEXT NOT NULL,
      stream_id TEXT NOT NULL,
      stream_version INTEGER NOT NULL,
      event_type TEXT NOT NULL,
      occurred_at TEXT NOT NULL,
      command_id TEXT,
      causation_event_id TEXT,
      correlation_id TEXT,
      actor_kind TEXT NOT NULL,
      payload_json TEXT NOT NULL,
      metadata_json TEXT NOT NULL
    , application_event_version INTEGER NOT NULL DEFAULT 1);
CREATE INDEX orchestration_v2_projection_messages_thread_created_idx ON orchestration_v2_projection_messages(thread_id, created_at, message_id);
CREATE INDEX orchestration_v2_projection_messages_latest_user_idx ON orchestration_v2_projection_messages(thread_id, updated_at DESC, message_id DESC) WHERE role = 'user';
CREATE UNIQUE INDEX orchestration_v2_projection_runs_thread_ordinal_idx ON orchestration_v2_projection_runs(thread_id, ordinal);
CREATE INDEX orchestration_v2_projection_runs_thread_status_idx ON orchestration_v2_projection_runs(thread_id, status);
CREATE INDEX orchestration_v2_projection_runs_recovery_idx ON orchestration_v2_projection_runs(status, thread_id) WHERE status IN ('queued', 'preparing', 'starting', 'running', 'waiting');
CREATE INDEX orchestration_v2_projection_runtime_requests_thread_status_idx ON orchestration_v2_projection_runtime_requests(thread_id, status);
CREATE INDEX orchestration_v2_projection_requests_recovery_idx ON orchestration_v2_projection_runtime_requests(thread_id) WHERE status = 'pending';
CREATE INDEX orchestration_v2_projection_nodes_thread_run_idx ON orchestration_v2_projection_nodes(thread_id, run_id);
CREATE INDEX orchestration_v2_projection_nodes_live_idx ON orchestration_v2_projection_nodes(thread_id) WHERE status IN ('pending', 'starting', 'running', 'waiting');
CREATE INDEX orchestration_v2_projection_subagents_child_thread_idx ON orchestration_v2_projection_subagents(child_thread_id);
CREATE INDEX orchestration_v2_projection_turn_items_shell_pending_idx ON orchestration_v2_projection_turn_items(thread_id, run_id) WHERE type IN ('command_execution', 'dynamic_tool', 'subagent') AND status NOT IN ('completed', 'interrupted', 'failed', 'cancelled');
CREATE INDEX idx_orch_events_stream_sequence ON orchestration_events(aggregate_kind, stream_id, sequence);
CREATE INDEX idx_orchestration_events_application_sequence ON orchestration_events(application_event_version, sequence);
CREATE INDEX idx_orchestration_events_agent_stream_sequence ON orchestration_events(stream_id, sequence) WHERE application_event_version = 2 AND aggregate_kind = 'thread';
"""

UTC = datetime.timezone.utc


def iso(when):
    """T3's own spelling: millisecond precision, Z suffix."""
    return when.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (when.microsecond // 1000)


class V2Fixture:
    def __init__(self, path, event_h=0.0, now=None):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.now = now or datetime.datetime.now(UTC)
        self.con = sqlite3.connect(str(self.path))
        self.con.execute("PRAGMA journal_mode=WAL")
        self.con.executescript(SCHEMA)
        self.n = 0
        self.event("project-fixture", "project.created", hours=event_h, aggregate="project")
        self.con.commit()

    def ago(self, hours):
        return iso(self.now - datetime.timedelta(hours=hours))

    def _id(self, kind):
        self.n += 1
        return "%s-%d" % (kind, self.n)

    def thread(self, tid, worktree, updated_h, archived_h=None, deleted_h=None,
               snoozed_until=None, last_visited_h=None, payload=None, updated_at=None):
        """One thread row. `payload` replaces payload_json verbatim (str) or extends it (dict)."""
        doc = {"id": tid, "projectId": "proj-fixture", "title": "fixture " + tid,
               "worktreePath": None if worktree is None else str(worktree),
               "createdAt": self.ago(500), "updatedAt": updated_at or self.ago(updated_h),
               "archivedAt": None if archived_h is None else self.ago(archived_h),
               "deletedAt": None if deleted_h is None else self.ago(deleted_h),
               "snoozedUntil": snoozed_until, "snoozedAt": None,
               "lastVisitedAt": None if last_visited_h is None else self.ago(last_visited_h),
               "settledAt": None, "branch": None, "pullRequests": [],
               "lineage": {"parentThreadId": None, "relationshipToParent": None}}
        if isinstance(payload, dict):
            doc.update(payload)
        body = payload if isinstance(payload, str) else json.dumps(doc)
        self.con.execute(
            "insert into orchestration_v2_projection_threads (thread_id, project_id, title, default_provider,"
            " runtime_mode, interaction_mode, created_at, updated_at, archived_at, deleted_at, payload_json)"
            " values (?, 'proj-fixture', ?, 'claudeAgent', 'full-access', 'default', ?, ?, ?, ?, ?)",
            (tid, "fixture " + tid, self.ago(500), updated_at or self.ago(updated_h),
             doc["archivedAt"], doc["deletedAt"], body))
        self.con.commit()

    def legacy_import(self, tid, source_h, transcript_h=None):
        """A V1 thread imported at the upgrade; no transcript_h means not hydrated (no V2 messages)."""
        self.con.execute(
            "insert into orchestration_v2_legacy_imports (thread_id, source_updated_at, shell_imported_at,"
            " transcript_imported_at) values (?, ?, ?, ?)",
            (tid, self.ago(source_h), self.ago(26), None if transcript_h is None else self.ago(transcript_h)))
        self.con.commit()

    def message(self, tid, created_h, updated_h=None, role="user", created_at=None, updated_at=None):
        self.con.execute(
            "insert into orchestration_v2_projection_messages (message_id, thread_id, role, streaming,"
            " created_at, updated_at, payload_json) values (?, ?, ?, 0, ?, ?, '{}')",
            (self._id("msg"), tid, role, created_at or self.ago(created_h),
             updated_at or self.ago(created_h if updated_h is None else updated_h)))
        self.con.commit()

    def run(self, tid, status, requested_h, completed_h=None):
        ordinal = self.con.execute("select count(*) + 1 from orchestration_v2_projection_runs where thread_id = ?",
                                   (tid,)).fetchone()[0]
        self.con.execute(
            "insert into orchestration_v2_projection_runs (run_id, thread_id, ordinal, provider, status,"
            " requested_at, completed_at, payload_json) values (?, ?, ?, 'claudeAgent', ?, ?, ?, '{}')",
            (self._id("run"), tid, ordinal, status, self.ago(requested_h),
             None if completed_h is None else self.ago(completed_h)))
        self.con.commit()

    def runtime_request(self, tid, status="pending", kind="user_input"):
        self.con.execute(
            "insert into orchestration_v2_projection_runtime_requests (runtime_request_id, thread_id, node_id,"
            " kind, status, created_at, payload_json) values (?, ?, ?, ?, ?, ?, '{}')",
            (self._id("req"), tid, self._id("node"), kind, status, self.ago(0.5)))
        self.con.commit()

    def node(self, tid, kind="tool_call", status="running"):
        nid = self._id("node")
        self.con.execute(
            "insert into orchestration_v2_projection_nodes (node_id, thread_id, root_node_id, kind, status,"
            " started_at, payload_json) values (?, ?, ?, ?, ?, ?, '{}')",
            (nid, tid, nid, kind, status, self.ago(0.5)))
        self.con.commit()

    def subagent(self, tid, status="running", child=None):
        self.con.execute(
            "insert into orchestration_v2_projection_subagents (subagent_id, thread_id, parent_node_id, provider,"
            " child_thread_id, origin, status, updated_at, payload_json)"
            " values (?, ?, ?, 'claudeAgent', ?, 'provider_native', ?, ?, '{}')",
            (self._id("sub"), tid, self._id("node"), child, status, self.ago(0.5)))
        self.con.commit()

    def turn_item(self, tid, type_="command_execution", status="running"):
        self.con.execute(
            "insert into orchestration_v2_projection_turn_items (turn_item_id, thread_id, ordinal, type, status,"
            " updated_at, payload_json) values (?, ?, ?, ?, ?, ?, '{}')",
            (self._id("item"), tid, self.n, type_, status, self.ago(0.5)))
        self.con.commit()

    def event(self, stream, event_type="thread.metadata-updated", hours=0.0, version=2, aggregate="thread",
              occurred_at=None):
        self.con.execute(
            "insert into orchestration_events (event_id, aggregate_kind, stream_id, stream_version, event_type,"
            " occurred_at, actor_kind, payload_json, metadata_json, application_event_version)"
            " values (?, ?, ?, ?, ?, ?, 'server', '{}', '{}', ?)",
            (self._id("evt"), aggregate, stream, self.n, event_type, occurred_at or self.ago(hours), version))
        self.con.commit()

    def close(self):
        self.con.commit()
        self.con.close()


def runtime_file(userdata, started_h=None, raw=None, now=None):
    """server-runtime.json as T3 0.1.0 writes it (startedAt), or `raw` text verbatim."""
    now = now or datetime.datetime.now(UTC)
    path = Path(userdata) / "server-runtime.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    if raw is None:
        raw = json.dumps({"version": 1, "pid": 1, "port": 1, "origin": "http://127.0.0.1:1",
                          "startedAt": iso(now - datetime.timedelta(hours=started_h or 0))})
    path.write_text(raw)
    return path
