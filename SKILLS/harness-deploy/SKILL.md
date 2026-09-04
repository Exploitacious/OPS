---
name: harness-deploy
description: "Use when changing how Stage 1 (linuxploitacious) or Stage 2 (.claude-config/deploy.sh or .ps1) installs, or deploying the harness to a new machine."
---

# Harness deploy

`DEPLOYMENT.md` is the authoritative two-stage deploy procedure: Stage 1 (linuxploitacious host setup and clone) then Stage 2 (`.claude-config/deploy.sh` or `.ps1` wires the rest). It lives at the repo root, not `CONTEXT/`.

Read `~/OPS/DEPLOYMENT.md` now.

Read the stage the task changes; the procedure is idempotent, and a new step must land in both `deploy.sh` and `deploy.ps1`.
