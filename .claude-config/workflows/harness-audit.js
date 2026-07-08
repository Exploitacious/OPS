export const meta = {
  name: 'harness-audit',
  description: 'Deep review of the OPS AI harness + linuxploitacious workspace: 10 survey lanes, opus dedupe/rank, adversarial verify, completeness critic',
  whenToUse: 'Quarterly (or after major harness changes): full audit of the OPS + linuxploitacious system. ~2M subagent tokens.',
  phases: [
    { title: 'Survey', detail: '10 parallel subsystem reviewers' },
    { title: 'Rank', detail: 'opus chief reviewer dedupes + ranks' },
    { title: 'Verify', detail: 'adversarial refuters + completeness critic' },
  ],
}

const FINDINGS_SCHEMA = {
  type: 'object',
  required: ['lane_summary', 'health_grade', 'findings'],
  properties: {
    lane_summary: { type: 'string', description: '5-10 sentence assessment of this subsystem: what it does well, overall state, biggest risk' },
    health_grade: { type: 'string', description: 'A-F letter grade with one-line justification' },
    files_read: { type: 'array', items: { type: 'string' } },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        required: ['title', 'severity', 'file', 'evidence', 'recommendation'],
        properties: {
          title: { type: 'string' },
          severity: { type: 'string', enum: ['critical', 'high', 'medium', 'low', 'idea'] },
          file: { type: 'string', description: 'absolute path' },
          line: { type: 'integer' },
          evidence: { type: 'string', description: 'verbatim quote or command output proving the finding — never paraphrase from memory' },
          recommendation: { type: 'string' },
          already_tracked: { type: 'boolean', description: 'true if this item already appears in a tracked backlog/worklist doc (e.g. under DELIVERABLES/)' },
        },
      },
    },
  },
}

const PREAMBLE = `You are one lane of a comprehensive one-shot audit of the Operator's AI-harness infrastructure. Real stakes: the Operator runs every Claude Code session — real work, a multi-agent fleet, personal research — through this system. This audit feeds an operator planning discussion; a fabricated file:line reference or an invented quote poisons the whole report, and a vague "looks fine" wastes the run. Per the operating doctrine P3 (verify sub-agent output — claims are not facts) and P14 (conclusions are constraint-driven and verified against the primary source): every finding must cite an absolute file path, a line number where possible, and quote the ACTUAL text as evidence — read the file, do not recall it. Every "no issue found" must name exactly which files you read.

System context you need:
- OPS ships single-profile: Claude Code config lives at ~/.claude (a second profile via CLAUDE_CONFIG_DIR is optional and not assumed here). settings.json / CLAUDE.md / skills / plugins are symlinks into ~/linuxploitacious/claude/.claude/ and ~/OPS/. Box is typically headless Linux.
- ~/OPS is the AI-harness monorepo: CONTEXT/ doctrine (numbered principles in operating-doctrine.md, foreman-charter.md injected every SessionStart), SKILLS/, WORKFORCE/ (multi-agent fleet), PROJECTS/ (external repos), .claude-config/ (hooks + deployers), .claude-memory/ (git-synced auto-memory pools).
- ~/linuxploitacious is the public Stage-1 provisioning repo (shell setup, dotfiles via stow, Claude Code Level-1 config).
- Read any prior audit/worklist docs under ~/OPS/DELIVERABLES/ BEFORE reporting: anything already shipped or explicitly operator-decided there must NOT be re-proposed. If a finding is already tracked in such a backlog/worklist doc, still report it but set already_tracked=true.
- Model policy lives in the shared linuxploitacious CLAUDE.md § Subagent model tiers — read it rather than assuming.

Hard rules: READ-ONLY audit — you must not create, modify, or delete ANY file. No emojis. Findings ranked most-severe first. Severity calibration: critical = actively causing damage/data loss/security exposure; high = will bite soon or silently degrades sessions; medium = drift/debt worth fixing; low = polish; idea = improvement opportunity, not a defect. Do not pad — five real findings beat fifteen noise findings. Distrust documentation claims: verify against the artifact (P14). If a doc says X and the code does Y, that IS a finding.

Your final act: call StructuredOutput with the schema provided. lane_summary is for the foreman, write it dense and specific.`

phase('Survey')

const LANES = [
  {
    key: 'linuxploit-core',
    body: `LANE: linuxploitacious core provisioning scripts.
Files: ~/linuxploitacious/shellSetup.sh (large — read ALL of it), ~/linuxploitacious/winSetup.ps1, ~/linuxploitacious/README.md, everything under ~/linuxploitacious/scripts/.local/, ~/linuxploitacious/dockerHost/.
Questions: (1) Bugs, ordering problems, unsafe operations (curl|bash, rm -rf on variables, unquoted vars), idempotency violations. (2) README drift vs actual script behavior — line refs, documented aliases/functions that do not exist, stow package list consistency. (3) The OPS setup function in shellSetup.sh: does it reference current directory names (e.g. WORKFORCE/, not any renamed-away predecessor)? Report current state with quotes. (4) Dead code / dead menu options. (5) Anything in the public repo that should not be public (secrets, tokens, internal hostnames, personal PII). (6) winSetup.ps1: inspect the ordering and brace/paren integrity statically.`,
  },
  {
    key: 'linuxploit-claude-config',
    body: `LANE: shared Claude Code config + shell dotfiles.
Files: ~/linuxploitacious/claude/.claude/settings.json, ~/linuxploitacious/claude/.claude/CLAUDE.md, ~/linuxploitacious/claude/.claude/statusline.sh, ~/linuxploitacious/zsh/.zshrc, ~/linuxploitacious/bash/.bashrc, ~/.zshrc.local, ~/.bashrc.local, ~/linuxploitacious/tmux/.tmux.conf, ~/linuxploitacious/wezterm/.wezterm.lua, ~/linuxploitacious/powershell/Microsoft.PowerShell_profile.ps1. Also: run 'cd ~/linuxploitacious && git diff' to see uncommitted drift, and 'ls -la ~/' for stray backup files (.zshrc.bak, .bashrc.backup_*).
Questions: (1) settings.json correctness: every key against known Claude Code settings semantics; flag any top-level "model" pin to a model that could go unavailable, and the boot fallback behavior in that case. (2) CLAUDE.md staleness: find stale factual claims — e.g. any auto-compact behavior claim (a "Claude Code auto-compacts at ~75% context" line) vs the actual settings (autoCompactEnabled / DISABLE_AUTO_COMPACT), retired model references, and stale counts. (3) statusline.sh: bugs, cost of refreshInterval; whether statusLine.command hardcoding "$HOME/.claude/statusline.sh" behaves correctly if a second profile is configured (CLAUDE_CONFIG_DIR) given the file is symlinked in both — verify. (4) zshrc/bashrc: dead PATH entries, the .local seam, any claude() wrapper/shim function in ~/.zshrc.local — verify it exists and is correct. (5) Duplication between the two rc files that could drift. (6) Stray files at ~/ that provisioning left behind.`,
  },
  {
    key: 'ops-hooks',
    body: `LANE: OPS hook layer + deployers.
Files: the SessionStart hooks in ~/OPS/.claude-config/hooks/ (foreman-charter.sh, session-briefing.sh, memory-index.sh, post-compact-resume.sh, pre-compact.sh, handoff-check.sh) plus the PreToolUse guards (git-guard.sh, secrets-guard.sh), ~/OPS/.claude-config/deploy.sh, ~/OPS/.claude-config/deploy.ps1, ~/OPS/.claude-config/bin/grabit, ~/OPS/.claude-handoffs/key.sh + README.md, ~/OPS/.claude-config/backup/ contents, and the hook registrations in ~/linuxploitacious/claude/.claude/settings.json.
Questions: (1) Correctness of each hook: exit codes, stderr handling, what happens when OPS is missing, quoting bugs, performance (each SessionStart hook runs at EVERY SessionStart including resumes and /clear — time them with bash -x or time if cheap). (2) The SessionStart matcher is ".*" — check each hook script for whether it branches on the source (startup vs resume vs compact) via $CLAUDE_HOOK_SOURCE / stdin JSON or fires identical full output every time; full re-injection of the charter on every resume/compact is a real context tax, quantify total bytes injected per boot across all SessionStart hooks (run them and measure output size). (3) post-compact-resume.sh: does its log (~/.claude/post-compact-resume.log) grow unbounded? (4) pre-compact.sh: verify snapshot path claims vs what CLAUDE.md says it does. (5) handoff-check.sh project-keying: correct key computation? silent when no baton? (6) deploy.sh/deploy.ps1: idempotency, symlink handling, ensure_claude_localrc correctness. (7) Races when two sessions boot simultaneously (memory-index.sh regen — atomic rename shipped in ac-memory-index, verify the hook path uses it). (8) git-guard.sh / secrets-guard.sh: correctness of the block conditions and that they fail closed, not open.`,
  },
  {
    key: 'workforce-bin',
    body: `LANE: fleet tooling scripts.
Files: every script in ~/OPS/WORKFORCE/bin/ (ac-spawn, ac-msg, ac-register, ac-pulse, ac-reorient, ac-pre-compact, ac-post-compact-check, ac-compact-peer, ac-mcp-reconnect-peer, ac-memory-init, ac-memory-index, ac-memory-gc, ac-task, ac-status, ac-sync, ac-rollup, ac-drift-check, ac-cron-body, ac-backfill-shas, ac-close-project, claude-wrapper.sh, README.md, and the *.test.sh siblings). Check 'git -C ~/OPS status' and 'git -C ~/OPS ls-files WORKFORCE/bin' for hygiene (is __pycache__/ tracked?).
Questions: (1) Real bugs: quoting, TOCTOU, races, error swallowing, hardcoded paths that break on the Windows/second machine, unsafe tmux send-keys injection. (2) ac-msg: check the empty/unbound root passthrough path — can a cross-project message land in the wrong inbox? Quote the code. (3) ac-reorient: does it detect solo vs fleet and stay quiet for non-fleet solo sessions (where foreman-charter/briefing already print), or does it emit "No project bound" advice irrelevant to solo sessions? (4) ac-memory-index/-init/-gc: correctness of the atomic write, host-key logic, index size-limit handling (binary truncates MEMORY.md at ~24.4KB — what does the tool do to stay under?). (5) claude-wrapper.sh shared-host flock gate — verify the implementation is correct. (6) Test coverage: which scripts have .test.sh siblings and what critical path is still untested? (7) Dead scripts no longer reachable from any doc/personality.`,
  },
  {
    key: 'workforce-doctrine',
    body: `LANE: fleet personalities + protocol.
Files: ~/OPS/WORKFORCE/personalities/AGENT.md, COORDINATOR.md, captain-standing-orders.md, name-pool.md; everything in ~/OPS/WORKFORCE/protocol/ (including lessons/ and standing-directions/ subdirs); ~/OPS/WORKFORCE/README.md; ~/OPS/CONTEXT/fleet-doctrine.md; state of ~/OPS/WORKFORCE/FLEETPROJECTS/ (what runtime projects exist, are any stale/abandoned).
Questions: (1) Staleness: the harness has gained native primitives (Agent tool with SendMessage continuation, background Workflow orchestration, TaskCreate/TaskList, CronCreate, remote control). Identify concrete places where the tmux-fleet doctrine mandates hand-rolled machinery (polling inboxes, cron pulse checks, manual compact-peer) that native primitives now cover better or that contradict the Operator's current workflow-tool practice. Be specific: quote the doctrine line, name the native feature. (2) Internal contradictions between AGENT.md / COORDINATOR.md / fleet-doctrine.md / protocol files (thresholds, paths, procedure mismatches). (3) References to files/paths that no longer exist. (4) FLEETPROJECTS runtime hygiene: stale projects, gitignore correctness. (5) Size/weight: these are large files loaded on ACTIVATE — what could be tiered or trimmed without losing function. (6) Is the fleet still worth its complexity for a solo operator given tiers 2-3 (Agent tool + workflows) now handle most fan-out? Give an honest strategic read, not a rubber stamp.`,
  },
  {
    key: 'skills-audit',
    body: `LANE: SKILLS/ portfolio.
Files: every file in ~/OPS/SKILLS/ (agent-delegation/, grabit/, memory-prune/, meta-skill-creator/, pre-compact-synthesis/, session-handoff/, README.md). Compare against any installed third-party plugin skills (~/.claude/plugins/ — find its skills dir) for overlap.
Questions: (1) Per skill: does SKILL.md frontmatter/trigger description match what actually fires it; are internal file references valid; is the content stale vs current model policy (retired model names, obsolete context-window caps, credit-gate assumptions) — quote each stale passage. (2) agent-delegation: its estimation/conversion-factor guidance vs the current reality of Workflow-tool orchestration; does 05_dynamic_workflows.md match the current Workflow tool API (pipeline/parallel/budget/phases)? (3) session-handoff + pre-compact-synthesis: overlap between them, and vs native session-resume (--resume/--continue works across restarts) — is any part now redundant? (4) memory-prune: does its audit workflow still match the current memory architecture (two-tier, CONTEXT/projects lessons)? Does it use Date.now() or other calls the Workflow runtime bans? (5) Dual-track skills (SKILL.md + 00_System_Prompt.md GUI project, e.g. agent-delegation and meta-skill-creator) — drift between the two tracks? (6) meta-skill-creator: is its authoring spec current vs today's skill frontmatter capabilities (allowed-tools, context: fork, agent field, hooks in skills, $ARGUMENTS)? (7) Missing skills the Operator obviously needs but lacks (base this on the doctrine + memory pointers you see, not speculation).`,
  },
  {
    key: 'context-coherence',
    body: `LANE: doctrine/documentation coherence across the instruction chain.
Files: ~/OPS/CLAUDE.md, ~/OPS/README.md, ~/OPS/DEPLOYMENT.md, ~/OPS/CHANGELOG.md (if present), all of ~/OPS/CONTEXT/*.md (operating-doctrine.md, foreman-charter.md, working-preferences.md, project-kata.md, fleet-doctrine.md, worker-digest.md), ~/linuxploitacious/claude/.claude/CLAUDE.md, plus ~/OPS/CONTEXT/projects/ (list only + spot-read 2 if any exist).
Questions: (1) Build a duplication map: which normative rules exist in 3+ places (compression rules, sycophancy bans, model-tier tables, commit standards, AskUserQuestion patterns, memory routing) and which copies have drifted from the declared source-of-truth. Quote drifted pairs. (2) Contradictions/tensions: OPS CLAUDE.md startup sequence (AskUserQuestion before executing, show plan, wait for approval, TaskCreate) vs foreman-charter autonomous-execution mode and permission guard — the charter patches this with "cold-start intake" framing, but assess whether the CLAUDE.md text itself was updated to match; also TodoWrite vs TaskCreate naming (which is current, and do any files still use the stale name?). (3) Stale factual claims: any auto-compact behavior claim (vs settings where autocompact is OFF), retired model references, obsolete context-window caps, stale line-number references, stale counts ("X principles"). (4) README vs reality: folder tree accuracy (NOTES/, DELIVERABLES/, .claude-handoffs/ present?), CHANGELOG discipline (does it reflect recent commits?). (5) Load-order sanity: what an actual session is told to read vs what hooks already inject — double-instruction (e.g. CLAUDE.md says read foreman-charter, hook already injected it). (6) The Operator-preferences file (working-preferences.md): internal quality, whether anything contradicts the other CONTEXT files. (7) For each drift cluster, name ONE consolidation move (which copy becomes a pointer).`,
  },
  {
    key: 'memory-audit',
    body: `LANE: memory system state.
Files/dirs: ~/OPS/.claude-memory/ (every pool dir — list entries, read the MEMORY.md indexes, spot-read ~10 entries across pools), ~/.claude/projects/<workspace>/memory/ (the current session pool — read MEMORY.md + every entry file, it is small), ~/OPS/.claude-memory/README.md + MIGRATION_MANIFEST.md (if present), ~/OPS/CONTEXT/projects/*.md (list + spot-read 2 for quality if any exist), ~/OPS/.claude-handoffs/ (pending/ + archive/ state). Run ~/OPS/WORKFORCE/bin/ac-memory-gc if it is safe/read-only (it is documented as read-only inventory) and report its output.
Questions: (1) Stale/contradictory memories: find entries contradicted by newer ground truth (e.g. a model-availability note that a later policy reset reversed, or a superseded deploy-timing fact). Check MEMORY.md index lines match their files. (2) Pool hygiene: which pools are over/near the 24.4KB index limit, empty, or stale (ac-memory-gc output). (3) Uncommitted memory drift in ~/OPS git status — how many files, how old, is the "commit memory often" discipline actually holding? (4) Symlink integrity: do the profile memory dirs (e.g. ~/.claude/projects/*/memory) point where ac-memory-init intends? Run ls -la on those dirs. If a second profile via CLAUDE_CONFIG_DIR is configured, does it share pools correctly? (5) Cross-profile duplication: if a second profile is configured, does it hold divergent copies of the same facts? (6) Secrets scan: any entry containing literal credentials — report existence and file, DO NOT quote the secret itself. (7) Handoff dir state: stale pending batons?`,
  },
  {
    key: 'boot-tax',
    body: `LANE: session boot cost measurement.
Task: quantify exactly what every new Claude Code session pays before the first user word, and what a resumed/compacted session re-pays. Method: (a) run each of the 6 SessionStart hooks yourself exactly as settings.json invokes them (they are read-only printers — but read each script first to confirm no side effects beyond log/snapshot writes before running; skip any that would mutate state and estimate from code instead) with CLAUDE_CONFIG_DIR unset and note stdout bytes; (b) measure bytes of the always-loaded instruction chain: ~/linuxploitacious/claude/.claude/CLAUDE.md, ~/OPS/CLAUDE.md, MEMORY.md of the active pool, plus every CONTEXT file the OPS CLAUDE.md startup sequence ORDERS the session to additionally read every session (name them from the actual CLAUDE.md, including any foreman-charter double-read); (c) estimate tokens at ~3.7 bytes/token; (d) build a table: source → bytes → est tokens → fires on (startup/resume/compact/clear) → duplicated elsewhere? (e) TOTAL for a cold boot in ~ vs in ~/OPS, and the marginal cost when the model actually obeys "read CONTEXT files every session". (f) Compare against what the Operator gets for it; identify the 3 biggest savings with concrete restructuring (e.g. charter slimming, source-branching in hooks so resume/compact re-inject less, pointer-izing duplicated rule blocks). Note subagent angle: SessionStart hooks do NOT fire for Agent-tool workers, but CLAUDE.md chain DOES load for each spawned worker — count that per-spawn cost for a 15-worker workflow. Cite every number.`,
  },
  {
    key: 'projects-layer',
    body: `LANE: projects + notes + deliverables layer.
Files: ~/OPS/PROJECTS/projects-map.md, any backlog file (IDEAS.md / ROADMAP.md if present), any lessons-migration manifest if present, sync-check.sh + Sync-Check.ps1, ~/OPS/CONTEXT/project-kata.md, ~/OPS/DELIVERABLES/README.md + file list, ~/OPS/NOTES/ structure (list MASTER/ top 2 levels only), and ls of each org cluster under ~/OPS/PROJECTS/ (repo lists only, do NOT descend into the repos), plus ~/ root clutter vs the "keep home clean" rule.
Questions: (1) projects-map accuracy: do the mapped repos exist on disk; missing/extra entries? (2) Backlog hygiene: which entries are DONE-but-not-removed — the file's own convention says completed items move to CHANGELOG. (3) project-kata.md: is its guidance consistent with what OPS itself does (does the kata bless the root files OPS actually keeps)? (4) NOTES/MASTER: is it a real Obsidian vault (has .obsidian?) and is anything misfiled at NOTES/ root (the rule says never place files directly in NOTES/)? (5) Root-of-home clutter: what should move where per the Operator's own rules? (6) DELIVERABLES: files present vs README description drift.`,
  },
]

const surveyResults = await parallel(
  LANES.map((l) => () =>
    agent(PREAMBLE + '\n\n' + l.body, {
      label: 'survey:' + l.key,
      phase: 'Survey',
      schema: FINDINGS_SCHEMA,
      model: 'sonnet',
    }).then((r) => (r ? { lane: l.key, ...r } : null))
  )
)

const lanes = surveyResults.filter(Boolean)
log('Survey done: ' + lanes.length + '/' + LANES.length + ' lanes returned, ' + lanes.reduce((n, l) => n + (l.findings || []).length, 0) + ' raw findings')

phase('Rank')

const CHIEF_SCHEMA = {
  type: 'object',
  required: ['overall_read', 'top_findings', 'dropped'],
  properties: {
    overall_read: { type: 'string', description: '2-3 paragraph honest strategic assessment of the whole harness' },
    top_findings: {
      type: 'array',
      items: {
        type: 'object',
        required: ['id', 'title', 'lane', 'severity', 'file', 'why_it_matters', 'needs_verification'],
        properties: {
          id: { type: 'string' },
          title: { type: 'string' },
          lane: { type: 'string' },
          severity: { type: 'string' },
          file: { type: 'string' },
          line: { type: 'integer' },
          evidence: { type: 'string' },
          recommendation: { type: 'string' },
          why_it_matters: { type: 'string' },
          needs_verification: { type: 'boolean', description: 'true if the claim is specific/surprising enough that an independent refuter should check it before the operator sees it' },
        },
      },
    },
    dropped: { type: 'array', items: { type: 'string' }, description: 'notable findings you deduped or rejected, with one-line reason each' },
    theme_clusters: { type: 'array', items: { type: 'string' }, description: 'cross-lane themes: same root cause appearing in multiple lanes' },
  },
}

const chief = await agent(
  `You are the chief reviewer of a 10-lane audit of the Operator's AI-harness infrastructure (OPS + linuxploitacious; context: single-profile Claude Code setup, doctrine-driven foreman model, multi-agent fleet, git-synced memory). The lane outputs are below as JSON. Your job: dedupe across lanes (same root cause reported twice = one finding, note both call sites), rank by real operator impact, kill anything that smells fabricated or that merely restates an operator-decided item (anything already decided in a DELIVERABLES/ worklist, or already_tracked=true entries — those may appear only in a short "already tracked" list inside overall_read). Where two lanes contradict each other, say so and pick a side by reading the actual file yourself (you have tools — spot-verify at least the 5 most severe findings' evidence quotes against the real files before ranking them). Produce at most 20 top_findings; keep every evidence quote under 300 characters and the whole payload compact — if StructuredOutput validation fails, TRIM the real payload and resubmit; NEVER submit a test/debug stub. Mark needs_verification=true for any finding whose evidence you could not personally confirm. Severity calibration: critical = active damage/exposure; high = bites soon or silently degrades every session; medium = drift/debt; low/idea = polish/opportunity. This report goes straight to the Operator, who explicitly asked for a serious, non-flattering review — an inflated severity or a soft-pedaled real problem both fail the review.

LANE OUTPUTS:
` + JSON.stringify(lanes, null, 1),
  { label: 'chief-reviewer', phase: 'Rank', schema: CHIEF_SCHEMA, model: 'opus' }
)

if (!chief) throw new Error('chief reviewer returned null')
log('Chief ranked ' + chief.top_findings.length + ' findings; ' + chief.top_findings.filter((f) => f.needs_verification).length + ' need verification')

phase('Verify')

const VERDICT_SCHEMA = {
  type: 'object',
  required: ['verdict', 'reasoning'],
  properties: {
    verdict: { type: 'string', enum: ['CONFIRMED', 'REFUTED', 'PARTIAL'] },
    reasoning: { type: 'string' },
    corrected_detail: { type: 'string', description: 'if PARTIAL/REFUTED: what is actually true, with file:line evidence' },
  },
}

const CRITIC_SCHEMA = {
  type: 'object',
  required: ['gaps'],
  properties: {
    gaps: {
      type: 'array',
      items: {
        type: 'object',
        required: ['area', 'why_it_matters'],
        properties: {
          area: { type: 'string' },
          why_it_matters: { type: 'string' },
          suggested_check: { type: 'string' },
        },
      },
    },
    strategic_opportunities: { type: 'array', items: { type: 'string' }, description: 'improvement directions NO lane surfaced — things a frontier model should tell this operator about where his harness could go next' },
  },
}

const toVerify = chief.top_findings.filter((f) => f.needs_verification)
const [verdicts, critic] = await parallel([
  () =>
    parallel(
      toVerify.map((f) => () =>
        agent(
          `Adversarial verification. A code-audit finding about the Operator's AI-harness repos is below. Your default posture: try to REFUTE it. Read the actual file(s) at the cited locations, run commands if needed (read-only — do not modify anything). If the evidence quote does not exist verbatim-or-close in the file, or the interpretation is wrong, or newer state supersedes it, say REFUTED or PARTIAL with the corrected truth. Only CONFIRM what you personally reproduced. The Operator acts on CONFIRMED findings; a false CONFIRM wastes scarce time, a false REFUTE hides a real defect — check, don't guess.

FINDING:
` + JSON.stringify(f, null, 1),
          { label: 'verify:' + f.id, phase: 'Verify', schema: VERDICT_SCHEMA, model: 'sonnet' }
        ).then((v) => ({ id: f.id, verdict: v }))
      )
    ),
  () =>
    agent(
      PREAMBLE +
        `

LANE: completeness critic — the LAST reviewer. Below are the 10 lane summaries + the chief reviewer's ranked findings from a full audit of this harness. Your job is what is MISSING: (1) subsystems or failure modes no lane examined (think: backup/restore of the whole setup, what happens when this box dies, secrets management posture across the whole system given bypassPermissions + a public provisioning repo, cost/usage observability, the daemon/ and jobs/ dirs in the profile dirs, plugin supply chain — any third-party plugins are auto-updated from their source, cron/scheduled state, statusline refresh cost, .claude.json contents); (2) questions the Operator should be asked that no finding answers; (3) strategic_opportunities: as a frontier-model peer, name the highest-leverage next moves for this harness that NO lane proposed — be concrete and grounded in what you can verify exists, not generic advice. Investigate with tools (read-only) before claiming a gap is real. Do not repeat ranked findings.

LANE SUMMARIES:
` +
        JSON.stringify(lanes.map((l) => ({ lane: l.lane, health_grade: l.health_grade, summary: l.lane_summary })), null, 1) +
        `

CHIEF FINDINGS:
` +
        JSON.stringify(chief.top_findings.map((f) => ({ id: f.id, title: f.title, severity: f.severity })), null, 1),
      { label: 'completeness-critic', phase: 'Verify', schema: CRITIC_SCHEMA, model: 'opus' }
    ),
])

const verdictById = {}
for (const v of (verdicts || []).filter(Boolean)) verdictById[v.id] = v.verdict

const finalFindings = chief.top_findings.map((f) => ({
  ...f,
  verification: f.needs_verification ? (verdictById[f.id] ? verdictById[f.id].verdict : 'UNVERIFIED') : 'CHIEF_CONFIRMED',
  verification_note: f.needs_verification && verdictById[f.id] ? verdictById[f.id].reasoning : undefined,
  corrected_detail: f.needs_verification && verdictById[f.id] ? verdictById[f.id].corrected_detail : undefined,
}))

log('Verification done: ' + finalFindings.filter((f) => f.verification === 'CONFIRMED' || f.verification === 'CHIEF_CONFIRMED').length + ' confirmed of ' + finalFindings.length)

return {
  lane_grades: lanes.map((l) => ({ lane: l.lane, grade: l.health_grade, summary: l.lane_summary })),
  overall_read: chief.overall_read,
  theme_clusters: chief.theme_clusters,
  findings: finalFindings,
  dropped: chief.dropped,
  completeness_gaps: critic ? critic.gaps : [],
  strategic_opportunities: critic ? critic.strategic_opportunities : [],
}