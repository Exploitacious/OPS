#!/usr/bin/env python3
"""transcript-usage.py: per-session token profile from Claude Code transcripts (metadata only,
never prints message text).

  transcript-usage.py --since 2026-09-05T00:00:00Z [--until ISO] [--hourly] [--gaps] ROOT [ROOT...]

One row per transcript file (main sessions and sub-agent lanes alike), deduped per API call by
message.id so streamed partials are not double counted. Columns: calls, input, cache_creation
(ccr, split c5 = 5-minute-TTL writes / c1h = 1-hour-TTL writes), cache_read (crd), output,
first-call cache_creation (a proxy for system prompt + tool schemas), max/median cache_read per
call, gaps > 5 min / > 60 min between calls, rewrite_after_gap (a > 50K write right after a > 5 min
gap: a cache-TTL miss that re-wrote the context). --hourly adds per-hour buckets. --gaps adds the
summary first used in a 2026-09-08 investigation of T3 Code token burn: writes after idle gaps,
context per call (median/p90) split main vs lane, active hours and per-active-hour means, top hours.
Roots are profile transcript dirs, e.g. ~/.claude/projects (a path under .claude-personal is
reported as profile "personal", anything else as "work").
Cost weighting used in that investigation (base-token equivalents): cache read 0.1, 5m write 1.25,
1h write 2, output 5. Test: tests/transcript-usage-test.py.
"""
import json, os, sys, argparse, statistics
from datetime import datetime, timezone

def parse_ts(s):
    try:
        return datetime.fromisoformat(s.replace('Z', '+00:00'))
    except Exception:
        return None

ap = argparse.ArgumentParser()
ap.add_argument('--since'); ap.add_argument('--until'); ap.add_argument('--hourly', action='store_true'); ap.add_argument('--gaps', action='store_true')
ap.add_argument('--min-turns', type=int, default=1)
ap.add_argument('roots', nargs='+')
a = ap.parse_args()
since = parse_ts(a.since) if a.since else None
until = parse_ts(a.until) if a.until else None

rows = []; hourly = {}
for root in a.roots:
    for dp, dn, fn in os.walk(root):
        for f in fn:
            if not f.endswith('.jsonl'): continue
            p = os.path.join(dp, f)
            seen = {}; order = []; models = {}; cwd = None; version = None; gitb = None
            sidechain = False; kinds = {}
            try:
                with open(p, 'r', errors='replace') as fh:
                    for line in fh:
                        try: e = json.loads(line)
                        except Exception: continue
                        t = e.get('type'); kinds[t] = kinds.get(t, 0) + 1
                        if e.get('isSidechain'): sidechain = True
                        cwd = e.get('cwd') or cwd; version = e.get('version') or version; gitb = e.get('gitBranch') or gitb
                        if t != 'assistant': continue
                        m = e.get('message') or {}; u = m.get('usage')
                        if not u: continue
                        ts = parse_ts(e.get('timestamp', '') or '')
                        if ts is None: continue
                        if since and ts < since: continue
                        if until and ts > until: continue
                        mid = m.get('id') or e.get('requestId') or e.get('uuid')
                        cc = u.get('cache_creation') or {}
                        rec = dict(ts=ts, inp=u.get('input_tokens', 0) or 0,
                                   ccr=u.get('cache_creation_input_tokens', 0) or 0,
                                   c5=cc.get('ephemeral_5m_input_tokens', 0) or 0,
                                   c1h=cc.get('ephemeral_1h_input_tokens', 0) or 0,
                                   crd=u.get('cache_read_input_tokens', 0) or 0,
                                   out=u.get('output_tokens', 0) or 0, model=m.get('model', '?'))
                        if mid not in seen: order.append(mid)
                        seen[mid] = rec  # last write wins (final usage of a streamed call)
            except Exception as ex:
                print(f'ERR {p}: {ex}', file=sys.stderr); continue
            turns = [seen[k] for k in order]
            if len(turns) < a.min_turns: continue
            for r in turns: models[r['model']] = models.get(r['model'], 0) + 1
            crd = [r['crd'] for r in turns]; ccr = [r['ccr'] for r in turns]
            # gaps > 5 min between consecutive calls (cache TTL exposure) and cache re-writes after them
            gaps5 = 0; gaps60 = 0; rewrite_after_gap = 0
            for i in range(1, len(turns)):
                d = (turns[i]['ts'] - turns[i-1]['ts']).total_seconds()
                if d > 300: gaps5 += 1
                if d > 3600: gaps60 += 1
                if d > 300 and turns[i]['ccr'] > 50000: rewrite_after_gap += 1
            rows.append(dict(
                file=p, profile=('personal' if '.claude-personal' in p else 'work'),
                kind=('subagent' if (sidechain or '/subagents/' in p or os.path.basename(p).startswith('agent-')) else 'main'),
                cwd=cwd, version=version, branch=gitb, calls=len(turns),
                first=turns[0]['ts'].isoformat(timespec='minutes'), last=turns[-1]['ts'].isoformat(timespec='minutes'),
                inp=sum(r['inp'] for r in turns), ccr=sum(ccr), c5=sum(r['c5'] for r in turns), c1h=sum(r['c1h'] for r in turns),
                crd=sum(crd), out=sum(r['out'] for r in turns),
                first_ccr=turns[0]['ccr'], first_crd=turns[0]['crd'], max_crd=max(crd), med_crd=int(statistics.median(crd)),
                gaps5=gaps5, gaps60=gaps60, rewrite_after_gap=rewrite_after_gap,
                models=','.join(f'{k}:{v}' for k, v in sorted(models.items(), key=lambda kv: -kv[1])),
                kinds=','.join(f'{k}:{v}' for k, v in sorted(kinds.items())),
            ))
            if a.hourly:
                for r in turns:
                    h = r['ts'].astimezone(timezone.utc).strftime('%Y-%m-%dT%H')
                    b = hourly.setdefault((h, ('personal' if '.claude-personal' in p else 'work')), dict(calls=0, ccr=0, crd=0, out=0, inp=0))
                    b['calls'] += 1; b['ccr'] += r['ccr']; b['crd'] += r['crd']; b['out'] += r['out']; b['inp'] += r['inp']

rows.sort(key=lambda r: -(r['ccr'] + r['crd'] + r['inp']))
tot = dict(files=len(rows), calls=sum(r['calls'] for r in rows), inp=sum(r['inp'] for r in rows), ccr=sum(r['ccr'] for r in rows),
           c5=sum(r['c5'] for r in rows), c1h=sum(r['c1h'] for r in rows), crd=sum(r['crd'] for r in rows), out=sum(r['out'] for r in rows))
print('TOTALS', json.dumps(tot))
for k in ('main', 'subagent'):
    sub = [r for r in rows if r['kind'] == k]
    if sub:
        print(f'KIND {k} files={len(sub)} calls={sum(r["calls"] for r in sub)} ccr={sum(r["ccr"] for r in sub)} crd={sum(r["crd"] for r in sub)} out={sum(r["out"] for r in sub)}')
print('file\tprofile\tkind\tcalls\tfirst\tlast\tinp\tccr\tc5\tc1h\tcrd\tout\tfirst_ccr\tfirst_crd\tmax_crd\tmed_crd\tgaps5\tgaps60\trewrite_after_gap\tmodels\tversion\tcwd\tkinds')
for r in rows:
    print('\t'.join(str(r[k]) for k in ('file','profile','kind','calls','first','last','inp','ccr','c5','c1h','crd','out','first_ccr','first_crd','max_crd','med_crd','gaps5','gaps60','rewrite_after_gap','models','version','cwd','kinds')))
if a.hourly:
    print('HOURLY hour\tprofile\tcalls\tinp\tccr\tcrd\tout')
    for (h, pr), b in sorted(hourly.items()):
        print(f'{h}\t{pr}\t{b["calls"]}\t{b["inp"]}\t{b["ccr"]}\t{b["crd"]}\t{b["out"]}')

if a.gaps:
    agg = {'main': dict(files=0, calls=0, ccr=0, gapw=0, gapw_calls=0, big=0), 'subagent': dict(files=0, calls=0, ccr=0, gapw=0, gapw_calls=0, big=0)}
    ctx = {'main': [], 'subagent': []}; hours = {}
    for root in a.roots:
        for dp, dn, fn in os.walk(root):
            for f in fn:
                if not f.endswith('.jsonl'): continue
                p = os.path.join(dp, f); seen = {}; order = []; side = False
                with open(p, errors='replace') as fh:
                    for line in fh:
                        try: e = json.loads(line)
                        except Exception: continue
                        if e.get('isSidechain'): side = True
                        if e.get('type') != 'assistant': continue
                        m = e.get('message') or {}; u = m.get('usage')
                        if not u: continue
                        t = parse_ts(e.get('timestamp', '') or '')
                        if not t or (since and t < since) or (until and t > until): continue
                        mid = m.get('id') or e.get('requestId') or e.get('uuid')
                        if mid not in seen: order.append(mid)
                        seen[mid] = (t, u.get('cache_creation_input_tokens', 0) or 0, u.get('cache_read_input_tokens', 0) or 0, u.get('output_tokens', 0) or 0)
                turns = [seen[k] for k in order]
                if not turns: continue
                kind = 'subagent' if (side or '/subagents/' in p or f.startswith('agent-')) else 'main'
                g = agg[kind]; g['files'] += 1; g['calls'] += len(turns)
                for i, (t, ccr, crd, out) in enumerate(turns):
                    g['ccr'] += ccr; ctx[kind].append(ccr + crd)
                    if ccr > 100000: g['big'] += 1
                    if i > 0 and (t - turns[i-1][0]).total_seconds() > 300 and ccr > 20000:
                        g['gapw'] += ccr; g['gapw_calls'] += 1
                    h = t.astimezone(timezone.utc).strftime('%m-%d %Hh'); b = hours.setdefault(h, dict(calls=0, ccr=0, crd=0, out=0))
                    b['calls'] += 1; b['ccr'] += ccr; b['crd'] += crd; b['out'] += out
    print('GAPS')
    for k, g in agg.items():
        c = sorted(ctx[k]); med = c[len(c)//2] if c else 0; p90 = c[int(len(c)*0.9)] if c else 0
        print(f"  {k}: files={g['files']} calls={g['calls']} ccr={g['ccr']} big_writes(>100K)={g['big']} writes_after_5min_gap={g['gapw']} ({g['gapw_calls']} calls, {100*g['gapw']/max(g['ccr'],1):.0f}% of ccr) ctx/call median={med} p90={p90}")
    act = [b for b in hours.values() if b['calls'] >= 20]
    print(f"  active hours (>=20 calls): {len(act)}")
    if act: print(f"  per-active-hour mean: calls={sum(b['calls'] for b in act)//len(act)} ccr={sum(b['ccr'] for b in act)//len(act)} crd={sum(b['crd'] for b in act)//len(act)} out={sum(b['out'] for b in act)//len(act)}")
    print('  top 5 hours by ccr+crd:')
    for h, b in sorted(hours.items(), key=lambda kv: -(kv[1]['ccr']+kv[1]['crd']))[:5]:
        print(f"    {h}Z calls={b['calls']} ccr={b['ccr']} crd={b['crd']} out={b['out']}")
