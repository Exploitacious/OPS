# Contributing to OPS

OPS is a generalized commons. The maintainer runs a private harness; most
contributors run one too — a private copy of OPS (or an older sibling of it)
that has accumulated its own optimizations, memory, and identity. The whole
point of this repo is that the *mechanics* flow between those private worlds
while the *identity* never does.

That makes contributing here different from a normal open-source PR in exactly
one way: **you are extracting from a private harness into a public one, and
the extraction discipline is the contribution gate.**

## The one rule: port patterns, never paste files

Your private harness's version of a hook, skill, doctrine section, or script
is entangled with you — your name, org, clients, machine names, paths, project
history, running logs. Do not copy it over and clean it up afterward; that's
how private strings survive into public commits. Instead:

1. Identify the *mechanic* — what the improvement actually does and why it
   works.
2. Rewrite it against the OPS tree's conventions (paths under `~/OPS`,
   `ops-*` unit/agent names, `OPS_DIR`, synthetic `ExampleOrg` examples,
   "the Operator" instead of any real name).
3. Where an example is structurally required, invent one. Obviously synthetic
   beats realistic — realistic examples read as leaks even when they aren't.

## Working with an AI on the port (recommended)

If you're having Claude (or any agent) do the merge, give it this brief
verbatim — it is the same contract this repo was originally extracted under:

> You are porting improvements from a PRIVATE harness into the PUBLIC OPS
> template. Read the private version for structure and intent only; never
> copy personal content across. Build a denylist for the private side's
> identity — real names, employer, clients, teammates, emails, hostnames,
> machine identifiers, tailnet names, IPs, private repo names, project
> codenames, ticket prefixes — and grep every file you touched for it
> (case-insensitive, word-bounded) before calling the work done. Zero hits.
> Replace identity with "the Operator" or clearly synthetic equivalents.
> Keep the doctrine voice: direct, disciplined, no emojis, no hedging, no
> corporate boilerplate. Update docs in the same change (see
> `CONTEXT/project-kata.md`). If a passage can't be scrubbed without losing
> its point, cut it cleanly — no "[redacted]" scars.

## Before you open the PR

Run the repo's own gates from your branch root:

```bash
.claude-config/bin/secrets-scan.sh CONTEXT WORKFORCE SKILLS .claude-config
.claude-config/bin/verify-ops.sh        # expects the repo at ~/OPS
bash -n <every shell script you touched>
node --check <every js file you touched>
```

All clean, plus your own denylist grep at zero hits. Say in the PR body that
you ran them — and expect the maintainer to run an independent leak pass
anyway before merging. Anything that looks machine-specific or reads too real
to be synthetic will get questioned; that's the review working as intended.

## Mechanics

- `main` is protected: contributions land by PR with review, no direct
  pushes, no force pushes.
- Conventional Commits (`<type>(<scope>): <imperative summary>`, subject
  ≤ 72 chars). Body explains *why* when it isn't obvious.
- One mechanic per PR beats a best-of-both-worlds mega-merge. Big merges
  hide leaks and stall review; a stack of small PRs flows.
- Doc updates ride in the same PR as the change they describe
  (`CONTEXT/project-kata.md` — docs match reality, always).
- This is a no-SLA repo (see README § Posture). PRs are welcome; response
  time isn't promised.
