---
name: grabit
description: "Use when the operator wants a real file off this headless box and onto their own machine: they say send me this, grab this, put it in my downloads, pull this off the box, or push this to my machine. Pushes the named file over Tailscale to their Downloads via the grabit binary, not in-chat file delivery. Local agent sessions only; runs a shell binary over the tailnet."
---

# grabit: send a file off the headless box

Move a real file from this OPS box to the operator's machine with the `grabit` binary. When the operator asks for a file, push it with grabit. Do not hand it back as an in-chat attachment.

## Why this exists

This box is usually headless: the operator drives it over SSH and can pull only text out of the terminal. grabit Taildrops actual files to the machine they connected from, where Windows auto-saves them to Downloads (verified, no tray prompt). In-chat delivery like `SendUserFile` does not land a file on the operator's disk where they expect it, so reaching for it on a "send me a file" request is the exact mistake this skill prevents.

## The command

grabit is not on `$PATH`. Always call it by full path:

```
~/OPS/.claude-config/bin/grabit FILE...
```

Every transfer rides the tailnet (WireGuard-encrypted) and is never public: the browser mode uses `tailscale serve`, not funnel. grabit sends only the files you name, never their parent directory, so a neighbouring `.env` cannot leak.

## Modes

| Intent | Command |
|---|---|
| Send file(s) to the operator (default) | `grabit FILE...` pushes to the device they connected from, auto-detected via `$SSH_CONNECTION` |
| Send to a specific machine | `grabit --to DEVICE FILE...` with a tailnet name or `100.x` IP |
| Give a browser download link for large or many files | `grabit --serve PATH...` prints a tailnet HTTPS URL; `grabit --serve-off` tears it down (needs passwordless sudo) |
| List tailnet devices | `grabit --list` |

Default to plain push: one-shot, no sudo, lands in the operator's inbox. Reach for `--serve` only when push will not fit, or the operator explicitly wants a link, since it needs sudo and leaves an endpoint standing.

To receive files the operator pushed to this box, screenshots included, use the `grabit-screenshots` skill instead. This skill is the send direction only.

## Workflow

1. Resolve each file to a concrete path and confirm it exists before sending. Absolute is safest.
2. Run `~/OPS/.claude-config/bin/grabit <path> [<path> ...]`.
3. Report what was sent and where it lands, for example "to your Downloads on `<device>`".
4. If `$SSH_CONNECTION` is unset, a rare non-SSH or cron session, auto-detect fails. Fall back to `--to <device>`; the current device is recorded in the `reference-grabit-file-transfer` memory.
5. On error, surface the exact message. Do not silently retry in a different mode.

## Anti-patterns

1. Do not use in-chat delivery like `SendUserFile` when the operator wants a file on their machine. Push with grabit.
2. Do not pass a directory. grabit sends named files only.
3. Do not assume grabit is on `$PATH`. Always the full path.
4. Do not `--serve` by default. It needs sudo and leaves an endpoint standing; prefer push.
5. Do not send a file the operator did not ask for, and do not push secrets or credentials off-box without an explicit instruction.

## Deep context

Full mechanics and one-time box setup (`sudo tailscale set --operator=$USER`, which lets push run sudo-free) live in the `reference-grabit-file-transfer` memory and `~/OPS/.claude-config/bin/README.md`. Read those only if a transfer misbehaves or you are provisioning a new box.
