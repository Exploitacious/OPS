# voice (context slot)

The well-known slot a skill reads for the operator's register and brand voice.

In this OPS copy the voice lives in `brand-voice.md` (how the operator writes) and
`about-me.md` (who they are) — read those. This file is the slot pointer so a
portable skill referencing `voice.md` resolves.

**Degrade when absent:** if no voice is configured, use plain professional prose.
