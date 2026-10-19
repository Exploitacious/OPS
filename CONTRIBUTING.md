# Contributing to OPS

OPS is a generalized commons. The maintainer runs a private harness; most
contributors run one too: a private copy of OPS (or an older sibling of it)
that has accumulated its own optimizations, memory, and identity. The whole
point of this repo is that the *mechanics* flow between those private worlds
while the *identity* never does.

That makes contributing here different from a normal open-source PR in exactly
one way: **you are extracting from a private harness into a public one, and
the extraction discipline is the contribution gate.**

## The one rule: port patterns, never paste files

Your private harness's version of a hook, skill, doctrine section, or script
is entangled with you: your name, org, clients, machine names, paths, project
history, running logs. Do not copy it over and clean it up afterward; that's
how private strings survive into public commits. Instead:

1. Identify the *mechanic*: what the improvement actually does and why it
   works.
2. Rewrite it against the OPS tree's conventions (paths under `~/OPS`,
   `ops-*` unit/agent names, `OPS_DIR`, synthetic `ExampleOrg` examples,
   "the Operator" instead of any real name).
3. Where an example is structurally required, invent one. Obviously synthetic
   beats realistic: realistic examples read as leaks even when they aren't.

## The private-term rule

The list of private terms you scan for (your name, employer, clients,
teammates, hostnames, tailnet names, project codenames, ticket prefixes) is
itself private. Keep it in your own harness, and never publish it: not in a
file, a commit message, a PR title or description, an issue, or a comment. A
PR body that says "I grepped for these 12 terms" followed by the terms
publishes exactly what the scan exists to keep out.

- Scan what you will publish, not only the files: the diff, every commit
  message (`git log -p origin/main..HEAD`), and the PR title and body before you
  submit it.
- Scan the history of the branch too. A term fixed in a later commit is still
  in the earlier one, and a PR keeps its commits on GitHub permanently, so
  squash or rewrite your own branch before you push it.
- If a private term does reach a public PR, commit, or comment, say so to the
  maintainer in the PR right away, without repeating the term. Do not
  force-push over it: GitHub keeps the old commits and the PR's edit history.

## Working with an AI on the port (recommended)

If you're having Claude (or any agent) do the merge, give it this brief
verbatim: it is the same contract this repo was originally extracted under:

> You are porting improvements from a PRIVATE harness into the PUBLIC OPS
> template. Read the private version for structure and intent only; never
> copy personal content across. Build a denylist for the private side's
> identity: real names, employer, clients, teammates, emails, hostnames,
> machine identifiers, tailnet names, IPs, private repo names, project
> codenames, ticket prefixes: and grep every file you touched for it
> (case-insensitive, word-bounded) before calling the work done. Zero hits.
> Replace identity with "the Operator" or clearly synthetic equivalents.
> Keep the doctrine voice: direct, disciplined, no emojis, no hedging, no
> corporate boilerplate. Update docs in the same change (see
> `CONTEXT/project-kata.md`). If a passage can't be scrubbed without losing
> its point, cut it cleanly: no "[redacted]" scars.

## Before you open the PR

CI runs the gate (`.github/workflows/gate.yml`) on every pull request, with no
secrets, so a fork's PR gets the same run. Run the same checks first; each is
a job in that workflow.

**1. Syntax.** CI finds every tracked script by extension or `#!` line; check
what you touched:

```bash
bash -n <each shell script you touched>
python3 -m py_compile <each .py file you touched>   # use PYTHONPYCACHEPREFIX=/tmp/pyc to keep __pycache__ out of the tree
```

For JavaScript, run the gate's own check over every tracked `.js` file:

```bash
python3 -B .claude-config/bin/tests/ci-gate-test.py
```

It runs the `Check every JavaScript script` step from `gate.yml` itself, so
there is no second copy to drift. A workflow script (any `.js` whose first
statement is `export const meta =`, in `.claude-config/workflows/` or bundled
with a skill such as `SKILLS/memory-prune/audit_workflow.js`) uses top-level
`await` and `return`, because the workflow runner runs its body as an async
function, so the step parses that body as one. Plain `node --check <file>` is
wrong for these: Node 18 rejects the valid files, and newer releases can report
no error even for a module with an unclosed brace. Any other `.js` is checked
in explicit CommonJS, then module, mode.

**2. Every suite.** Run from your checkout root. This is the CI command; it
exits non-zero if any suite fails. It needs `bwrap` (`sudo apt install
bubblewrap`; see "Where destructive tests run" below) and, for the last loop,
`pwsh`:

```bash
fails=0
for t in .claude-config/bin/tests/*-test.sh .claude-config/bin/tests/*-test.py; do
  case "$t" in *.py) run=(python3 -B) ;; *) run=(bash) ;; esac
  case "$t" in
    */sandbox-run-test.sh|*/sandbox-run-fd-test.py)   # these start sandbox-run themselves
      "${run[@]}" "$t" || { echo "FAILED: $t"; fails=$((fails + 1)); } ;;
    *)
      .claude-config/bin/sandbox-run --no-bind --no-net --ro-bind "$PWD" -- "${run[@]}" "$t" \
        || { echo "FAILED: $t"; fails=$((fails + 1)); } ;;
  esac
done
for t in .claude-config/bin/*-selftest.* .claude-config/hooks/*-selftest.sh; do
  case "$t" in *.py) run=(python3 -B) ;; *) run=(bash) ;; esac
  .claude-config/bin/sandbox-run --no-bind --no-net --ro-bind "$PWD" -- "${run[@]}" "$t" \
    || { echo "FAILED: $t"; fails=$((fails + 1)); }
done
for t in deploy-windows-test.ps1 memory-init-windows-test.ps1; do
  pwsh -NoProfile -File ".claude-config/bin/tests/$t" || { echo "FAILED: $t"; fails=$((fails + 1)); }
done
echo "failed suites: $fails"
[ "$fails" -eq 0 ]   # last, so the exit status is the result (the echo exits 0)
```

`verify-ops-selftest.sh` also checks the shipped tree against the real Stage-1
settings when `OPS_SELFTEST_STAGE1` names a copy of that file; without it that
one case prints `SKIP`. CI fetches the file and sets the variable; to do the
same, download it (the URL is in `DEPLOYMENT.md`, "Testing a deploy under a
throwaway HOME"), then add `--ro-bind <file>` to that suite's `sandbox-run`
line and set the variable on the command.

**3. A fresh-install smoke test, then the drift gate.** `verify-ops.sh` checks
the machine it runs on (the core link under `~/.claude/rules/`, the Stage-1
settings), so on a machine with no deployed OPS, `OPS_DIR="$PWD"
.claude-config/bin/verify-ops.sh` reports a FAIL for the missing link, which
says nothing about your change. Run it the way CI does, in a throwaway `HOME`:
`DEPLOYMENT.md`, "Testing a deploy under a throwaway HOME" has the commands.
On a machine where OPS is already deployed, `OPS_DIR="$PWD"
.claude-config/bin/verify-ops.sh` checks your checkout directly.

**4. Secrets and private terms.** `.claude-config/bin/secrets-scan.sh CONTEXT
SKILLS .claude-config` is OPS's own detector (it takes a couple of minutes: it
greps line by line), and CI also runs `gitleaks` over the full history. Then
run your own private-term scan at zero hits (see the private-term rule above).

Say in the PR body that you ran them, and expect the maintainer to run an
independent leak pass anyway before merging. Anything that looks
machine-specific or reads too real to be synthetic will get questioned; that
is the review working as intended.

## Where destructive tests run

A test, self-test, mutation check, or probe of a tool that deletes, moves, or
overwrites files runs only inside `.claude-config/bin/sandbox-run`: a
bubblewrap sandbox with a read-only root, a fresh home directory and `/tmp`,
and nothing writable unless you name it. Why: in the private harness OPS is
ported from, an unsandboxed mutation sweep of a cleanup tool ran the real
deleter on `/` and `$HOME` and wiped most of a home directory. A throwaway
`HOME` did not help, because a mutated tool computed its own path.

- A suite for such a tool starts with the guard line from
  `.claude-config/bin/sandbox-lint`'s header and exits 97 outside the
  sandbox. `verify-ops.sh` check 24 fails a suite that names one of the tools
  (`OPS_DESTRUCTIVE_TOOLS` in `verify-ops.sh`) without it. Add the guard to any
  new suite of that kind.
- The sandbox is Linux only (`bwrap`). On macOS or Windows, run those suites on
  a Linux host, or open the PR and let CI run them.
- bubblewrap cannot nest on Ubuntu 23.10 and later, so the two suites that
  start `sandbox-run` themselves (`sandbox-run-test.sh`,
  `sandbox-run-fd-test.py`) run outside it; they write and delete only in their
  own scratch directory.
- A mutation sweep also runs in the sandbox, with a scratch copy as the only
  `--bind`. Details and the exit codes: `.claude-config/bin/README.md`,
  "sandbox-run".

## Mechanics

- `main` is protected: contributions land by PR with review, no direct
  pushes, no force pushes.
- **`GIT_GUARD=off` for your PR branch.** Your clone of this repo is itself an
  OPS copy (it holds `.claude-config/bin/origin-private-check`) whose origin is
  public, so the git-guard hook blocks an agent's push of your PR branch, by
  design: that is the push it exists to stop in a private copy. Check that the
  branch carries no private content (the private-term rule, at zero hits), then
  push it with the documented one-command override, which the hook honors only
  at the very start of a command:
  `GIT_GUARD=off git push origin <branch>`. Use it for that push and nothing
  else, and never set it for the whole session.
- Conventional Commits (`<type>(<scope>): <imperative summary>`, subject
  ≤ 72 chars). Body explains *why* when it isn't obvious.
- One mechanic per PR beats a best-of-both-worlds mega-merge. Big merges
  hide leaks and stall review; a stack of small PRs flows.
- Doc updates ride in the same PR as the change they describe
  (`CONTEXT/project-kata.md`: docs match reality, always).
- Third-party work: if your change adapts someone else's work, say so in the
  PR and add it to `SKILLS/THIRD_PARTY_NOTICES.md` with its license, in the
  same change.
- CI (`.github/workflows/gate.yml`) must be green before a merge. A failing job
  is a defect in the change, or in the gate; do not merge around it. The jobs
  run only on the template repository, so a push to your fork starts nothing:
  the run begins when you open the PR (GitHub may hold a first-time
  contributor's run until a maintainer approves it), which is why the checks
  above come first.
- This is a no-SLA repo (see README § Posture). PRs are welcome; response
  time isn't promised.
