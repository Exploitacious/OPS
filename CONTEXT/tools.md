# tools (context slot)

> **This is a template — it has not been filled in yet.** Fill it in during
> `BOOTSTRAP.md`, or the first time a skill needs to know which integrations
> exist on this host. Delete this banner once the file is real. A blank tools
> slot is a valid state: every skill that reads it degrades gracefully (see the
> degrade below).

The well-known slot a skill reads to learn which MCP namespaces and external
integrations exist on this host, so it reaches for a tool that is actually wired
rather than one it assumes.

Fill in, per integration:

- **Namespace** — the MCP server prefix as it appears to the AI (e.g.
  `myserver__`), plus the one-line "what it is".
- **What it covers** — the systems behind it (ticketing, RMM, docs, cloud, ...).
- **Any fixed identity** — a resource id, tenant, or default the tools always
  need, if one applies.

**Degrade when absent:** if no tool map is configured, use only the tools the
session actually exposes right now — never assume a namespace exists — and ask
the operator when a task needs an integration that isn't visible.
