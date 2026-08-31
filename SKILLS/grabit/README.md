# grabit (skill)

**Purpose:** Move real files between a (usually headless) OPS box and the operator's machine over Tailscale, via the `grabit` binary, not in-chat delivery. Corrects the default reflex to hand files back as chat attachments.

**Two skills, one binary:**
- `grabit/SKILL.md` — the SEND direction: push a named file to the operator's Downloads (`grabit FILE...` / `--to` / `--serve` / `--list`).
- `grabit-screenshots/SKILL.md` — the RECEIVE direction: pull files the operator pushed to the box, screenshots included (`grabit --inbox`), and read images natively.

**Deployment:** Claude Code **skills only**. A Claude.ai GUI Project can't execute a local shell binary over the tailnet, so there is no Project half. Picked up automatically via the `~/.claude/skills/` → `OPS/SKILLS/` symlink — no per-entry symlink needed.

**Depends on:** `~/OPS/.claude-config/bin/grabit` (tracked in OPS, syncs to all machines) + Tailscale running on both ends. Deep mechanics: the `reference-grabit-file-transfer` memory + `.claude-config/bin/README.md`.
