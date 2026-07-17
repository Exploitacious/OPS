# Work Tracking

> **This is a template — it has not been filled in yet.**
> Until you fill it in, this file describes *what a work-tracking config holds*,
> not *your systems*. Every block below marked **EXAMPLE** is synthetic (Example
> Corp flavor). The examples exist to show the shape each section needs — they
> are not defaults to inherit and they are not your real tools.
>
> **Fill this in during `BOOTSTRAP.md` (or the first time you close a session).**
> Replace every EXAMPLE block with your own systems, or delete the blocks you
> don't need. Delete this banner once the file is real.
>
> Why this matters: the `session-close` skill reads this file at close time to
> run its **WIP & work-tracking reconciliation gate** — the step that makes your
> tickets / time / board reflect what the session actually did before the
> session is gone. This file is the *only* place that gate learns your systems;
> it hardcodes nothing. If a section is empty, the gate degrades gracefully for
> that surface (see "If nothing here is configured" at the bottom) — it never
> fails, and it never invents a system you don't have.

<!--
  SECTION: How you record time
  Answers: When you finish a unit of work, where does the time go, and HOW does
  the AI put it there? Two mechanisms are supported, and you can mix them:
    - "tool" — you have (or will wire) an MCP tool the AI can call directly.
      Name the exact tool the way it will appear to the AI (server + tool), plus
      any fixed arguments it always needs (your user/resource id, default work
      type). The gate calls it only after you authorize the specific write.
    - "manual" — no tool, or you'd rather log it yourself. The gate DRAFTS the
      time entry text (hours + a concrete summary pulled from the commits) and
      hands it to you to paste into your system. This is the default fallback.
  If you don't bill anyone, say so — the gate will track effort without ever
  treating it as billable.
-->

**EXAMPLE — replace on bootstrap:**

- **Mechanism:** tool.
- **Tool:** `psa__log_time` on my PSA MCP server. Fixed args it always needs:
  `resource = "<my-user-id>"`, `work_type = "regular"`. The gate proposes hours
  + a note; I confirm before it calls the tool.
- **Companion note tool:** `psa__add_note` — attach a short summary of what
  shipped to the same work item (pull it from commit subjects, not "worked on
  stuff").
- **"Already logged today" check:** before proposing anything, ask my time
  system what's already recorded for today (tool `psa__time_overview` for my
  user id) so a day captured elsewhere never gets double-logged.
- **Billable vs not:** client work is billable; internal/overhead work is
  logged for tracking but not billed; personal-side work takes no entry — note
  "personal — skipped" and move on. Some work is genuinely non-trackable — ask,
  don't assume.

<!--
  SECTION: Where units of work live (ticketing / work-tracking system)
  Answers: What is a "unit of work" for you — a ticket, an issue, a work order —
  and in what system does it live? The gate resolves each thing the session
  touched to a candidate item here, then asks you to confirm before writing.
  Name the system and the mechanism (tool or manual), same as above. State your
  resolution rule: a repo/project is rarely 1:1 with one item, so tell the AI
  whether to confirm every time (recommended) or trust a mapping.
-->

**EXAMPLE — replace on bootstrap:**

- **System:** my PSA's ticket module.
- **Mechanism:** tool — `psa__find_ticket` to locate the open item for a work
  area, `psa__create_ticket` to open one when none exists.
- **Resolution rule:** a repo is NOT 1:1 with a ticket — phase-scoped work
  spawns new tickets. The gate proposes a candidate and I confirm it's the right
  OPEN item; it never auto-picks and never terminally closes an item on my
  behalf.
- **New labor with no item:** open the item FIRST, then log against it — never
  log orphaned work (see the principle in the gate).

<!--
  SECTION: Boards and personal task trackers (optional)
  Answers: Do you run a kanban/board where cards advance as work progresses, and
  do you keep a personal task list? If yes, name each and how the AI advances a
  card / ticks a task (tool or manual). If you don't use these, delete this
  section — the gate simply won't ask about a board you don't have.
-->

**EXAMPLE — replace on bootstrap:**

- **Board:** "Active Projects" kanban. Tool `board__update_card` — advance
  percent + lifecycle label + a title stamp when a session moves a card. Keep
  this write separate from the time entry.
- **Personal task tracker:** my personal to-do app. Tool `todo__complete` /
  `todo__edit` to tick or update sidequest items touched this session.
- **Blockers:** when work is blocked, mark the card `Waiting — Blocked` and add
  a note naming the block, rather than advancing it.

<!--
  SECTION: Learned repo → tracked-item map (optional, grow it over time)
  Answers: Which repo/project maps to which recurring ticket/card, so next time
  the gate's first guess is right? Start empty. Each time you CONFIRM a new
  repo→item association during a close, the gate appends a row here tagged with
  the date it learned it. This is a convenience cache, never an auto-attribution
  — the gate still confirms the item is the right OPEN one before writing.
-->

**EXAMPLE — replace on bootstrap:**

| Repo / work area | Ticket / item | Board card | Notes |
|------------------|---------------|------------|-------|
| example-webapp   | TCK-1042      | Webapp     | (learned 2026-01-15) |
| example-infra    | TCK-0998      | Infra      | phase work spawns new tickets — confirm |

<!--
  SECTION: If nothing here is configured
  This block is doctrine, not an example — leave it in place. It states what the
  gate does when a surface above is blank.
-->

## If nothing here is configured

The reconciliation gate **still runs** — configuration only changes *how* it
writes, never *whether* it reconciles. With a surface left blank, the gate:

- assembles the session's work picture from the work-log + git delta anyway;
- for each unit of work, **drafts** the entry text (hours + a concrete summary,
  or a status/note line) instead of calling a tool; and
- reminds you, in the closeout receipt, to log it yourself in whatever system
  you use.

A blank config is a valid, supported state — the gate degrades to "draft and
remind," never to silence. Fill a section in only when wiring a tool earns the
automation.
