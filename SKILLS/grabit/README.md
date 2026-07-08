# grabit (skill)

**Purpose:** Send real files from a (usually headless) OPS box to the operator's machine over Tailscale, landing in Downloads — via the `grabit` binary, not in-chat delivery. Corrects the default reflex to hand files back as chat attachments.

**Files:**
- `SKILL.md` — the skill: trigger phrases, the `grabit` command + all modes (push / `--to` / `--serve` / `--inbox` / `--list`), workflow, anti-patterns.

**Deployment:** Claude Code **skill only**. A Claude.ai GUI Project can't execute a local shell binary over the tailnet, so there is no Project half. Picked up automatically via the `~/.claude/skills/` → `OPS/SKILLS/` symlink — no per-entry symlink needed.

**Depends on:** `~/OPS/.claude-config/bin/grabit` (tracked in OPS, syncs to all machines) + Tailscale running on both ends. Deep mechanics: the `reference-grabit-file-transfer` memory + `.claude-config/bin/README.md`.

**Last updated:** 2026-06-26
