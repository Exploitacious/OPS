---
name: design-method
description: "Apply when designing or building any UI, web page, landing page, component, or email template. Design method with an optional brand layer."
---

# Design

Work as the design lead at a studio known for giving each client a visual identity nobody mistakes for anyone else's. The client has already rejected templated proposals. Make deliberate, opinionated choices about palette, type, and layout specific to this brief, and take aesthetic risk when it earns its place.

## Decide the brand context first

Before any design choice, decide whether the work carries the operator's brand:

- A brand-facing site, portal, deliverable (`.docx`/`.pptx`/`.xlsx`), landing page, marketing asset, or an email template that carries the operator's name. This is branded. Read the brand layer (see "Your brand layer" below), then design inside that system.
- Internal tool, throwaway prototype, experiment, or someone else's brand. This is free. Design with the method below and skip the brand layer.

When unsure, ask which one. Do not paint an internal tool in brand colors by reflex, and do not free-design a branded deliverable.

## Ground the design in the subject

If the brief does not say what the product is, name it yourself before designing and confirm: one concrete subject, its audience, its primary job. Distinctive choices come from the subject's industry, materials, and vernacular. A toy for kids aged 8 to 11 and a dashboard for financial analysts share no defaults. Build with the brief's real content throughout, not lorem placeholder.

## The method

Hero: the first thing viewers see. Open with the most characteristic thing in the subject's world, in whatever form fits: a headline, an image, a live demo, an interactive moment. The big-number-plus-small-label-plus-gradient hero is the default, so use it only when it is genuinely the best option.

Typography carries the page's personality. One family, or two if clearly distinct. Choose typefaces deliberately, not the ones you reach for on every project. Set a real type scale with intentional weights and spacing. When type is a headline, make the treatment an active part of the design, not a neutral delivery vehicle. Keep line length under 80 characters; give serif body a touch more line height than sans.

Visual structure is information. Borders, numbering, eyebrows, dividers, and labels should encode something about the content, not decorate. Numbered markers (01 / 02) belong only where the content is a real sequence. Check before adding them.

Motion, sparingly. One orchestrated moment (a single page-load sequence or reveal) beats scattered effects. Fade-and-slide-up on every section plus a hover transition on every card is the generic default and reads as generated. Motion that answers a person's action is welcome; it shows what changed.

Copy is design content, not decoration. Write from the user's perspective, active voice, sentence case, no filler. A CTA says what happens ("Save changes", not "Submit"), and an action keeps its name through the flow. Treat errors and empty states as direction, not mood.

## Avoid the generated-design tells

These clusters appear regardless of subject, so they read as AI defaults. Where the brief pins a direction, follow it exactly. Where an axis is free, do not spend that freedom on:

1. Cream background (near `#F4F1EA`) with a serif display and a terracotta accent (near `#D97757`, a common AI-assistant accent, a double tell).
2. Near-black background with one bright acid-green or vermilion accent.
3. Broadsheet layout: hairline rules, zero radius, dense newspaper columns.
4. The SaaS card kit: identical rounded cards, one radius on everything, the same soft grey shadow under each, gradient washes as filler.
5. Template chrome: a tracked-out all-caps eyebrow over every heading, meta joined with middle dots, "WORD fragment" labels with a spaced dash, tinted near-black standing in for black, mono for small labels, a trailing arrow on link text.

The single-word headline accent and the uppercase eyebrow are on this list too. A brand may ratify some of these on purpose (one serif-italic accent word per heading, uppercase mono eyebrows, card numbers); inside a brand system its ratified choices win and the brand layer overrides this list. Outside a brand, treat them all as defaults to avoid.

## Process: plan, critique, build

Two passes. First a compact token plan: color as 4 to 6 named hex values, the typefaces and their roles, a layout concept in one-sentence prose plus an ASCII wireframe with alignment guidance, and the principles that make this page specific. Then critique the plan against the brief: run a similar prompt in your head and see if you land somewhere similar; if a part reads like the generic default, revise it and say what changed and why. Only then write code.

When coding, watch CSS selector specificity. Type-based (`.section`) and element-based (`.cta`) selectors cancel each other out easily, most often on section padding and margin.

## Restraint

Spend boldness in one place. Let one element be the memorable thing and keep everything around it quiet. Cut decoration that does not serve the brief. Hit the quality floor without announcing it: responsive to mobile, visible keyboard focus, reduced motion respected, accessible contrast. Critique as you build; screenshot and review when the environment supports it. Before leaving, remove one accessory.

## Your brand layer

Branded work reads its tokens, type stack, brand language, and asset rules from a brand file instead of inventing them. This skill ships `brand.md` as a fill-in template. Author it once (the template's own guidance says how), then:

- If `SKILLS/design-method/brand.md` is filled (its unfilled-template banner removed), read it and design inside that system. Never invent a token, hex, or font the brand file does not name; the brand's ratified patterns override the generic-tell list above. Run `checklist.md` before calling the work done.
- If `brand.md` is still the unfilled template (or absent), there is no brand to honor: design free with the method above and say the brand layer is not set.

Method adapted from anthropics/skills frontend-design (Apache-2.0); the brand-layer slot is this template's.
