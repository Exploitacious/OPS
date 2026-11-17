# Third-party notices

OPS is released under the MIT License (`LICENSE`, Copyright (c) 2026
Exploitacious). Some of its doctrine adapts work by other people, each under a
license of its own. This file lists every such source, what OPS took from it,
and where the full license text lives. It is a good-faith record, not legal
advice: if you redistribute OPS or reuse this material, read the upstream
licenses yourself.

Nothing else in this repository is vendored from a third party. OPS calls other
tools (git, gh, jq, bubblewrap, the Claude Code CLI, and gitleaks in CI) but
neither ships nor modifies them. The frameworks `CONTEXT/how-i-work.md` names
(Theory of Constraints, the Improvement Kata, the Phoenix Project lens) are
referenced ideas; no text from those works is copied.

## Summary

| Source | Author | License | What OPS took | Where it lives in OPS | Full license text |
|---|---|---|---|---|---|
| [cursor/plugins](https://github.com/cursor/plugins), `pstack/skills/unslop` | Lauren Tan | MIT | Adapted into the AI-tells catalog | `CONTEXT/ai-tells.md` | The same file, "Upstream MIT license" |

On 2026-11-17 the template stopped shipping the skills that adapted the other
works this file used to list (mattpocock/skills, ayghri/i-have-adhd and
anthropics/skills `frontend-design`): the `operating-model` and `design-method`
skills were removed, and `SKILLS/VENDORED.tsv` no longer mounts the
`Exploitacious/agent-skills` set. A source you mount yourself carries its own
notices.

## What the license asks

**MIT.** The license grants use, copying, modification, and distribution, on one
condition quoted from its text: "The above copyright notice and this permission
notice shall be included in all copies or substantial portions of the
Software." It also disclaims all warranty. OPS keeps that notice with the
adapted work, as the summary table shows.

## Details

### cursor/plugins, pstack/skills/unslop

- Upstream: https://github.com/cursor/plugins, under `pstack` (MIT, Copyright
  (c) 2026 Lauren Tan; the license file is `pstack/LICENSE`), adapted at commit
  `fd878692de15`.
- OPS adapted the catalog of AI-writing tells. `CONTEXT/ai-tells.md` states the
  provenance and carries the upstream license in full under "Upstream MIT
  license". Re-review upstream before any version bump, as that file says.
