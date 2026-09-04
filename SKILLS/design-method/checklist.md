# Design checklist

Run before calling any design done. Adapt the brand rows out when the work is free-design.

## Method (every design)

- Subject named: one concrete subject, its audience, its primary job, built with real content not placeholder.
- Hero opens with the most characteristic thing, not the default big-number-plus-gradient unless it is genuinely best.
- One or two typefaces, chosen deliberately, with a real scale and intentional weights. Line length under 80.
- Structural devices (borders, numbering, eyebrows) encode content. Numbered markers only where the content is a real sequence.
- Motion is one orchestrated moment, not fade-up on every section plus hover on every card.
- Copy: user's perspective, active voice, sentence case, CTAs name what happens, errors and empty states give direction.
- Ran the generic-tell check: no unchosen cream-and-terracotta, near-black-plus-neon, broadsheet, SaaS-card-kit, or template-chrome defaults.
- Boldness spent in one place; one accessory removed.
- Quality floor: responsive to mobile, visible keyboard focus, reduced motion respected, accessible contrast.
- CSS specificity checked (no `.section` vs `.cta` cancellation on padding/margin).
- Two-pass process done: token plan critiqued against the generic default before code, with the change and its reason noted.

## Branded work only (when brand.md is filled)

- Brand context confirmed branded before painting anything in brand colors.
- Mode chosen per the brand file (e.g. web vs office/document adaptation, if the brand defines both).
- Tokens referenced from the brand file; no invented hex, font, or radius.
- Type stack matches the brand file exactly; no substitute families.
- Ratified brand patterns used correctly (whatever the brand file lists as intentional); not treated as generated-tells here.
- Accents used as the brand file scopes them (surgical vs fills, gradient allowed vs skipped).
- Brand name and logo used as the brand file specifies (public name, legal name only where required, logo unedited).
- No em dashes anywhere in operator-voice output, if the brand's voice bans them. No emoji unless the brand allows them.
- Web pages built from the brand's live/canonical patterns where it names them, not freehand; screenshot-verified at the brand's target widths.
- HTML email: any brand-specific email traps in the brand file honored (header/logo conditionals, CTA padding, no payload in conditional comments), verified on a real client screenshot.
