# Voice

<!--
The well-known voice slot (CONTEXT/slots.md): portable skills read this file
by name for the Operator's register and brand. If it is still the template,
or absent, a skill uses plain professional prose instead.

harness-update never syncs this file in either direction
(harness-update-scan.sh is_excluded): it is the Operator's voice, never the
public template's. BOOTSTRAP.md writes a starter in Stage 1 and replaces it
with an evidence-based profile in Stage 2.
-->

> **This is a template; it has not been filled in yet.** Every block marked
> **EXAMPLE** is synthetic: an invented operator with an invented voice,
> written to show the depth each section needs. It is not a voice to
> imitate. Until `BOOTSTRAP.md` captures the Operator's real voice, an AI
> must not fake one: say the profile is unfilled and offer Stage 2 before
> drafting anything the Operator will send. Delete this banner once the file
> is real.

How the Operator writes, loaded through `operator-voice`. Who they are lives
in `USER.md`; the shared writing rules live in [core.md](core.md#writing).
This file supplies their registers, vocabulary, examples, and brand kit.

## Tone

<!-- A few honest bullets: casual to formal, humor, confidence, how
frustration reads. The fast calibration before the detail below. -->

**EXAMPLE, replace on bootstrap:**

- Dry and understated in conversation; enthusiasm shows as detail, not
  exclamation points.
- Formal and exact in documents; prefers numbered steps to narrative.
- Humor is rare and deadpan.
- States uncertainty as a number or a condition ("likely, unless the
  carrier changed the format").

## Three registers, mirror whichever the Operator is in

<!-- Name each register, where it is used, and a one-line synthetic or
verbatim sample, then the rule: mirror whichever one the Operator is in. The
most load-bearing section. -->

**EXAMPLE, replace on bootstrap:**

- **Chat:** lowercase, short, no greeting. "rate table loaded. two lanes
  still off by a cent, checking rounding"
- **Email:** "Hi <Name>," and "Thanks," with the request in the first line
  and the context after it. "Hi Priya, could you send the March EDI rejects?
  We think the new mapping fixed them and want to confirm."
- **Deliverable:** numbered sections, defined terms, every claim tied to a
  source. "Section 3 lists the controls in scope; each maps to the evidence
  file named beside it."

Mirror the register the Operator is in: terse in chat, courteous and direct
in email, formal in documents.

## Words and phrases they use

<!-- Their recurring vocabulary and shorthand, collected from real writing
during bootstrap, never guessed. -->

**EXAMPLE, replace on bootstrap:**

- "Net effect" for the bottom line of a change.
- "Boring is a feature" when choosing the simpler tool.
- "Source of record" for the system that owns a fact.
- Ticket titles start with the system name: "TMS: ...", "Network: ...".

## Words and phrases to avoid

<!-- Exact strings to filter out of drafts, so the filter is mechanical. -->

**EXAMPLE, replace on bootstrap:**

- Sycophantic openers ("Great question", "Absolutely").
- Filler ("I'd be happy to", "It's worth noting that").
- Unanchored superlatives ("world-class", "seamless").
- Exclamation points in anything sent outside the team.

## Formatting

<!-- How output should look by context: file formats per audience, prose vs
bullets, hard rules. -->

**EXAMPLE, replace on bootstrap:**

- Documents for customers as `.docx`; internal notes as Markdown.
- Chat in short prose; bullets only for lists of three or more items.
- Tables for comparisons; code blocks for anything technical.
- No bold except defined terms on first use.

## Client deliverable brand kit (.docx, .pptx, .xlsx)

<!-- The concrete spec an office document should hit: logo file and
placement, exact colors, fonts, default section order, contact block. If a
brand kit exists elsewhere, keep it the source of truth and record only the
essentials and a pointer. If none exists, say so explicitly so an AI asks
instead of inventing one. -->

**EXAMPLE, replace on bootstrap:**

- **Company name:** "Example Freight Co." in customer text; the legal name
  only where a contract requires it.
- **Logo:** `path/to/logo.png`, top of the title page.
- **Colors:** headings `#2f4858`, accent `#f26419` for one callout per page
  at most, body near-black on white.
- **Typography:** one sans-serif family for headings and body; monospace for
  data only.
- **Section order:** title page, summary, findings, recommendations, contact
  block.
- **Contact block:** phone, email, website.

## Email patterns

<!-- Observed from a batch of real sent mail during bootstrap: greetings,
sign-offs, follow-ups, apologies, feedback, scheduling, handing the ball
back. One example each. Extract; never invent. -->

**EXAMPLE, replace on bootstrap:**

- **Greeting and sign-off:** "Hi <Name>," and "Thanks,"; never "Dear".
- **Follow-up:** one line restating the ask and a date. "Checking on the
  rejects file; we need it by Thursday to close the month."
- **Scheduling:** two concrete windows and a preference. "Tuesday 10 to 12
  or Wednesday after 2 both work; Tuesday is better."
- **Next step:** ends with who does what. "I will send the mapping change;
  could you confirm the test file once it lands?"

## Chat patterns

<!-- Observed from real internal chat: message length, how status and
deadlines get raised, delegation style. -->

**EXAMPLE, replace on bootstrap:**

- **Length:** one line, often a fragment.
- **Status:** the fact first, then the next action. "export failed at 02:10,
  rerunning with the old schema"
- **Delegation:** a name, the task, the deadline. "@sam can you take the
  label printer ticket today"

## Writing samples

<!-- A handful of labeled samples, at least one per register. In a filled
file these are verbatim excerpts of the Operator's own writing, captured in
Stage 2; they are the calibration anchors. -->

**EXAMPLE, replace on bootstrap** (synthetic, written for this template):

**Chat:**

"carrier api is returning 429s again. backing off to one call a second,
should clear the queue by noon"

**Email:**

"Hi Marcus, thanks for the quote. Two questions before we sign: does the
price include the second site, and what is the notice period to cancel?
Happy to talk Thursday if that is easier."

**Deliverable:**

"The current rating process depends on a spreadsheet that four people edit.
Section 2 measures the error rate it produces; Section 3 proposes a single
rate table with an audit log, and the cost of moving to it."

## Changelog

<!-- Append a row whenever the voice profile is tuned, so later sessions
know it moved on purpose, not by drift. -->

| Date | Change | Reason |
|---|---|---|
| YYYY-MM-DD | EXAMPLE: initial profile captured through BOOTSTRAP | First-run voice extraction from real messages |
