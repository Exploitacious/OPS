---
id: 2026-06-12__private-basetemp-rule
date: 2026-06-12
author: Captain
contributors: [Bravo, Charlie]
status: settled
scope: cross-cutting
affects: [fleet-protocol]
related_tasks: []
related_repos: []
tags: [testing, fleet, tmpfs]
---
# Private basetemp + disk TMPDIR for all fleet gate runs

Two interacting /tmp hazards confirmed tonight on this host:
1. /tmp is a 3.9G tmpfs; concurrent full-suite pytest runs (~1.7G each) +
   npm stores fill it; ENOSPC poisons gates with PHANTOM failures
   (Charlie's verify-docs run, Captain's first audit pass).
2. pytest's shared /tmp/pytest-of-master numbering + keep-3 auto-prune
   DELETES sibling LIVE runs' dirs when ≥2 suites run concurrently
   (Bravo's isolated-rerun proof: same modules 38/38 green isolated).

RULE (all fleet members, all gate runs on shared hosts):
  export TMPDIR=$HOME/fleet-work/<name>/tmp
  python3 -m pytest tests/ --basetemp=$HOME/fleet-work/<name>/basetemp -q
  rm -rf the basetemp after green.
Phantom-failure tell: F-clusters in tmp_path-using modules + multi-minute
wedges in suites that pass isolated. Re-run isolated before believing any
red gate on a shared host.
