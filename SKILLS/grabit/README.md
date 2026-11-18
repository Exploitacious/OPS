# grabit (skill)

**Purpose:** Move real files between a (usually headless) OPS box and the operator's machine over Tailscale, via the `grabit` binary, not in-chat delivery. Corrects the default reflex to hand files back as chat attachments.

**One skill, one binary:** `grabit/SKILL.md` covers the SEND direction (push a named file to the operator's Downloads: `grabit FILE...` / `--to` / `--serve` / `--list`) and the RECEIVE direction (`grabit --inbox` pulls what the operator pushed to the box, screenshots included). The separate `grabit-screenshots` skill was retired on 2026-11-17.

**Deployment:** Claude Code **skills only**. A Claude.ai GUI Project can't execute a local shell binary over the tailnet, so there is no Project half. Picked up automatically via the `~/.claude/skills/` to `OPS/SKILLS/` symlink; no per-entry symlink needed.

**Depends on:** `~/OPS/.claude-config/bin/grabit` (tracked in OPS, syncs to all machines) plus Tailscale running on both ends. Deep mechanics: `.claude-config/bin/README.md` under grabit.
