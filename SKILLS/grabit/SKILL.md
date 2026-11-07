---
name: grabit
description: "Use when the operator wants a real file off this headless box onto their own machine: send me this, grab this, put it in my downloads. Pushes it over Tailscale to their Downloads with the grabit binary, not in-chat delivery. Not for an image attached in a T3 message (a saved path: read it)."
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

The receive direction is the next section. Most "look at this image" requests are not receives at all.

## Receiving: an image in a T3 message is already a path

An image attached in a T3 message arrives in the prompt as a saved path (`[User attached one or more files ...]`): read it directly with the Read tool and say what you see. Do not run grabit for it. A receive skill whose description matches ordinary talk about pasted or attached images fires on requests that need no pull at all.

Pull with `~/OPS/.claude-config/bin/grabit --inbox` only when the operator says they pushed (Taildropped) something to this box. It pulls everything waiting into `~/grabit-inbox` and lists what landed; the `grabit-screenshots` skill carries the full receive procedure (read each pending image newest first, say what you actually see before interpreting it, never ask for a path or suggest base64-pasting an image). An empty inbox means nothing arrived: say so rather than guessing.

## Workflow

1. Resolve each file to a concrete path and confirm it exists before sending. Absolute is safest.
2. Run `~/OPS/.claude-config/bin/grabit <path> [<path> ...]`.
3. Report what was sent and where it lands, for example "to your Downloads on `<device>`".
4. If `$SSH_CONNECTION` is unset, a rare non-SSH or cron session, auto-detect fails. Fall back to `--to <device>`; list the tailnet devices with `grabit --list`, and the device list and transfer modes are in `~/OPS/.claude-config/bin/README.md` under grabit.
5. On error, surface the exact message. Do not silently retry in a different mode.

## Anti-patterns

1. Do not use in-chat delivery like `SendUserFile` when the operator wants a file on their machine. Push with grabit.
2. Do not pass a directory. grabit sends named files only.
3. Do not assume grabit is on `$PATH`. Always the full path.
4. Do not `--serve` by default. It needs sudo and leaves an endpoint standing; prefer push.
5. Do not send a file the operator did not ask for, and do not push secrets or credentials off-box without an explicit instruction.

## Deep context

Full mechanics and one-time box setup (`sudo tailscale set --operator=$USER`, which lets push run sudo-free) live in `~/OPS/.claude-config/bin/README.md` under grabit. Read that only if a transfer misbehaves or you are provisioning a new box.

## Other agent runtimes

`grabit` is a plain shell binary, so a Codex or OpenCode thread on the same box sends a file exactly the same way, `~/OPS/.claude-config/bin/grabit <path>`, with the same constraint: local agent sessions only, over the tailnet. The `$SSH_CONNECTION` auto-detect and the `--to <device>` fallback behave identically on every runtime.
