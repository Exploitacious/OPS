// Memory-prune audit workflow (Claude Code dynamic workflow / P12 Tier 3).
// READ-ONLY: inventories + classifies every auto-memory entry, returns a
// keep/promote/move/discard action table. Executes NOTHING — the parent
// session presents the table for Operator sign-off, then acts (see
// SKILL.md guardrails). Invoke via the Workflow tool.
//
// args (optional): { dir: "<absolute path to the workspace memory dir>" }
// Defaults to the OPS workspace memory dir, derived from $HOME. Claude Code
// names each workspace's memory dir after the cwd slug (slashes -> dashes),
// so a clone at ~/OPS produces "workspace-<home-slug>-OPS" — override via
// args.dir if your clone lives somewhere else.

export const meta = {
  name: 'memory-prune-audit',
  description: 'Read-only audit of OPS auto-memory: classify each entry keep/promote/move/discard, dedup, return action table',
  phases: [
    { title: 'Context', detail: 'inventory entries + digest live doctrine for already-canonical check' },
    { title: 'Classify', detail: 'parallel batches read + classify each entry' },
    { title: 'Synthesize', detail: 'dedup, reconcile counts, emit action table' },
  ],
}

const HOME = process.env.HOME || '/root'
const OPS_ROOT = `${HOME}/OPS`
const HOME_SLUG = HOME.replace(/^\//, '').replace(/\//g, '-')
const DIR = (args && args.dir) || `${OPS_ROOT}/.claude-memory/workspace-${HOME_SLUG}-OPS`

phase('Context')

// One agent inventories the files AND digests live doctrine, so the
// "already promoted" check reflects the CURRENT doctrine, never a stale
// hardcoded index. Returns the file list + a compact canonical-index.
const CTX = {
  type: 'object',
  properties: {
    files: { type: 'array', items: { type: 'string' } },
    canonical_index: { type: 'string', description: 'compact digest: each operating-doctrine principle (Pn + name + one-line gist), fleet-doctrine F-rules, and agent-delegation skill coverage — so classifiers can flag entries already captured' },
  },
  required: ['files', 'canonical_index'],
  additionalProperties: false,
}
const ctx = await agent(
  `Two jobs, return both.
1. List every Markdown memory ENTRY file in ${DIR} (run: ls -1 ${DIR}/*.md). Return bare filenames in 'files', EXCLUDING MEMORY.md (that is the index).
2. Read these OPS docs and produce a COMPACT 'canonical_index' digest of what is ALREADY captured in doctrine/skill, so classifiers can mark redundant memories as discard ("already in Pn"):
   - ${OPS_ROOT}/CONTEXT/operating-doctrine.md  (every principle: Pn + name + one-line gist)
   - ${OPS_ROOT}/CONTEXT/foreman-charter.md     (posture + "Where knowledge goes" routing)
   - ${OPS_ROOT}/CONTEXT/fleet-doctrine.md      (named F-rules, one line each)
   - list ${OPS_ROOT}/SKILLS/ entries by name (one line each)
Keep the digest tight — principle/rule names + gists, not full text.`,
  { label: 'context', phase: 'Context', model: 'sonnet', schema: CTX }
)
const files = (ctx.files || []).filter(f => f && f !== 'MEMORY.md')
const canonical = ctx.canonical_index || ''
log(`Inventory: ${files.length} memory entries; canonical index ${canonical.length} chars`)

const BATCH = 6
const batches = []
for (let i = 0; i < files.length; i += BATCH) batches.push(files.slice(i, i + BATCH))

const CRITERIA = `
Classify each entry into exactly ONE recommendation (the four homes from the placement taxonomy):

 keep    = stays in personal auto-memory. Cross-project gotchas, harness/tooling behavior, host/cred pointers,
           model-behavior calibration, personal project-state notes, OR generic tech truths spanning many projects
           (belong to no single repo).
 promote = a UNIVERSAL pattern (any project/agent) → OPS doctrine or a skill. target = the doctrine file/principle
           or skill. If ALREADY in the canonical_index below, this is 'discard' with reason "already in <Pn/rule>", NOT promote.
 move    = a reusable lesson tied to ONE project's code/vendor/infra → that project's OPS CONTEXT/projects/<project>-lessons.md
           (synced, loaded on-demand, launch-dir-independent — the DEFAULT home for project knowledge). target = the <project>-lessons.md file.
           (Exception: a repo with an active human team reading its own docs/ may target that repo instead — note it in target.)
 discard = stale / superseded / RESOLVED-and-closed / one-conversation-only / already-in-canonical / duplicate.
           reason MUST justify it.

Bias: memory is cheap; over-capture is fine. Discard only when genuinely stale, resolved, redundant, or already-canonical.
NEVER discard a live-verified vendor API shape or a host/cred pointer. Flag heavy overlaps as duplicate pairs.

--- CANONICAL INDEX (already captured in doctrine/skill) ---
${canonical}
--- END CANONICAL INDEX ---
`

phase('Classify')
const CLASSIFY = {
  type: 'object',
  properties: {
    entries: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          name: { type: 'string' },
          current_type: { type: 'string' },
          summary: { type: 'string' },
          recommendation: { type: 'string', enum: ['keep', 'promote', 'move', 'discard'] },
          target: { type: 'string' },
          reason: { type: 'string' },
          overlaps: { type: 'string' },
        },
        required: ['name', 'current_type', 'summary', 'recommendation', 'target', 'reason', 'overlaps'],
        additionalProperties: false,
      },
    },
  },
  required: ['entries'],
  additionalProperties: false,
}

const classified = await parallel(
  batches.map((batch, idx) => () =>
    agent(
      `You audit the Operator's OPS auto-memory for a prune pass. Stakes: this index is read into every Claude Code session;
stale/redundant entries waste context and mislead future agents, while wrongly discarding a live-verified vendor fact
forces re-discovery the hard way. Be accurate, not aggressive.

Read these ${batch.length} memory files IN FULL (Read each absolute path):
${batch.map(f => `  - ${DIR}/${f}`).join('\n')}

${CRITERIA}

For EACH file return one entry object, grounded in the file's actual content (not the filename). RESOLVED/closed → lean
discard. Universal pattern already in the canonical index → discard ("already in <ref>"). Return all ${batch.length}.`,
      { label: `classify:batch-${idx + 1}`, phase: 'Classify', model: 'sonnet', schema: CLASSIFY }
    )
  )
)

const allEntries = classified.filter(Boolean).flatMap(c => c.entries || [])
log(`Classified ${allEntries.length} entries across ${batches.length} batches`)

phase('Synthesize')
const SYNTH = {
  type: 'object',
  properties: {
    decisions: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          name: { type: 'string' },
          recommendation: { type: 'string', enum: ['keep', 'promote', 'move', 'discard'] },
          target: { type: 'string' },
          reason: { type: 'string' },
        },
        required: ['name', 'recommendation', 'target', 'reason'],
        additionalProperties: false,
      },
    },
    duplicate_clusters: { type: 'array', items: { type: 'string' } },
    counts: {
      type: 'object',
      properties: { keep: { type: 'number' }, promote: { type: 'number' }, move: { type: 'number' }, discard: { type: 'number' } },
      required: ['keep', 'promote', 'move', 'discard'],
      additionalProperties: false,
    },
    promote_targets: { type: 'array', items: { type: 'string' } },
    move_projects: { type: 'array', items: { type: 'string' } },
    risky_discard_review: { type: 'string', description: 'explicit check: is any discard actually a live vendor/host/cred fact? confirm none, or flag.' },
    notes: { type: 'string' },
  },
  required: ['decisions', 'duplicate_clusters', 'counts', 'promote_targets', 'move_projects', 'risky_discard_review', 'notes'],
  additionalProperties: false,
}

const synth = await agent(
  `Finalize a memory-prune audit for the Operator. Below are ${allEntries.length} per-entry classifications from parallel auditors.
Reconcile into one action plan:
 1. Resolve duplicate/overlap clusters (keep the best, discard the rest; note in duplicate_clusters).
 2. risky_discard_review: explicitly confirm NO discard is a live vendor API shape or host/cred pointer; flip any that is.
 3. Group promotes by destination, moves by project repo.
 4. One decision row per ORIGINAL entry (each appears exactly once).
 5. counts MUST sum to ${allEntries.length}.

Raw classifications (JSON):
${JSON.stringify(allEntries)}`,
  { label: 'synthesize', phase: 'Synthesize', model: 'sonnet', schema: SYNTH }
)

return synth
