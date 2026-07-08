---
name: grabit — file courier
description: >
  Send a real file from this (usually headless) OPS box to the operator's own
  machine over Tailscale, landing in their Downloads — via the `grabit` tool, NOT
  in-chat file delivery. Activates when the operator says "send me a file/this",
  "grab this", "get/put this in my downloads", "pull this off the box", "push this
  to my machine", or otherwise wants a real file (build, zip, doc, image, report)
  off the terminal. Also covers receiving files the operator pushed TO the box.
  Claude Code only — runs a shell binary over the tailnet.
---

# grabit — file courier off the headless box

You move real files between this OPS box and the operator's machine over Tailscale, using the `grabit` binary. When the operator asks for a file, you **push it with grabit** — you do not hand it back as an in-chat attachment.

## Why this exists

This box is usually headless: the operator drives it over SSH/tmux and can only pull *text* out of the terminal. `grabit` Taildrops actual files to the machine they're connected from, where they auto-save to **Downloads** (Windows — verified). In-chat file delivery (e.g. `SendUserFile`) is the wrong tool here — it doesn't land a file on the operator's disk where they expect it. Reaching for in-chat delivery on a "send me a file" request is the exact mistake this skill exists to prevent.

## The command

`grabit` is **not** on `$PATH`. Always call it by full path:

```
~/OPS/.claude-config/bin/grabit FILE...
```

Tailnet-encrypted, never public (`tailscale serve`, not `funnel`). It only ever sends the **named files** — never their parent directory — so a neighbouring `.env` can't leak.

## Modes

| Intent | Command |
|---|---|
| Send file(s) to the operator (default) | `grabit FILE...` — pushes to the device they SSH'd in from (auto-detected via `$SSH_CONNECTION`) |
| Send to a specific machine | `grabit --to DEVICE FILE...` (tailnet name or `100.x` IP) |
| Give a browser download link (large / many files) | `grabit --serve PATH...` → prints a tailnet HTTPS URL; `grabit --serve-off` tears it down (needs passwordless sudo) |
| Fetch files the operator pushed TO this box | `grabit --inbox [DIR]` (default `~/grabit-inbox`) |
| List tailnet devices | `grabit --list` |

Default to plain push. Reach for `--serve` only when push won't fit (very large, or the operator explicitly wants a link). `--inbox` is the receive direction — use it when the operator says they've sent/pushed something *to* the box.

## Workflow

1. Resolve each file to a concrete path (relative to cwd is fine; absolute is safest). Confirm it exists before sending.
2. Run `~/OPS/.claude-config/bin/grabit <path> [<path> …]`.
3. Report what was sent and where it lands ("→ your Downloads on `<device>`").
4. If `$SSH_CONNECTION` is unset (rare — a non-SSH/cron session), auto-detect fails. Fall back to `--to <device>`; the current Windows device is recorded in the `reference-grabit-file-transfer` memory.
5. On error, surface the exact message — don't silently retry in a different mode.

## Anti-patterns

- **Never** use in-chat file delivery (`SendUserFile`) when the operator wants a file *on their machine* — push with grabit.
- **Never** pass a directory to push — grabit sends named files only; a folder isn't supported and invites scope creep.
- **Never** assume `grabit` is on `$PATH` — always the full path.
- Don't `--serve` by default — it needs sudo and leaves an endpoint standing; prefer push.
- Don't send a file the operator didn't ask for, and don't push secrets/credentials off-box without an explicit instruction.

## Deep context

Full mechanics + one-time box setup (`sudo tailscale set --operator=$USER`) live in the `reference-grabit-file-transfer` memory and `~/OPS/.claude-config/bin/README.md`. Read those only if a transfer misbehaves or you're provisioning a new box.
