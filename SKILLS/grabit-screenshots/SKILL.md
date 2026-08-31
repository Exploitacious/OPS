---
name: grabit-screenshots
description: "Use when the operator says they pushed something to this box for you to look at: look at my screenshot, check the image I sent, I just sent you a diagram or picture, or pull the file I pushed. Pull it with grabit --inbox and read it yourself, never ask for a path. Local agent sessions only; the file arrives by Taildrop over the tailnet."
---

# grabit-screenshots: receive and read files pushed to the box

Pull files the operator pushed to this OPS box over Tailscale and, when they are images, read them so you see what they captured. The `grabit` binary at `~/OPS/.claude-config/bin/grabit` does the pull. It is not on `$PATH`, so always call it by full path.

## What happened when they say "look at my screenshot"

The operator captured on their own machine and chose the destination that Taildrops the capture here. They did not put it in a shared folder and there is no path for you to ask about. You see images natively once the file is on this box, which is the whole point of the pipeline.

## Pull and read

1. `~/OPS/.claude-config/bin/grabit --inbox`. This pulls everything waiting into `~/grabit-inbox`, then lists what landed.
2. Read each pending image with the Read tool, newest first.
3. Say what you actually see before interpreting it, so a wrong or stale image is caught immediately instead of reasoned over.

A non-image file the operator pushed arrives the same way; open it with the right tool once `--inbox` has pulled it. `--inbox` takes an optional directory argument (default `~/grabit-inbox`).

## Gotchas that matter

1. Taildrop has no list verb (`tailscale file` is `cp` or `get` only), so the queue cannot be inspected without pulling. Pulling is non-destructive: files just move into `~/grabit-inbox`.
2. Multiple captures batch. Each send queues on its own; one `--inbox` pulls them all. On "look at my screenshots", plural, read every pending one.
3. Nothing arrives automatically. Sending is a destination the operator picks per capture, so an empty inbox means they have not sent it yet. Say so rather than guessing what they meant.
4. Do not suggest base64-pasting an image into the terminal. It costs 30 to 300 times the tokens of a native image read, and text in context cannot be viewed as an image anyway. It would have to be decoded back to a file and read, the same destination by a far more expensive route.

## Deep context

The receive pipeline is a screenshot tool on the operator's machine configured to Taildrop the capture here; that machine-side setup lives with the operator's own tooling. Full transfer mechanics are in the `reference-grabit-file-transfer` memory and `~/OPS/.claude-config/bin/README.md`. To send a file the other direction, off this box to the operator's machine, use the `grabit` skill.
