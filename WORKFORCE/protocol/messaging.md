# Protocol — Messaging

Rules for inter-agent messaging. Every Agent and Coordinator
follows these. The Operator does not write messages directly; the
Operator talks in the Claude Code conversation, and agents act on
that.

## Runtime context

The file-based protocol in this document IS the inter-agent
communication runtime — not a fallback layer under an official
Anthropic multi-agent feature. `ac-msg` writes atomically (tmp +
rename) into `runtime/inbox/<recipient>/`; that inbox is the
mailbox. `runtime/tasks/*.md` (hand-edited per the task-spec format
in `personalities/COORDINATOR.md`) is the shared task list. There
is no separate primitive underneath either.

This protocol also serves as the **audit trail**: every
inter-agent exchange that's load-bearing (task assignment,
blockers, escalations, decisions) lands as a file in
`runtime/archive/<name>/` once processed — the durable record a
future Coordinator or Agent reads even if they weren't live to see
the original exchange. Per-project `runtime/` is machine-local, not
git-synced (see `WORKFORCE/README.md`), so the durability here is
"survives on this machine's disk," not "syncs across machines."

Native Claude Code orchestration primitives — the Agent tool +
`SendMessage`, background `Workflow`, `TaskCreate` — exist and cover
intra-session fan-out (operating-doctrine P12's orchestration tiers
2-3), but they live and die inside one process. This file-based
protocol is what a peer in a separate tmux window — a process the
parent doesn't share memory with — uses instead.

Operational rule: every load-bearing inter-agent exchange goes
through `ac-msg`. There is no faster in-process channel to prefer
over it for cross-peer work — that's the whole reason this protocol
exists.

---

## Files and directories

```
runtime/
├── inbox/<name>/          # messages waiting for <name> to read
├── outbox/                # composing (rarely needed; usually you write directly to tmp/ then rename)
├── archive/<name>/        # messages <name> has processed (immutable)
├── tmp/                   # atomic write staging
└── log.jsonl              # append-only event log
```

- `<name>` is an agent's name (e.g., `Bravo`) or the literal
  `operator` for messages destined for the Operator's escalation
  inbox.
- `runtime/inbox/<name>/` is created automatically on agent
  activation (`mkdir -p`).

---

## Message file format

**Filename:** `<UTC-ISO-compact>__<from>__<topic-slug>.md`

- UTC ISO compact replaces colons with hyphens for filesystem
  safety: `2026-05-11T15-12-34Z`.
- `from` is the sender's name (e.g., `Bravo`, `Sigma`).
- `topic-slug` is kebab-case. Prefix with PR number where
  applicable (`pr-122-merged`). Reply prefixes: `re__<topic>` or
  `ack__<topic>`.

Example: `2026-05-11T15-12-34Z__Bravo__pr-72-opened.md`

**Body:** YAML frontmatter + markdown.

```markdown
---
id: 2026-05-11T15-12-34Z__Bravo__pr-72-opened
from: Bravo
to: Sigma
ts: 2026-05-11T15:12:34Z
topic: pr-72-opened
refs:
  - sample-app#72
  - infra#41
awaits: null
priority: normal
in_reply_to: null
---

# Body in markdown.

What changed, what's actionable, what to expect.
```

### Required fields

| Field | Values |
|---|---|
| `id` | filename without `.md`, exactly matches the filename |
| `from` | sender's agent name |
| `to` | recipient: agent name, `operator`, or `broadcast` |
| `ts` | ISO-8601 UTC with colons (e.g., `2026-05-11T15:12:34Z`) |
| `topic` | short stable identifier |
| `refs` | list of PR / commit / issue refs (`repo#nn`, sha) — optional but recommended |
| `awaits` | `<message-id>` if sender wants reconciliation on recipient's next inbox check; `null` otherwise |
| `priority` | `urgent` \| `normal` \| `fyi` |
| `in_reply_to` | original message id if this is a reply; `null` otherwise |

### Priority semantics

- `urgent` — recipient acts on next inbox check. Use sparingly:
  prod outage, scope conflict that blocks both agents, security
  issue, irreversible-action gate hit.
- `normal` — default. Recipient processes during regular inbox sweep.
- `fyi` — state-share only. No action expected. Log and move on.

### `awaits` — the deadlock fix

The old protocol had `requires_ack: true` which got read as "block."
The new field is `awaits: <message-id>`. Semantics:

- Set `awaits: <self-id>` if you want the recipient to know you'll
  reconcile their reply on your *next* inbox check (not block now).
- Set `awaits: null` if no reply is needed. This is the default.
- **You never block on `awaits`.** If you genuinely cannot proceed
  without the reply, you mark your task `status: blocked` and
  switch to other work. You do not idle in a conversation waiting
  for an inbox file.

The Coordinator surfaces `blocked` tasks if they sit blocked
beyond a reasonable window.

---

## Atomicity rules

1. **Never edit a message file in `inbox/`, `archive/`, or
   anywhere else** once it's been written. Corrections = new
   message (`topic: re__<original>` with `in_reply_to` set).
2. **Never write directly into `inbox/<other>/`.** Always write to
   `runtime/tmp/<id>.md` first, then `mv` it into the inbox. Rename
   is atomic on the same filesystem.
3. **Never delete from `archive/`.** Immutable history. Rotation
   is by `tar`-and-archive, not deletion.
4. **`log.jsonl` is append-only.** Use `flock` or single-line
   echo (atomic for small writes on Linux).
5. **Pulse files are the only files written in place** — and even
   those use `tmp` + rename. Never `>` redirect (which truncates
   mid-write and races).
6. **Manifest files are also tmp + rename.** Per-agent `.json`
   files in `manifest.d/`.

---

## Send procedure (step by step)

You want to send a message from `Bravo` to `Charlie`:

```bash
TS_COMPACT="2026-05-11T15-12-34Z"
TS_ISO="2026-05-11T15:12:34Z"
ID="${TS_COMPACT}__Bravo__pr-72-opened"

# 1. Compose in tmp
cat > "runtime/tmp/${ID}.md" <<EOF
---
id: ${ID}
from: Bravo
to: Charlie
ts: ${TS_ISO}
topic: pr-72-opened
refs:
  - sample-app#72
awaits: null
priority: normal
in_reply_to: null
---

PR #72 opened in N8nAutomations. Replaces api_query calls in
WF1/newticket/msteams with resolve_id. Doesn't touch MCP-side.
FYI in case you wire something new to api_query.
EOF

# 2. Atomic move into recipient's inbox
mv "runtime/tmp/${ID}.md" "runtime/inbox/Charlie/${ID}.md"

# 3. Append to log
flock runtime/log.jsonl -c \
  "echo '{\"ts\":\"${TS_ISO}\",\"from\":\"Bravo\",\"to\":\"Charlie\",\"id\":\"${ID}\",\"topic\":\"pr-72-opened\",\"priority\":\"normal\"}' >> runtime/log.jsonl"
```

In Pass 2, the `bin/ac-msg` script wraps this.

For now, write the file via Claude Code tools (Write tool, then a
Bash `mv` to inbox, then Bash to append the log line).

---

## Receive procedure (every inbox sweep)

Done at session start, before major actions, and before exit.

```
for each file in runtime/inbox/<self>/, oldest first:
  read frontmatter
  process body — act if actionable, log to journal if context-only
  if awaits is set:
    queue a reply (write to tmp, then mv to inbox/<sender>/)
  mv file to runtime/archive/<self>/
```

Never process out of order. Filename timestamps determine ordering.

---

## Common topics

| Topic | Meaning |
|---|---|
| `hello` | Activation greeting; FYI only |
| `pr-<n>-opened` | New PR; other side should know |
| `pr-<n>-merged` | PR merged + deployed; include rollout state |
| `pr-<n>-question` | Question about something in the PR |
| `re__<topic>` | Reply (back-and-forth) |
| `ack__<topic>` | Confirmation; closes the loop (audit only, not gate) |
| `task-assigned` | Coordinator assigning work to an agent |
| `task-done` | Agent reporting completion to Coordinator |
| `task-blocked` | Agent reporting a blocker |
| `dep-<name>-ready` | A specific dependency is ready to consume |
| `escalation-<slug>` | Conflict needing Operator |
| `decision-filed` | New decision record committed; pointer in body |
| `coordinator-online` | Sigma announcing they're up |
| `coordinator-offline` | Sigma announcing they're going idle |

---

## Broadcast

To send to all active agents, set `to: broadcast` and `mv` the
file into each active agent's inbox. The log gets one line per
recipient.

Use broadcasts sparingly. Coordinator-online is a typical use case.

---

## What doesn't go in messages

- Secrets, API keys, credentials. Hard rule.
- Customer PII.
- Anything that needs version control (use a real PR review or
  decision record).
- Long-form architectural prose (use `protocol/decisions.md` and
  link from the message).

---

## Rotation

Monthly:

```bash
# Rename and gzip the current log
mv runtime/log.jsonl runtime/log-$(date -u +%Y-%m).jsonl
gzip runtime/log-$(date -u +%Y-%m).jsonl
touch runtime/log.jsonl
```

Archive rotation: `tar` messages older than 90 days into
`runtime/archive/<name>-<yyyy-mm>.tar.gz`, then delete the loose
files. Both Coordinator and Agent can do this; either announces
via FYI message before doing it.
