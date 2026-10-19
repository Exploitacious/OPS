---
name: stewardship
description: "Apply when an MCP tool or a skill returns errors, wrong data, or instructions that do not match reality. Surface the defect instead of silently working around it."
---

# Stewardship

The MCP tools and skills in this harness are built and tuned by the people who use them, and defects and gaps surface during real work, not during development. So a surprising result is evidence about the tool or the skill, not only about your task. Read it that way.

## Triage a tool result

Retry once for a transient fault on a read: a timeout, a 5xx, a dropped connection. If the retry succeeds, move on. A call that changes anything is different, because after a timeout or a dropped connection you do not know whether it ran: read the target's current state before any retry.

A gateway timeout (an MCP "Request timed out", JSON-RPC `-32001`) does not tell you whether the call ran. The change may have been applied, partly applied, or still be finishing. For a tool that changes anything, read the target's current state before retrying, because a repeat call can apply the change twice. A read-only call is safe to retry.

A tool that reports itself retired or renamed, and executed nothing, is not a defect in your task. Refresh your tool list and call the replacement it names. Report which prompt, skill, or workflow still names the old tool: that is the stale source to fix. Retrying the same name never helps.

Anything else is a defect. Wrong data, a schema that does not match what the tool returned, a silent empty where there should be rows, a parameter that does not behave the way its documentation says. Never silently work around a defect and move on as if the tool were fine.

## Triage a skill

The same doctrine covers the skills you load. When a skill's instruction is wrong, stale, unclear, or silent on the case in front of you, that is a skill defect. Do not quietly deviate from it and forget you did.

## Stay on task

Surfacing a defect does not mean dropping your work to chase it. Note the defect where you track your work, apply the minimal workaround, and finish the job. Fix at the source mid-task only when the task is blocked without the fix.

## Follow through by capability

What surfacing looks like depends on your access.

If you have repo access, fix the defect at the source once the task is done.

- A skill that lives in `SKILLS/<name>/` is edited there. A mounted skill (a row in `SKILLS/VENDORED.tsv`) is edited at its source repo under `PROJECTS/` and re-mirrored with `skills-vendor.sh sync`, never in the `SKILLS/` mirror, because the sync overwrites a hand-edited mirror. Open a PR in the source repo and bump its version when it carries one, so the fix reaches every install.
- A tool lives in its own repo. Before you change one, find out whether its interface is a frozen contract that other automations parse. Never rename a frozen tool or change its response shape, keep every fix backward-compatible, and get the owner's sign-off before any interface change.

You may have no repo access at all, for example on a consumer surface or a staff seat. Send a short report through whatever channel you have to whoever maintains the tool or skill (the operator, or the maintainers named in `CONTEXT/team.md` when that slot is filled). Name the tool or skill, say what you sent, what came back, and what you expected instead. Surfacing it is the whole job, and someone with access takes it from there.

## Why it is worth the interruption

Every tool fixed and every skill sharpened upgrades every agent and every person using the library at once.
