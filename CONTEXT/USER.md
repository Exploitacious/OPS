# USER: the Operator and the people around them

<!--
USER-TEMPLATE: unfilled. This line is the verify-ops.sh identity canary
(check 21): on a bootstrapped copy it must be gone. Remove it once every
EXAMPLE block below holds your own facts.

harness-update never syncs this file in either direction
(harness-update-scan.sh is_excluded): it is your identity, never the public
template's. BOOTSTRAP.md writes it on first launch.
-->

> **This is a template; it has not been filled in yet.** Every block marked
> **EXAMPLE** is synthetic (an invented "Example Freight Co." operator). The
> examples show the shape and depth each section needs; they are not
> defaults to inherit and not the Operator's real answers. Until
> `BOOTSTRAP.md` replaces them, an AI reading this file does not yet know the
> Operator, and should say so before producing anything voice- or
> judgment-sensitive. Delete this banner once the file is real.

Who the Operator is and who matters around them. The team roster is the
`team.md` slot; voice is `voice.md`; the rules that bind every session are in
`core.md`, situational ones in `how-i-work.md`, and the Operator's rulings in
`standing-orders.md`. Write only what the Operator gave you: an honest short
file beats a padded one.

## The Operator

<!-- One paragraph: who they are, the role in their own words, the
organization and its domain, and what makes the job unusual. An AI uses this
to place every later request in context. -->

**EXAMPLE, replace on bootstrap:** The Operator is the infrastructure lead at
Example Freight Co., a regional freight broker with about forty staff and two
warehouses. Most weeks the job is half platform engineering (the dispatch
system, its integrations, the network) and half translating carrier and
customer requirements into tooling. Prefers small, boring, well-tested
systems over clever ones, and buys before building unless control of the data
is the point.

### What they do day to day

<!-- Three to six bold-labeled buckets of recurring work, each with a short
description and any decision heuristic behind it. -->

**EXAMPLE, replace on bootstrap:**

- **Dispatch platform:** keeps the load-tracking service and its carrier
  integrations running; owns its deploys and on-call.
- **Data plumbing:** nightly exports to the finance team, EDI feeds from two
  large shippers, and the reconciliation reports built on them.
- **Security and access:** identity, device management, and the yearly
  audit evidence the insurance carrier asks for.
- **Vendor management:** evaluates and negotiates the SaaS tools the company
  runs on.

### Current priorities

<!-- A ranked list, most load-bearing first, each with a one-line why now.
The section that goes stale fastest; treat it as living. -->

**EXAMPLE, replace on bootstrap:**

1. **Retire the legacy rating spreadsheet:** pricing errors cost real margin
   every week.
2. **Second warehouse network cutover:** the old firewall is out of support
   at year end.
3. **Audit evidence automation:** last year's collection took three weeks by
   hand.

### Technical stack

<!-- A plain inventory of the systems, languages, and infrastructure they
actually work in, so an AI reaches for the tool they already own. BOOTSTRAP
pre-fills it from recon and confirms it with the Operator. -->

**EXAMPLE, replace on bootstrap:** A transportation management system with a
REST API, a helpdesk tool, a cloud identity provider with device management,
and a managed Postgres database. Python for services and scripts, Bash on the
servers, a small Kubernetes cluster for internal tools, and MCP servers that
expose the TMS and the helpdesk to AI tooling.

### Work they are proud of

<!-- Optional. Two or three short stories that show what they consider good
work: what it replaced and why it mattered. Calibration for judgment and
voice. -->

**EXAMPLE, replace on bootstrap:** Replaced a nightly batch of hand-edited
CSV uploads with an event-driven sync that posts carrier status changes
within a minute, cutting customer "where is my load" calls by a third.

## Identities, deliberately separate

<!-- Work and personal accounts (email, git identity, cloud accounts) that
must stay apart, and why. An AI uses this to pick the right identity for a
commit, an email, or a sign-in. -->

**EXAMPLE, replace on bootstrap:** A work identity (company email and the
company GitHub organization) and a personal one (own domain, personal GitHub)
that never mix: work repos commit with the work identity, side projects with
the personal one.

## Leadership and decision authority

<!-- Who gates which decisions, the meeting cadence, and where the Operator
may decide alone. The full roster with roles lives in team.md. -->

**EXAMPLE, replace on bootstrap:** Reports to the COO; they meet weekly for
thirty minutes, which is the only reliable slot for decisions above the
Operator's spending limit. Can approve any tool under the monthly limit and
any change inside the platform without waiting.

## Vendors and partners, not interchangeable

<!-- Outside vendors whose roles must not be confused: one line each with
what they own and how the Operator refers to them. -->

**EXAMPLE, replace on bootstrap:**

- **The TMS vendor:** owns the core system and its API limits; support
  tickets go through their portal, never email.
- **The network contractor:** owns the warehouse switching and firewalls;
  changes need a ticket two business days ahead.

## Clients and stakeholders

<!-- The accounts or internal customers that recur in the work, largest or
most complex first. Names are identity: keep this file private. -->

**EXAMPLE, replace on bootstrap:** Two large shippers drive most EDI work and
most escalations; internally, the finance team is the most frequent requester
of reports and data fixes.
