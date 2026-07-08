export const meta = {
  name: 'transcript-mine',
  description: 'Mine session transcripts for unfiled lessons/decisions/feedback; returns a STAGED table (writes nothing) for operator-approved filing',
  whenToUse: 'Closeout companion or periodic sweep: pass {since: ISO-date} (e.g. the last-closeout stamp) and it mines main-session transcripts newer than that for knowledge that was never captured to memory/lessons. Staged-only — filing happens after operator review. Historical deep-mines: raise limit deliberately (cost scales with transcript count/size).',
  phases: [
    { title: 'Scout', detail: 'list candidate transcripts' },
    { title: 'Mine', detail: 'one miner per transcript' },
  ],
}

// args: { since: 'YYYY-MM-DD or ISO' (required), limit: max transcripts (default 8), order: 'small-first'|'recent-first' (default small-first) }
// Some invocation paths deliver args as a JSON string — accept both.
let ARGS = args
if (typeof ARGS === 'string') { try { ARGS = JSON.parse(ARGS) } catch (e) { ARGS = null } }
if (!ARGS || !ARGS.since) throw new Error("transcript-mine requires args.since (ISO date — e.g. the ~/.local/state/ops/last-closeout stamp)")
const LIMIT = ARGS.limit || 8
const ORDER = ARGS.order || 'small-first'

const SCOUT_SCHEMA = {
  type: 'object',
  required: ['transcripts'],
  properties: {
    transcripts: {
      type: 'array',
      items: {
        type: 'object',
        required: ['path', 'size_kb', 'project'],
        properties: {
          path: { type: 'string' },
          size_kb: { type: 'integer' },
          mtime: { type: 'string' },
          project: { type: 'string', description: 'decoded workspace/project the session ran in' },
        },
      },
    },
    excluded_note: { type: 'string' },
  },
}

const MINE_SCHEMA = {
  type: 'object',
  required: ['transcript', 'candidates'],
  properties: {
    transcript: { type: 'string' },
    session_gist: { type: 'string', description: 'one sentence: what this session was about' },
    candidates: {
      type: 'array',
      items: {
        type: 'object',
        required: ['title', 'type', 'evidence', 'proposed_home'],
        properties: {
          title: { type: 'string' },
          type: { type: 'string', enum: ['feedback', 'project', 'reference', 'user', 'lesson'] },
          evidence: { type: 'string', description: 'short verbatim quote from the transcript proving it — max 250 chars' },
          proposed_home: { type: 'string', description: 'exact target: cross-project pool | <project> pool | CONTEXT/projects/<p>-lessons.md | doctrine (name the principle/skill)' },
          already_captured: { type: 'boolean', description: 'true if you found it in a MEMORY.md index or lessons file — include only if the captured version is materially incomplete' },
          confidence: { type: 'string', enum: ['high', 'medium', 'low'] },
        },
      },
    },
  },
}

phase('Scout')
const scout = await agent(
  `Read-only scout for a transcript-mining run over the Operator's Claude Code session history. List MAIN-SESSION transcripts modified since ${ARGS.since}: files matching <config>/projects/<workspace>/<uuid>.jsonl under ~/.claude/projects/ (and any second profile dir, e.g. a CLAUDE_CONFIG_DIR pool, if one is in use) — EXCLUDE anything under a subagents/ subdirectory (worker transcripts are noise; their conclusions surfaced in the parent) and files under 20KB (too small to hold unfiled lessons). Use find with -newermt '${ARGS.since}' and stat for sizes. Decode each workspace dir name to a human project label (a dir like ...-OPS-PROJECTS-ExampleOrg-sample-app decodes to sample-app). Return up to ${LIMIT * 3} candidates sorted ${ORDER === 'small-first' ? 'smallest first' : 'newest first'}; the foreman takes the top ${LIMIT}. You change nothing. StructuredOutput per schema.`,
  { label: 'scout', phase: 'Scout', schema: SCOUT_SCHEMA, model: 'haiku' }
)
if (!scout || !scout.transcripts.length) return { staged: [], note: 'no transcripts matched since=' + ARGS.since }

const picked = scout.transcripts.slice(0, LIMIT)
log('Mining ' + picked.length + ' transcripts (of ' + scout.transcripts.length + ' candidates)')

phase('Mine')
// NOTE: take the transcript PATH from the picked item, not from the miner's
// echoed field — miners fill free-text fields verbosely and drift the path.
const mined = await parallel(
  picked.map((t) => () =>
    agent(
      `You are mining ONE Claude Code session transcript for knowledge that was never filed — the operator's standing complaint is "agents forgetting to document all the things they're supposed to," and this run is the recovery mechanism. Transcript: ${t.path} (project: ${t.project}, ~${t.size_kb}KB of JSONL; read it with the Read tool in chunks — user/assistant text matters, tool noise mostly does not).

Hunt for, in priority order: (1) operator FEEDBACK — corrections, preferences, "don't do X", validated approaches; (2) DECISIONS made and acted on but never written to a decision record/memory; (3) hard-won technical lessons — gotchas, dead ends with named constraints, vendor quirks, verified API shapes; (4) durable reference facts. Ignore: routine task mechanics, anything ephemeral, anything whose home is the code itself.

Before proposing a candidate, CHECK it is actually unfiled: grep the memory indexes (~/OPS/.claude-memory/*/MEMORY.md) and the matching ~/OPS/CONTEXT/projects/${t.project.toLowerCase()}-lessons.md (if it exists) for its key terms. Filed-and-complete → drop it; filed-but-materially-incomplete → include with already_captured=true and say what is missing.

Per the Operator's routing taxonomy (foreman-charter § Where knowledge goes): operator feedback + cross-project gotchas → cross-project pool; in-flight project state → that project's pool; durable single-project lessons → CONTEXT/projects/<p>-lessons.md; universal patterns → doctrine. Max 8 candidates, ranked by value; zero candidates is a valid, honest result for a routine session. Evidence quotes ≤250 chars. You change NOTHING — this is a staging run; the operator approves filing later. StructuredOutput per schema.`,
      { label: 'mine:' + t.project, phase: 'Mine', schema: MINE_SCHEMA, model: 'sonnet' }
    )
  )
)

const staged = []
const seen = new Set()
mined.forEach((m, i) => {
  if (!m) return
  for (const c of m.candidates || []) {
    const key = (c.title || '').toLowerCase().replace(/[^a-z0-9]+/g, '-')
    if (seen.has(key)) continue
    seen.add(key)
    staged.push({ ...c, transcript: picked[i].path, session_gist: (m.session_gist || '').slice(0, 300) })
  }
})
staged.sort((a, b) => (a.confidence === b.confidence ? 0 : a.confidence === 'high' ? -1 : b.confidence === 'high' ? 1 : a.confidence === 'medium' ? -1 : 1))
log('Staged ' + staged.length + ' unfiled candidates from ' + mined.filter(Boolean).length + ' transcripts')

return {
  staged,
  mined_transcripts: picked.map((t) => t.path),
  note: 'STAGED ONLY — nothing written. File approved items to their proposed_home (closeout stage or manually), then re-run ac-memory-index on touched pools.',
}
