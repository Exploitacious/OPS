# Third-party notices

OPS is released under the MIT License (`LICENSE`, Copyright (c) 2026
Exploitacious). Some skills adapt work by other people, each under a license of
its own. This file lists every such source, what OPS took from it, and where the
full license text lives. It is a good-faith record, not legal advice: if you
redistribute OPS or reuse these skills, read the upstream licenses yourself.

Nothing else in this repository is vendored from a third party. OPS calls other
tools (git, gh, jq, bubblewrap, the Claude Code CLI, and gitleaks in CI) but
neither ships nor modifies them. The frameworks `CONTEXT/how-i-work.md` names
(Theory of Constraints, the Improvement Kata, the Phoenix Project lens) are
referenced ideas; no text from those works is copied.

## Summary

| Source | Author | License | What OPS took | Where it lives in OPS | Full license text |
|---|---|---|---|---|---|
| [mattpocock/skills](https://github.com/mattpocock/skills), `grilling` | Matt Pocock | MIT | Adapted into the `grill-me` skill | `SKILLS/grill-me/` (mounted) | `LICENSE.upstream` in that folder; Appendix A |
| mattpocock/skills, `tdd` and `diagnosing-bugs` | Matt Pocock | MIT | Vendored; maintained in `agent-skills` | `SKILLS/tdd/`, `SKILLS/diagnosing-bugs/` (mounted) | `LICENSE.upstream` in each folder; Appendix A |
| mattpocock/skills, `writing-for-agents` | Matt Pocock | MIT | Its writing model, adopted by `meta-skill-creator` (named in that skill's text) | `SKILLS/meta-skill-creator/` (mounted) | Appendix A; the upstream repository |
| [ayghri/i-have-adhd](https://github.com/ayghri/i-have-adhd) | Ayoub Ghriss | MIT | Adapted into the operating model's communication defaults | `SKILLS/operating-model/references/adhd-output.md` | The same file, "Upstream MIT license" |
| [cursor/plugins](https://github.com/cursor/plugins), `pstack/skills/unslop` | Lauren Tan | MIT | Adapted into the AI-tell catalog | `SKILLS/operating-model/references/patterns.md` | The same file, "Upstream MIT license" |
| [anthropics/skills](https://github.com/anthropics/skills), `frontend-design` | Not named in the license file | Apache-2.0 | The design method, adapted | `SKILLS/design-method/SKILL.md` | Appendix B |

"Mounted" means the folder is not tracked in this repository: deploy clones
[`Exploitacious/agent-skills`](https://github.com/Exploitacious/agent-skills)
(MIT, Copyright (c) 2026 Exploitacious) and `skills-vendor.sh sync` mirrors it
into `SKILLS/` (`SKILLS/VENDORED.tsv`). The `LICENSE.upstream` files travel
inside those folders, so a mirror carries them.

## What each license asks

**MIT (every source except `frontend-design`).** The license grants use, copying,
modification, and distribution, on one condition quoted from its text: "The above
copyright notice and this permission notice shall be included in all copies or
substantial portions of the Software." It also disclaims all warranty. OPS keeps
that notice with each adapted work, as the summary table shows.

**Apache-2.0 (`frontend-design`).** Section 4 of the license asks anyone who
redistributes the work or a derivative to (a) give recipients a copy of the
License, (b) mark modified files with a prominent notice that they were changed,
(c) keep the copyright, patent, trademark, and attribution notices from the
source, and (d) carry over the attribution text of a NOTICE file, if the work
ships one. The upstream skill ships `LICENSE.txt` and `SKILL.md` only, with no
NOTICE file.

## Details

### mattpocock/skills

- Upstream: https://github.com/mattpocock/skills (MIT, Copyright (c) 2026 Matt
  Pocock).
- `grill-me` is adapted from the `grilling` skill at commit `85f83d3fde1d`,
  rewritten for this library (no emojis, a structured question tool where the
  harness has one, a recommended answer on every question, facts gathered by the
  agent, and model invocation left on so it fires at intake).
- `tdd` and `diagnosing-bugs` are vendored at commit `6654f6b60cd9` and
  maintained in `agent-skills`.
- `meta-skill-creator` states that its writing model comes from the upstream
  `writing-for-agents` skill (context pointers, the two loads, the information
  hierarchy). That folder does not bundle the upstream notice, so Appendix A
  carries it.
- The upstream notice is bundled as `LICENSE.upstream` in `grill-me`, `tdd`, and
  `diagnosing-bugs`, and reproduced in Appendix A.

### ayghri/i-have-adhd

- Upstream: https://github.com/ayghri/i-have-adhd (MIT, Copyright (c) 2026 Ayoub
  Ghriss), reviewed at commit `ff690b6fbd3383e4fce6a7e50c7b409ca9a6a804`.
- OPS adapted the file `skills/i-have-adhd/SKILL.md` into the operating model's
  communication defaults. `adhd-output.md` records what was kept, what changed,
  and carries the upstream license in full under "Upstream MIT license".

### cursor/plugins, pstack/skills/unslop

- Upstream: https://github.com/cursor/plugins, under `pstack` (MIT, Copyright
  (c) 2026 Lauren Tan; the license file is `pstack/LICENSE`), adapted at commit
  `fd878692de15`.
- OPS adapted the catalog of AI-writing tells. `patterns.md` states the
  provenance and carries the upstream license in full under "Upstream MIT
  license". Re-review upstream before any version bump, as that file says.

### anthropics/skills, frontend-design

- Upstream: https://github.com/anthropics/skills, `skills/frontend-design`
  (Apache-2.0; the license file is `skills/frontend-design/LICENSE.txt`, which
  names no copyright holder). The adapted version is not pinned to a commit.
- OPS rewrote the design method for this template and added a brand-layer slot
  (`brand.md`) of its own. `SKILLS/design-method/SKILL.md` says the method is
  adapted from the upstream skill, which is the notice that the file was
  changed. The full License text is Appendix B.

## Appendix A: MIT License, mattpocock/skills

Reproduced verbatim from the `LICENSE` file at the root of
https://github.com/mattpocock/skills.

```text
MIT License

Copyright (c) 2026 Matt Pocock

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Appendix B: Apache License 2.0, anthropics/skills frontend-design

Reproduced verbatim from `skills/frontend-design/LICENSE.txt` in
https://github.com/anthropics/skills.

```text

                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS
```
