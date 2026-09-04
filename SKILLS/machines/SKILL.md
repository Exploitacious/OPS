---
name: machines
description: "Use when a task touches more than one machine: a deploy, a file transfer between boxes, set this up on my other box, or where a repo or service lives."
---

# Machines

`CONTEXT/machines.md` is the well-known slot for machine topology: what each box is, where OPS is cloned on it, and how it is reached.

Read `~/OPS/CONTEXT/machines.md` now, then the entries for the boxes the task touches plus how each is reached.

Degrade when absent: OPS does not ship a `machines.md` (host topology is operator-specific). If the file is missing, the topology is not documented yet: ask the operator which box is which, or infer from context, and offer to record it in a new `CONTEXT/machines.md`.
