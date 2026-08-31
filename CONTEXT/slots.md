# Context slots

Slots are how one portable skill in a shared source serves every operator without a fork. A skill that hard-codes "log time on the Autotask ticket" or "match this brand voice" cannot ship to another user without editing. A slot keeps that local specific out of the skill: the skill references a well-known slot filename and degrades gracefully when the slot is absent, so the same file runs unmodified for a user who has the slot and a user who does not.

Rules a skill follows when it reads a slot:

- Reference the slot by its well-known name, not an absolute machine path.
- Always state the degrade: what to do when the slot is missing. A skill that breaks without its slot is not portable.
- Never inline the slot's content into the skill. Inlining is the fork you are avoiding.
- Phrase it as a positive with a fallback, not a prohibition: "If `voice.md` exists, match its register; otherwise use plain professional prose."

## The registry

Slots live here, in the distribution's `CONTEXT/`, never in a skill repo. Each row names the well-known filename, what it holds, its degrade when absent, and — since this is a live distribution — which file actually fills it in this OPS copy.

| Slot | Holds | Degrade when absent | Filled in this copy by |
|---|---|---|---|
| `voice.md` | operator register and brand voice | plain professional prose | `brand-voice.md` + `about-me.md` (see `voice.md`) |
| `work-tracking.md` | ticketing and billing bindings: which system, which fields | skip the tracking step and say it was skipped | `work-tracking.md` (proven slot; `session-close` reads it) |
| `team.md` | roster, roles, who owns what | address roles generically, no names | `team.md` (stub until filled) |
| `tools.md` | which MCP namespaces exist on this host | use only tools the session actually exposes | `tools.md` (stub until filled) |
| `doctrine.md` | the engineering-principle registry (the P/F numbers skills cite by name) | name the exact required behavior instead of a principle number | `operating-doctrine.md` (P1-P15) + `fleet-doctrine.md` (F-rules), via `doctrine.md` |

`work-tracking.md` is the proven pattern: `session-close` reads its ticketing binding from context rather than hard-coding a system, which is what lets the same close ritual run for a user on any tracker. On a fresh copy, `BOOTSTRAP.md` (or the first close) fills the empty slots; a slot left blank is a valid state, because every consuming skill states its degrade.

## Adding a slot

A new slot earns its place when more than one skill needs the same class of local specific. Add the row here, give it a degrade, and put the file in `CONTEXT/`, not in the skill. One skill needing one specific is a candidate for a private companion skill instead, not a new slot.
