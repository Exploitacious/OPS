# Name Pool

Agents and Coordinators pick a name from this list at activation.
Names are claimed by writing to `runtime/manifest.d/<name>.json`.

Before claiming, scan `runtime/manifest.d/` for collisions. If a
name's manifest entry has `last_seen` older than 30 minutes, it's
stale and may be reclaimed — but only with a decision record
explaining the reclaim.

**Naming convention (per fleet-doctrine F3 — architectural choices):**

- **Coordinator = leadership title** (Captain, Marshal, Commander, …)
- **Agent = NATO phonetic + scope tag in brackets** (`Bravo[infra]`)

Visual distinction is intentional: leadership titles read as
nouns/roles, agents as phonetic codes. At-a-glance log scanning
must never confuse Coordinator with Agent.

(Supersedes the prior Greek-letter Coordinator convention as of
2026-05-12; see `protocol/lessons/2026-05-12__alignment-hardening.md`.)

---

## Coordinators — leadership titles

Coordinators use these. No scope tag (Coordinator is the scope).
There is at most one active Coordinator per project at any time.

Order of preference (pick first unclaimed):

1. Captain
2. Marshal
3. Commander
4. Chief
5. Director
6. Foreman
7. Helm
8. Skipper
9. Steward
10. Sentinel

### Reserved (do not claim)

- **Admiral** — reserved. Implies fleet-wide command above the
  Operator; wrong vibe. The Operator is final authority.
- **General** — reserved. Same reason.
- **Boss** — reserved. Wrong tone for the peer-mindset doctrine.
- **Master** — reserved. Loaded connotation; also collides with
  common usernames and the git default-branch name.
- **Lead, Lieutenant** — reserved. Reads as middle-management;
  Coordinator is single-tier.

---

## Agents — NATO phonetic

Agents use these. Scope tag in brackets goes after the name when
known (e.g., `Bravo[infra]`).

Order of preference (pick first unclaimed):

1. Bravo
2. Charlie
3. Delta
4. Echo
5. Foxtrot
6. Golf
7. Hotel
8. India
9. Juliet
10. Kilo
11. Lima
12. Mike
13. November
14. Oscar
15. Papa
16. Quebec
17. Romeo
18. Tango
19. Uniform
20. Victor
21. Whiskey
22. X-ray
23. Yankee
24. Zulu

### Reserved (do not claim)

- **Alpha** — reserved. Avoids confusion with "default" or "primary."
- **Sierra** — reserved. Historical reservation (avoided
  confusion with the old Greek Coordinator pool); kept reserved for
  consistency.

If the pool is exhausted, contact the Operator. The pool is
intentionally bounded.

---

## Scope tags (for agents)

Suggested scope tags. Tags are not exclusive — multiple agents can
share a scope tag if their work areas don't overlap. These are
examples; define tags that fit your own portfolio (see
`PROJECTS/projects-map.md`), and invent a new one with a decision
record when the work doesn't fit an existing tag.

| Tag | Means | Typical repos |
|---|---|---|
| `infra` | Provisioning + IaC + DNS + tunnels | infra repo (e.g. `ExampleOrg/sample-infra`) |
| `backend` | API / server code | `ExampleOrg/sample-app` (server) |
| `frontend` | Web UI / SPA | `ExampleOrg/sample-app` (client) |
| `data` | DB schema + sync workers + pipelines | `ExampleOrg/sample-data` |
| `mcp` | MCP servers + gateway | `ExampleOrg/sample-mcp` |
| `docs` | Handbook + docs | any repo's `docs/` |
| `personal` | Non-org personal projects | personal cluster repos |

If the Operator-given task doesn't fit any of these, leave the
tag off until clarified, or invent one and write a decision
record documenting the new tag.

---

## Examples

- `Captain` — Coordinator (this project).
- `Marshal` — alternate Coordinator title (if Captain claimed).
- `Bravo[infra]` — Bravo, provisioning + IaC work.
- `Charlie[backend]` — Charlie, API server work.
- `Delta[mcp]` — Delta, MCP server work.
- `Echo` — Echo, scope not yet assigned.

---

## Anti-patterns

- Do not use real human names (a teammate's first name, a client
  contact) — those are people, not agents.
- Do not use repo names as agent names ("app-agent") — use the
  scope tag, not the name.
- Do not invent names outside the pool. The pool is the source
  of truth; growth requires Operator approval and a name-pool.md
  update via a decision record.
- Do not mix Coordinator + Agent pools. A Coordinator never
  picks "Bravo"; an Agent never picks "Captain". Visual
  distinction protects log scannability.
