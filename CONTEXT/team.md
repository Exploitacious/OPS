# team (context slot)

> **This is a template — it has not been filled in yet.** Fill it in during
> `BOOTSTRAP.md`, or the first time a skill needs to know who owns what. Delete
> this banner once the file is real. A blank team slot is a valid state: every
> skill that reads it degrades gracefully (see the degrade below).

The well-known slot a skill reads for the roster: who is on the team, their
roles, and who owns what. A skill that needs to route work, name an approver, or
address a person by role reads this instead of hard-coding names.

Fill in, per person or role:

- **Name / handle** — how they appear in tools and in the operator's speech.
- **Role** — what they own and decide (e.g. approver for X, owner of repo Y).
- **Reach** — how the operator refers to them ("my partner", "the lead"), so a
  loose mention resolves to the right person.

**Degrade when absent:** if no roster is configured, address roles generically
and use no names — "the approver", "whoever owns that repo" — and ask the
operator when a specific person actually matters.
