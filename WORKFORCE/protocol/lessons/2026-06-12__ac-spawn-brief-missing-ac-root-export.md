---
date: 2026-06-12
author: Captain
scope: cross-cutting
affects: [fleet-protocol]
---
ac-spawn's auto-generated brief references $AC_ROOT-expanded paths but never
instructs the agent to `export AC_ROOT=...` — agents hit ac-register's
fail-fast. AGENT.md step 0 requires the brief to carry the export line.
Fix: add an explicit "FIRST ACTION: export AC_ROOT=<path> && export
AC_FLEET=<path>" sentence to the heredoc in ac-spawn (~line 132). Worked
around 2026-06-12 with custom --brief files for a multi-agent project wave.
Also: the brief's name-hint sentence should pass --name through to the
ac-register command it quotes (it currently quotes a nameless register call).
