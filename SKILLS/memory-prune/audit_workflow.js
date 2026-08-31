// Memory-prune audit workflow (Claude Code dynamic workflow / P12 Tier 3).
// READ-ONLY: inventories + classifies every auto-memory entry, returns a
// keep/promote/move/discard action table. Executes NOTHING — the parent
// session presents the table for Operator sign-off, then acts (see
// SKILL.md guardrails). Invoke via the Workflow tool.
//
// args (optional): { dir: "<absolute path to the workspace memory dir>" }
// Defaults to the OPS workspace memory dir, derived from the environment.
// Claude Code names each workspace's memory dir after the cwd slug (path
// separators -> dashes), so a clone at ~/OPS produces
// "workspace-<home-slug>-OPS" — override via args.dir if the clone lives
// elsewhere.
//
// If the sandbox exposes no home variable this THROWS rather than guessing.
// A literal home path baked in would, on any other machine or user, silently
// point the audit at a nonexistent directory — and a read-only audit that
// finds nothing looks exactly like a clean pool, so the wrong answer is
// indistinguishable from the right one. A loud failure naming args.dir is
// strictly better than a silent empty result.

export const meta = {
  name: 'memory-prune-audit',
  description: 'Read-only audit of OPS auto-memory: classify each entry keep/promote/move/discard, dedup, return action table',
  phases: [
    { title: 'Context', detail: 'inventory entries + digest live doctrine for already-canonical check' },
    { title: 'Classify', detail: 'parallel batches read + classify each entry' },
    { title: 'Synthesize', detail: 'dedup, reconcile counts, emit action table' },
  ],
}

// args-interpolation guard: the harness can deliver `args` as a JSON STRING (or
// drop it entirely on the first invocation), so field access silently reads
// undefined. Normalize once, log what arrived.
const ARGS = (typeof args === 'string') ? (() => { try { return JSON.parse(args) } catch { return {} } })() : (args || {})
log('memory-prune-audit args received: ' + JSON.stringify(ARGS))
const ENV = (typeof process !== 'undefined' && process.env) || {}
// USERPROFILE second: Windows does not set HOME, so HOME-only derivation is a
// silent Linux-ism. Neither present -> no guess.
const HOME = ENV.HOME || ENV.USERPROFILE || null
if (!HOME && !ARGS.dir) {
  throw new Error(
    'memory-prune-audit: no HOME/USERPROFILE in this sandbox and no args.dir given. ' +
    'Pass args.dir with the absolute path to the workspace memory dir — refusing to ' +
    'guess, because an audit pointed at the wrong directory returns "clean".'
  )
}
const OPS_ROOT = ARGS.ops || `${HOME}/OPS`
// The pool dir name is "<machine-key>-<home-slug>-OPS", and the machine key is
// NOT derivable here: it comes from `hostname` (see WORKFORCE/bin/ac-memory-init),
// which this sandbox cannot run. Hardcoding "workspace-" silently audits nothing
// on every other machine, while globbing "*-<home-slug>-OPS" is worse, because
// .claude-memory/ is a CROSS-MACHINE mirror and the glob matches several
// machines' pools at once. So: take args.dir when given, otherwise let the
// context agent resolve the ACTIVE pool through the config-dir symlink
// (authoritative by construction) and report back which directory it used, so
// the choice is logged rather than assumed.
const DIR = ARGS.dir || null
const DIR_INSTRUCTION = DIR
  ? `The memory pool directory is ${DIR}.`
  : `Resolve the ACTIVE memory pool directory yourself, and report it in 'dir_used'. ` +
    `It is the real path behind "$CLAUDE_CONFIG_DIR/projects/<encoded-cwd>/memory" ` +
    `(encoded-cwd = the session cwd with every path separator replaced by "-"), which ` +
    `is a symlink into ${OPS_ROOT}/.claude-memory/. Resolve it with readlink -f. Do NOT ` +
    `guess a machine-key prefix and do NOT glob — .claude-memory/ mirrors SEVERAL ` +
    `machines' pools and a glob would match more than one. If you cannot resolve it, ` +
    `say so in 'dir_used' rather than picking one.`

phase('Context')

// One agent inventories the files AND digests live doctrine, so the
// "already promoted" check reflects the CURRENT doctrine, never a stale
// hardcoded index. Returns the file list + a compact canonical-index.
const CTX = {
  type: 'object',
  properties: {
    files: { type: 'array', items: { type: 'string' } },
    dir_used: { type: 'string', description: 'absolute path of the memory pool actually inventoried — logged so the audited directory is never assumed' },
    canonical_index: { type: 'string', description: 'compact digest: each operating-doctrine principle (Pn + name + one-line gist), fleet-doctrine F-rules, and delegation-skill coverage — so classifiers can flag entries already captured' },
  },
  required: ['files', 'dir_used', 'canonical_index'],
  additionalProperties: false,
}
const ctx = await agent(
  `Two jobs, return both.
1. ${DIR_INSTRUCTION} List every Markdown memory ENTRY file in it (ls -1 <dir>/*.md). Return bare filenames in 'files', EXCLUDING MEMORY.md (that is the index).
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
log(`Inventory: ${files.length} memory entries in ${ctx.dir_used || '(dir unreported)'}; canonical index ${canonical.length} chars`)

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
      `You audit the operator's OPS auto-memory for a prune pass. Stakes: this index is read into every Claude Code session;
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
  `Finalize a memory-prune audit for the operator. Below are ${allEntries.length} per-entry classifications from parallel auditors.
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
