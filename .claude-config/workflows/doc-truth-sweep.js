export const meta = {
  name: 'doc-truth-sweep',
  description: 'Parameterized doc-vs-reality fix sweep: pass lanes of {key, files, fixes} via args; one worker per lane, file-disjoint',
  whenToUse: 'After an audit surfaces documentation-vs-reality contradictions, or after a big change wave: pass the finding lanes as args and this fixes them in parallel. Lanes must be file-disjoint.',
  phases: [{ title: 'Sweep', detail: 'one fixer per file-disjoint lane' }],
}

// args shape: { lanes: [{ key: 'short-slug', files: ['/abs/path', ...], fixes: 'numbered fix list with evidence + expected verification' }, ...] }
if (!args || !Array.isArray(args.lanes) || args.lanes.length === 0) {
  throw new Error('doc-truth-sweep requires args.lanes = [{key, files, fixes}, ...]')
}

const RESULT = {
  type: 'object',
  required: ['status', 'summary', 'files_changed', 'verification'],
  properties: {
    status: { type: 'string', enum: ['done', 'partial', 'blocked'] },
    summary: { type: 'string' },
    files_changed: { type: 'array', items: { type: 'string' } },
    verification: { type: 'string', description: 'real command output / quoted before-after proving each fix' },
    skipped: { type: 'array', items: { type: 'string' }, description: 'items deliberately not done, each with a one-line reason' },
  },
}

const COMMON = `You are one lane of a doc-truth sweep over the Operator's OPS AI-harness and related repos. The Operator keeps deliberate repetition in the doctrine (repetition aids agent compliance — do NOT trim or consolidate for token savings), but every factual claim must be TRUE and every copy must AGREE: repetition of contradictions teaches agents to distrust the docs. Your fixes ship to master after foreman review; every future session reads what you write. Match each file's existing voice and formatting exactly.

Rules (doctrine by name — baseline in ~/OPS/CONTEXT/worker-digest.md): P1 document-the-why (keep/repair the rationale next to any rule you fix); P3 verify-before-trust (read the actual current file and confirm each claimed problem still exists before editing — if already fixed or the claim is wrong, SKIP with a reason, never fabricate an edit); P14 (verification field quotes real before/after or command output).
Bans: no edits outside your named file set. No git commit/push. No file deletions (removing stale ENTRIES inside a file is fine where the fix list says so). No emojis. No line-number references in any doc text you write — cite sections/anchors/names. Surgical edits only; do not restructure or renumber documents.
Concurrency: other lanes are editing OTHER files right now. Touch only your named files.
Finish: StructuredOutput per schema.`

phase('Sweep')

const results = await parallel(
  args.lanes.map((l) => () =>
    agent(
      COMMON + '\n\nFILES: ' + (l.files || []).join(', ') + '\n\nFIXES:\n' + l.fixes,
      { label: 'sweep:' + l.key, phase: 'Sweep', schema: RESULT, model: 'sonnet' }
    ).then((r) => (r ? { lane: l.key, ...r } : { lane: l.key, status: 'blocked', summary: 'agent returned null', files_changed: [], verification: '' }))
  )
)

return { results }
