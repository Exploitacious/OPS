#!/usr/bin/env bash
# hooklib.sh: shared helpers for the OPS hooks. SOURCED, never executed.
#
# The hooks originally parsed their PreToolUse / compaction JSON payloads with
# an inline `python3 -c ...` heredoc. Windows (Git Bash) has NO `python3` shim
# (winget ships python.exe / py.exe only), so every such call resolved to 127
# and the surrounding `|| exit 0` silently DISABLED the hook: git-guard's hard
# gates, secrets-guard, and the compaction resume banner all became no-ops.
#
# hook_field replaces that with a portable extractor: jq first (a hard harness
# dependency, present on Windows AND Linux), then python3 / python / py. If NO
# parser is available it returns 2 so SECURITY callers can fail CLOSED instead
# of fail-open. It never depends on `python3` specifically.
#
# Usage:
#   RAW="$(cat)"
#   v="$(printf '%s' "$RAW" | hook_field tool_input.command)" || { no-parser }
# On success prints the (possibly empty) value and returns 0.
# Returns 2 when no JSON parser exists at all.

hook_field() {
  local path="$1" input out
  input="$(cat)"

  if command -v jq >/dev/null 2>&1; then
    if out="$(printf '%s' "$input" | jq -r --arg p "$path" '
        ($p | split(".")) as $parts
        | reduce $parts[] as $k (.; if type == "object" then .[$k] else null end)
        | if . == null then "" else (. | tostring) end' 2>/dev/null)"; then
      printf '%s' "$out"
      return 0
    fi
  fi

  local py
  for py in python3 python py; do
    if command -v "$py" >/dev/null 2>&1; then
      if out="$(printf '%s' "$input" | "$py" -c '
import json, sys
path = sys.argv[1].split(".")
try:
    d = json.load(sys.stdin)
except Exception:
    sys.stdout.write(""); sys.exit(0)
cur = d
for k in path:
    cur = cur.get(k) if isinstance(cur, dict) else None
    if cur is None:
        break
sys.stdout.write("" if cur is None else str(cur))' "$path" 2>/dev/null)"; then
        printf '%s' "$out"
        return 0
      fi
    fi
  done

  return 2
}

# Resolve a Python interpreter: python3 (Linux/macOS) then python / py (Windows
# has NO python3 shim). Prints the command name; returns 2 if none found. Used
# to run python-shebang'd helpers (e.g. bin/memory-index) portably instead of
# relying on the dead `#!/usr/bin/env python3` line on Windows.
hook_python() {
  # VERIFY each candidate actually reports "Python 3" before returning it: on
  # Windows `python3` is frequently a broken App-Execution-Alias stub that
  # resolves on PATH but errors (or opens the Store) when run. The version
  # probe falls through such a stub to the real `python` / `py`.
  local p v
  for p in python3 python py; do
    if command -v "$p" >/dev/null 2>&1; then
      v="$("$p" --version 2>&1)" || continue
      case "$v" in Python\ 3.*) printf '%s' "$p"; return 0 ;; esac
    fi
  done
  return 2
}

# hook_timeout: the timeout command a hook wraps a bounded call in. Prints
# gnutimeout when present, else timeout; returns 1 when neither exists.
# Why: on some hosts /usr/bin/timeout is the uutils build, which polls for its
# child's exit and adds about 100 ms to every call (measured: 106 ms for
# `timeout 3 true` against 5 ms for `gnutimeout 3 true`). Ubuntu ships GNU's
# build beside it as gnutimeout. Both take -k and a duration in seconds, and
# both exit 124 when the limit kills the command.
hook_timeout() {
  if command -v gnutimeout >/dev/null 2>&1; then printf gnutimeout; return 0; fi
  if command -v timeout >/dev/null 2>&1; then printf timeout; return 0; fi
  return 1
}

# Normalize a possibly-Windows path (drive letter, back/forward slashes) to a
# POSIX path bash can stat. Uses cygpath when present (Git Bash); otherwise
# prints the input unchanged (already POSIX on Linux/macOS).
hook_pathnorm() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -u "$1" 2>/dev/null || printf '%s' "$1"
  else
    printf '%s' "$1"
  fi
}

# Validate the two forms deploy creates: a symlink or a small import file.
# A filename mentioned in prose, a fenced example, or an import of a different
# checkout cannot prove boot. Match the real target, not just its basename.
hook_core_rule_matches() {
  local rule="$1" core="$2" expected resolved line imported=""
  local import_re='^([^[:space:]\\]|\\[[:space:]])+$'
  [ -f "$core" ] && [ -s "$core" ] && [ -r "$core" ] \
    && [ -f "$rule" ] && [ -r "$rule" ] || return 1
  expected="$(readlink -f "$core" 2>/dev/null)" || return 1
  [ -n "$expected" ] || return 1
  if [ -L "$rule" ]; then
    resolved="$(readlink -f "$rule" 2>/dev/null)" || return 1
  else
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%$'\r'}"
      case "$line" in
        ''|'#'*) continue ;;
        @*) [ -z "$imported" ] || return 1; imported="${line#@}" ;;
        *) return 1 ;;
      esac
    done < "$rule"
    # Claude ends imports at unescaped whitespace; quoting the path does not
    # escape it. Windows deploy normalizes slashes and escapes each space.
    [[ "$imported" =~ $import_re ]] || return 1
    imported="${imported//\\ / }"
    imported="$(hook_pathnorm "$imported")"
    case "$imported" in
      \~/*) imported="$HOME/${imported:2}" ;;
      /*) ;;
      *) imported="$(dirname "$rule")/$imported" ;;
    esac
    [ -f "$imported" ] && [ -r "$imported" ] || return 1
    resolved="$(readlink -f "$imported" 2>/dev/null)" || return 1
  fi
  [ "$resolved" = "$expected" ]
}

# work_session_key: the stable per-session key for session-scoped state files
# under ~/.claude-compact-cycle/ (session-start stamp, work-log; the directory
# name predates the retired tmux typer and is kept so existing state stays
# readable). The hooks (session-work-init, pre-compact, session-briefing) and
# the skills (session-close, pre-compact-synthesis) all derive the key here, so
# every surface agrees on one name for a session. Every input must be one a hook
# and a Bash tool call both see (Claude Code sets CLAUDE_CODE_SESSION_ID in the
# environment of hook and Bash subprocesses alike).
# DERIVATION ORDER (tmux, then T3 session id, then cwd):
#   tmux: the live session name, `tr ':. ' '---' | keep [A-Za-z0-9-]`, stable for
#     the life of the session, which is why session-work-init.sh registers LAST
#     at boot.
#   t3: under T3 Code every thread in one directory has the same cwd, so the cwd
#     key below made all of them share ONE stamp and ONE work-log: a thread opened
#     within the 7-day refresh window inherited an old t0, one work-log mixed
#     several threads (an elapsed time of a week), and one thread's session-close
#     deleted its siblings' stamp. CLAUDE_CODE_SESSION_ID is per thread, an env
#     read, and stable across /compact and resume, so the key is
#     t3-<id sanitized to [A-Za-z0-9-]>. Reached only once tmux is ruled out, by
#     asking ops_backend (below) so the two never disagree on what a T3 session
#     is. An in-process lane inherits its foreman's id, so a foreman and its lanes
#     share one stamp and work-log: one billing unit. An id with no
#     [A-Za-z0-9-] characters falls through to cwd rather than keying every such
#     session on a bare "t3-".
#   cwd: none of the above: the encoded cwd (the workspace-key convention) so a
#     bare session still keys deterministically. Prints the key; never fails.
work_session_key() {
  local raw
  if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
    raw="$(tmux display-message -p '#S' 2>/dev/null || true)"
    if [ -n "$raw" ]; then
      printf '%s' "$raw" | tr ':. ' '---' | tr -cd 'A-Za-z0-9-'
      return 0
    fi
  fi
  if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] && [ "$(ops_backend)" = t3code ]; then
    raw="$(printf '%s' "$CLAUDE_CODE_SESSION_ID" | tr -cd 'A-Za-z0-9-')"
    if [ -n "$raw" ]; then
      printf 't3-%s' "$raw"
      return 0
    fi
  fi
  printf '%s' "$(pwd)" | sed 's|/|-|g' | tr -cd 'A-Za-z0-9-'
}

# ops_backend: which session backend hosts this Claude process, one of
# tmux|t3code|bare. The single source of the backend verdict, so a key derivation
# and any other consumer agree on one answer.
# PRECEDENCE tmux, t3code, bare, and it is load-bearing: tmux is only real when the
# tmux BINARY is on PATH (TMUX can be inherited into a child that has no tmux
# client), and a tmux pane can inherit T3's markers, so T3 is trusted only once
# tmux is ruled out. T3 Code exports T3CODE_HOME from its service unit and
# T3CODE_THREAD_ID on every Claude launch; either marks a T3 thread. No external
# call except `command -v tmux`.
ops_backend() {
  if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
    printf 'tmux'
  elif [ -n "${T3CODE_HOME:-}" ] || [ -n "${T3CODE_THREAD_ID:-}" ]; then
    printf 't3code'
  else
    printf 'bare'
  fi
}

# ---------------------------------------------------------------------------
# Leftover session stamps: judged by evidence, off the boot path.
#
# session-work-init.sh writes ~/.claude-compact-cycle/session-start-<KEY> once
# per session and session-close deletes it, so a stamp that is still there after
# its session is gone marks a session that ended without a work-tracking
# reconciliation. Counting leftovers is not the check: a chat-only thread leaves
# one too, and under T3 every thread (and every delegated lane) leaves its own.
# So each leftover is judged by evidence, and judged PER REPO: it is flagged only
# when a repository it touched shows real commits in the stamp's own window.
#
#   quiet  nothing attributable (no boot repo and no work-log), no repository
#          with a .git directory among the repos it touched (a linked worktree
#          has a .git FILE and is a lane's or a task's checkout), or only
#          housekeeping commits in the window. Nothing is owed; no nag. A quiet
#          stamp is LEFT IN PLACE: nothing here deletes or moves a stamp.
#   flag   at least one repo with real commits in the window. The boot Hygiene
#          line names how many; session-close finishes the judgment, because a
#          hook has no work-tracking access and must never block boot on a
#          network call.
#
# The window. A stamp's end is the newest of its own mtime, its work-log mtime and,
# for a session that never compacted (no work-log), its transcript's mtime, capped
# at ORPHAN_WINDOW_CAP seconds (default 4 days) after t0 so a revived stamp cannot
# grow an unclearable window. The work-log, when it exists, wins outright: a
# transcript directory is keyed by cwd and shared by every session that ever ran
# there. Git evidence is day-grained (t0's day through the end day), and
# housekeeping commits (memory sync, closeout and lessons commits) are not work.
#
# COST. A fork costs 5 to 10 ms, so the cost of the judgment is its fork count: the
# stamp is read with builtins, the transcript mtimes of a directory come from one
# batched `stat` shared by every stamp of a scan, and the git evidence count is
# shared by every stamp with the same (repo, window). The _osv_* caches live only
# inside a scan; the public orphan_stamp_verdict resets them on every call.

# _osv_reset_caches: empty the per-scan caches (indexed arrays only: bash 3.2).
_osv_reset_caches() {
  _OSV_TXD=(); _OSV_TXM=()   # transcript dir -> newline-separated mtimes
  _OSV_GK=();  _OSV_GV=()    # repo+window key -> real-commit count
}

# _osv_tx_mtimes <dir>: sets _OSV_TXV to the newline-separated mtimes (epoch
# seconds) of the regular *.jsonl files directly in <dir>, cached per scan. Glob
# plus the builtin -f test plus ONE batched `stat` per 200 files (never `ls`, never
# one fork per file; 200 keeps the command line under the Windows Git Bash limit).
_osv_tx_mtimes() {
  local d="$1" i n f out
  local -a files=()
  n="${#_OSV_TXD[@]}"
  for ((i = 0; i < n; i++)); do
    if [ "${_OSV_TXD[$i]}" = "$d" ]; then _OSV_TXV="${_OSV_TXM[$i]}"; return 0; fi
  done
  for f in "$d"/*.jsonl; do [ -f "$f" ] && files[${#files[@]}]="$f"; done
  _OSV_TXV=""
  n="${#files[@]}"; i=0
  while [ "$i" -lt "$n" ]; do
    out="$(stat -c %Y -- "${files[@]:i:200}" 2>/dev/null)"
    [ -n "$out" ] && _OSV_TXV="${_OSV_TXV}${out}"$'\n'
    i=$((i + 200))
  done
  _OSV_TXD[${#_OSV_TXD[@]}]="$d"; _OSV_TXM[${#_OSV_TXM[@]}]="$_OSV_TXV"
  return 0
}

# _osv_git_real <repo> <since> <until>: sets _OSV_REAL to the number of
# non-housekeeping commits in the window, cached per scan on the exact key.
# Read git separately from counting: a pipeline can turn a failed git read into
# a successful zero from wc. A failed history read returns 1 and is never cached;
# zero work requires a complete read. Builtins count without extra processes.
_osv_git_real() {
  local r="$1" since="$2" untl="$3" key i n subjects subject
  local housekeeping_re='chore\(memory\)|chore\(close\)|docs\(lessons\)|docs\([a-z0-9-]*lessons\)'
  key="$r"$'\037'"$since"$'\037'"$untl"
  n="${#_OSV_GK[@]}"
  for ((i = 0; i < n; i++)); do
    if [ "${_OSV_GK[$i]}" = "$key" ]; then _OSV_REAL="${_OSV_GV[$i]}"; return 0; fi
  done
  if ! subjects="$(git -C "$r" log --since="$since" --until="$untl" --pretty='%s' 2>/dev/null)"; then
    _OSV_REAL=""
    return 1
  fi
  _OSV_REAL=0
  while IFS= read -r subject; do
    [ -n "$subject" ] || continue
    [[ "$subject" =~ $housekeeping_re ]] || _OSV_REAL=$((_OSV_REAL + 1))
  done <<< "$subjects"
  _OSV_GK[$n]="$key"; _OSV_GV[$n]="$_OSV_REAL"
  return 0
}

# _osv_verdict_into <stamp> [<stamp mtime>]: the classifier. Sets OSV_VERDICT
# (flag, quiet or error), OSV_REASON and OSV_REPOS with no subshell, so the caches
# survive across stamps. A caller that already holds the stamp's mtime passes it to
# skip a `stat`. Callers must have run _osv_reset_caches first. An unreadable
# record returns 1 with verdict=error, so a scan keeps the prior flags instead of
# guessing quiet.
_osv_verdict_into() {
  local st="$1" wl dir sbase t0="" boot_repo="" cwd="" line s_t0="" s_br="" s_cwd=""
  OSV_VERDICT=""; OSV_REASON=""; OSV_REPOS=""
  if [ ! -f "$st" ]; then OSV_VERDICT=quiet; OSV_REASON='stamp gone'; OSV_REPOS='-'; return 0; fi

  case "$st" in */*) dir="${st%/*}" ;; *) dir=. ;; esac
  sbase="${st##*/}"
  wl="$dir/work-log-${sbase#session-start-}"
  if [ ! -r "$st" ] || { [ -f "$wl" ] && [ ! -r "$wl" ]; }; then
    OSV_VERDICT=error; OSV_REASON="cannot read stamp or work-log for $sbase"; OSV_REPOS='-'
    return 1
  fi
  # First occurrence of each key wins (what `grep -m1 '^key='` returned).
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      started_at=*) [ -z "$s_t0" ]  && { t0="${line#*=}";        s_t0=1; } ;;
      boot_repo=*)  [ -z "$s_br" ]  && { boot_repo="${line#*=}"; s_br=1; } ;;
      cwd=*)        [ -z "$s_cwd" ] && { cwd="${line#*=}";       s_cwd=1; } ;;
    esac
  done 2>/dev/null < "$st"

  # No repo AND no work-log: nothing could be attributed.
  if [ -z "$boot_repo" ] || [ "$boot_repo" = "-" ]; then
    if [ ! -s "$wl" ]; then
      OSV_VERDICT=quiet; OSV_REASON='no boot repo and no work-log: nothing attributable'; OSV_REPOS='-'
      return 0
    fi
  fi

  local t_end t0_s t0_d end_d mt_st mt_wl mt_tx enc d m since untl dout repos r base nrep=0 real hits="" nl=$'\n' cfgd
  local ORPHAN_WINDOW_CAP="${ORPHAN_WINDOW_CAP:-345600}"
  mt_st="${2:-}"; [ -n "$mt_st" ] || mt_st="$(stat -c %Y "$st" 2>/dev/null || echo 0)"
  mt_wl=0; [ -s "$wl" ] && mt_wl="$(stat -c %Y "$wl" 2>/dev/null || echo 0)"
  # One `date` for both forms of t0 (epoch + day); a failure falls back to the
  # stamp mtime for the epoch and '?' for the day.
  dout="$(date -d "${t0:-@$mt_st}" '+%s %Y-%m-%d' 2>/dev/null)"
  if [ -n "$dout" ]; then t0_s="${dout% *}"; t0_d="${dout#* }"; else t0_s="$mt_st"; t0_d='?'; fi
  # Transcripts are the fallback for a session that never compacted, bounded to the
  # stamp's own plausible lifetime: one older than t0 belongs to an earlier session,
  # one past the cap to a later one. Glob + stat, never `ls`: an interactive profile
  # can alias ls to a long-format tool and `ls -t | head -1` then yields a LISTING
  # LINE instead of a path.
  mt_tx=0
  if [ ! -s "$wl" ] && [ -n "$cwd" ] && [ "$cwd" != "-" ]; then
    enc="${cwd//\//-}"
    for cfgd in "$HOME/.claude" "${CLAUDE_CONFIG_DIR:-}"; do
      [ -n "$cfgd" ] || continue
      d="$cfgd/projects/$enc"
      [ -d "$d" ] || continue
      _osv_tx_mtimes "$d"
      while IFS= read -r m; do
        [ -n "$m" ] || continue
        [ "$m" -lt "$t0_s" ] && continue
        [ "$m" -gt "$((t0_s + ORPHAN_WINDOW_CAP))" ] && continue
        [ "$m" -gt "$mt_tx" ] && mt_tx="$m"
      done <<< "$_OSV_TXV"
    done
  fi
  t_end="$mt_st"
  [ "$mt_wl" -gt "$t_end" ] && t_end="$mt_wl"
  [ "$mt_tx" -gt "$t_end" ] && t_end="$mt_tx"
  [ "$t_end" -gt "$((t0_s + ORPHAN_WINDOW_CAP))" ] && t_end="$((t0_s + ORPHAN_WINDOW_CAP))"
  end_d="$(date -d "@$t_end" +%Y-%m-%d 2>/dev/null || echo '?')"
  # Day-align the git window: work-tracking entries are day-grained, and whole days
  # also guarantee a same-minute stamp still sees its own day.
  since="${t0_d}T00:00:00"; untl="${end_d}T23:59:59"

  # Repos this stamp touched = boot repo + every repo= line in the work-log,
  # without blanks or "-", unique. `sort -u` only when there is more than one.
  local -a cands=("$boot_repo")
  if [ -f "$wl" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in repo=*) r="${line#repo=}"; cands[${#cands[@]}]="${r%% *}" ;; esac
    done 2>/dev/null < "$wl"
  fi
  repos=""
  for r in "${cands[@]}"; do
    case "$r" in ''|-) continue ;; esac
    case "$nl$repos$nl" in *"$nl$r$nl"*) continue ;; esac
    repos="${repos:+$repos$nl}$r"; nrep=$((nrep + 1))
  done
  [ "$nrep" -gt 1 ] && repos="$(printf '%s\n' "$repos" | sort -u)"
  if [ -z "$repos" ]; then
    OSV_VERDICT=quiet; OSV_REASON='no repo named by stamp or work-log'; OSV_REPOS='-'
    return 0
  fi

  while IFS= read -r r; do
    [ -n "$r" ] || continue
    base="${r%"${r##*[!/]}"}"; base="${base##*/}"   # basename without the fork
    [ -d "$r/.git" ] || continue
    if ! _osv_git_real "$r" "$since" "$untl"; then
      OSV_VERDICT=error; OSV_REASON="cannot read git history for $r in $t0_d..$end_d"; OSV_REPOS='-'
      return 1
    fi
    real="$_OSV_REAL"
    [ "${real:-0}" -gt 0 ] && hits="${hits:+$hits,}$base"
  done <<EOF
$repos
EOF

  if [ -n "$hits" ]; then
    OSV_VERDICT=flag; OSV_REASON="$t0_d..$end_d"; OSV_REPOS="$hits"
  else
    OSV_VERDICT=quiet; OSV_REASON="only housekeeping commits, or no commits, in $t0_d..$end_d"; OSV_REPOS='-'
  fi
  return 0
}

# orphan_stamp_verdict <stamp>: one TAB-separated line, <verdict>\t<reason>\t<repos|->.
# Pure and read-only, so the behavior tests can call it directly on fixtures.
orphan_stamp_verdict() {
  _osv_reset_caches
  _osv_verdict_into "$1"
  printf '%s\t%s\t%s\n' "$OSV_VERDICT" "$OSV_REASON" "$OSV_REPOS"
}

# ---------------------------------------------------------------------------
# The leftover-stamp SCAN: runs off the boot path.
#
# WHY. Judging every leftover stamp inline made boot grow with the set. A quiet or
# flag verdict never removes its stamp, and under T3 every thread that never runs
# session-close leaves one, so the set only grows: on one box 126 stamps cost 49 s
# of a 51 s boot, and every new session waits on the briefing hook before its first
# model call. The boot path now only checks a throttle and starts a detached scan;
# the scan does the sweep and leaves its result in the state dir:
#
#   orphan-flags         one stamp key per line for each stamp the last COMPLETE
#                        scan flagged (the boot report counts those whose stamp
#                        still exists, so closing a session clears its line at the
#                        next boot instead of after the next scan)
#   orphan-scan.status   state=running|ok|error plus started/finished/pid/runs/
#                        flagged/errors; replaced atomically
#   orphan-scan.error    present only when a status write or the launch failed
#   orphan-scan.lock[.d] flock file, or a mkdir lock where flock is missing
#
# Rules of the road:
#   - Throttle: at most one scan per OPS_ORPHAN_SCAN_INTERVAL seconds (1800), judged
#     by the `started` epoch in the status file, so a crashed scan retries after one
#     interval, not on every boot. The scan re-checks it under the lock, because
#     several sessions often boot in the same second: the first takes the lock, the
#     others find it held (or the throttle fresh) and exit quietly.
#   - Never silent: any failure (a state write failing, mtimes unreadable, the scan
#     dying) lands in the status file as state=error with the reason, and every later
#     boot says so in its Hygiene line until a scan passes. A scan that dies without
#     a word (kill -9) leaves state=running; the boot names it once it is older than
#     15 minutes.
#   - Never blocks boot: the scan is detached (own session where setsid exists,
#     stdio on /dev/null so the hook's pipe closes at once).
#   - Never removes or moves a stamp. The flags can be up to one interval old.
# OPS_ORPHAN_SCAN=sync runs the scan inline, bypassing the throttle: tests and a
# closeout that wants fresh flags use it. The default is background.

_osc_err() { OSCAN_ERRS="${OSCAN_ERRS:+$OSCAN_ERRS; }$1"; }

# _osc_read_status <state_dir>: loads orphan-scan.status into OSC_*; 1 when absent.
_osc_read_status() {
  local f="$1/orphan-scan.status" line
  OSC_STATE=""; OSC_STARTED=""; OSC_FINISHED=""; OSC_RUNS=""; OSC_FLAGGED=""; OSC_ERRORS=""
  [ -f "$f" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      state=*)    OSC_STATE="${line#*=}" ;;
      started=*)  OSC_STARTED="${line#*=}" ;;
      finished=*) OSC_FINISHED="${line#*=}" ;;
      runs=*)     OSC_RUNS="${line#*=}" ;;
      flagged=*)  OSC_FLAGGED="${line#*=}" ;;
      errors=*)   OSC_ERRORS="${line#*=}" ;;
    esac
  done 2>/dev/null < "$f"
  return 0
}

# _osc_write_status <state_dir> <state> <started> <finished> <runs> <flagged> <errors>
# Atomic (tmp + mv) so a boot never reads half a file. The errors field is one line,
# capped. A failed status write cannot report itself in that same file, so it keeps a
# separate error marker until a later status write succeeds; the marker's presence
# alone means failure.
_osc_write_status() {
  local f="$1/orphan-scan.status" tmp errs="$7" errf="$1/orphan-scan.error"
  errs="${errs//[$'\n\t\r']/ }"; errs="${errs:0:400}"
  tmp="$f.tmp.$$"
  # mv to a directory succeeds by moving inside it, which is not a status write.
  if [ ! -d "$f" ] && printf 'state=%s\nstarted=%s\nfinished=%s\npid=%s\nruns=%s\nflagged=%s\nerrors=%s\n' \
    "$2" "$3" "$4" "$$" "$5" "$6" "$errs" 2>/dev/null > "$tmp" && mv -f "$tmp" "$f" 2>/dev/null; then
    rm -f "$errf" 2>/dev/null
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  printf 'cannot write %s\n' "$f" 2>/dev/null > "$errf"
  return 1
}

# orphan_scan_due <state_dir>: 0 when a scan should run now (no status yet, an
# unreadable `started`, or the last scan started at least one interval ago).
orphan_scan_due() {
  local interval="${OPS_ORPHAN_SCAN_INTERVAL:-1800}" now
  _osc_read_status "$1" || return 0
  case "$OSC_STARTED" in ''|*[!0-9]*) return 0 ;; esac
  case "$interval" in ''|*[!0-9]*) interval=1800 ;; esac
  now="$(date +%s)"
  [ $((now - OSC_STARTED)) -ge "$interval" ]
}

# _osc_lock_acquire <state_dir>: 0 held, 1 another scan holds it, 2 cannot lock.
# flock where it exists (the kernel drops it when the scan dies, so no stale lock);
# a mkdir lock otherwise. Never steal from a live owner, regardless of age. Stale
# recovery is serialized INSIDE the lock directory and re-reads the owner there, so
# an earlier observation can never remove a new owner's lock. A PID-less lock older
# than 15 minutes needs manual recovery: its creator may still be initializing, so
# there is no owner whose death can be verified. rmdir, never rm -rf, keeps a
# competing recovery from erasing a new lock directory.
_osc_mkdir_claim() {
  local lockd="$1" pid="${BASHPID:-$$}"
  mkdir "$lockd" 2>/dev/null || return 1
  # Never overwrite an unexpected owner file, even if initialization was delayed.
  if ( set -C; printf '%s\n' "$pid" 2>/dev/null > "$lockd/pid" ) 2>/dev/null; then
    _OSC_LOCK=mkdir; _OSC_LOCK_PID="$pid"; return 0
  fi
  rmdir "$lockd" 2>/dev/null
  return 2
}

_osc_mkdir_stale() {
  local lockd="$1" owner=""
  [ -r "$lockd/pid" ] && read -r owner < "$lockd/pid" 2>/dev/null
  case "$owner" in
    ''|*[!0-9]*)
      [ -n "$(find "$lockd" -maxdepth 0 -mmin +15 2>/dev/null)" ] && return 2
      return 1 ;;
    *) ! kill -0 "$owner" 2>/dev/null ;;
  esac
}

_osc_lock_acquire() {
  local lock="$1/orphan-scan.lock" lockd="$1/orphan-scan.lock.d" rc pid="${BASHPID:-$$}"
  _OSC_LOCK=""; _OSC_LOCK_PID=""
  # OPS_ORPHAN_LOCK=mkdir forces the mkdir lock (the macOS / Git Bash path) on a box
  # that has flock, so a Linux test run can exercise it.
  if [ "${OPS_ORPHAN_LOCK:-}" != mkdir ] && command -v flock >/dev/null 2>&1; then
    { exec 9>>"$lock"; } 2>/dev/null || return 2
    flock -n 9 2>/dev/null; rc=$?
    if [ "$rc" -ne 0 ]; then
      exec 9>&-
      [ "$rc" = 1 ] && return 1   # conflict; other exit codes are lock failures
      return 2
    fi
    _OSC_LOCK=flock; return 0
  fi
  _osc_mkdir_claim "$lockd"; rc=$?
  [ "$rc" = 0 ] && return 0
  [ "$rc" = 2 ] && return 2
  [ -d "$lockd" ] || return 2
  _osc_mkdir_stale "$lockd"; rc=$?
  [ "$rc" = 0 ] || return "$rc"
  if ! mkdir "$lockd/reclaim" 2>/dev/null; then
    # A recovery interrupted while holding this guard needs attention, rather than
    # another unsafe recursive deletion of a possibly live owner's lock.
    [ -n "$(find "$lockd/reclaim" -maxdepth 0 -mmin +15 2>/dev/null)" ] && return 2
    return 1
  fi
  if ! _osc_mkdir_stale "$lockd"; then rmdir "$lockd/reclaim" 2>/dev/null; return 1; fi
  # Keep the directory in place and replace its dead owner under the guard.
  # Removing and recreating it leaves a PID-less gap in which contenders can strand
  # the recovery or remove a replacement lock.
  if ! { printf '%s\n' "$pid" 2>/dev/null > "$lockd/reclaim/pid" && mv -f "$lockd/reclaim/pid" "$lockd/pid" 2>/dev/null; }; then
    rm -f "$lockd/reclaim/pid" 2>/dev/null; rmdir "$lockd/reclaim" 2>/dev/null; return 2
  fi
  rmdir "$lockd/reclaim" 2>/dev/null || return 2
  _OSC_LOCK=mkdir; _OSC_LOCK_PID="$pid"; return 0
}

_osc_lock_release() {
  local owner="" lockd="$_OSC_STATE/orphan-scan.lock.d"
  case "$_OSC_LOCK" in
    flock) exec 9>&- ;;
    mkdir)
      [ -r "$lockd/pid" ] && read -r owner < "$lockd/pid" 2>/dev/null
      if [ "$owner" = "$_OSC_LOCK_PID" ]; then
        rm -f "$lockd/pid" 2>/dev/null && rmdir "$lockd" 2>/dev/null
      fi ;;
  esac
  _OSC_LOCK=""
}

# EXIT trap of a scan: if the scan did not reach its own final status write (an
# unexpected error, a signal), say so in the status file instead of leaving a stale
# state=running that nothing explains.
_osc_exit_trap() {
  local rc=$?
  if [ -z "$_OSC_DONE" ]; then
    _osc_write_status "$_OSC_STATE" error "$_OSC_STARTED" "$(date +%s)" "$_OSC_RUNS" 0 "scan exited early (rc=$rc) before finishing; flags are as the last good scan left them"
  fi
  _osc_lock_release
}

# orphan_scan_run <rundir> <state_dir> <cur_key>: ONE full sweep, called inside a
# scan process. Prints nothing; sets OSCAN_NFLAG and OSCAN_ERRS (semicolon-joined
# failures, empty when clean). Which stamps are judged:
#   - not this session's own (the key the caller derives);
#   - a stamp whose tmux session is still alive is not abandoned ("=" makes the
#     tmux name an exact match: a bare name prefix-matches another session);
#   - with no tmux to ask (a T3 thread, a plain terminal), only a stamp clearly
#     stale (over 18h) is judged.
# The flags file is rewritten only when the sweep ran to the end: a scan that could
# not read the stamps must not clear the last good flags.
orphan_scan_run() {
  local RUN="$1" STATE="$2" CUR="$3" st k raw mt _now line i n seen found nflag=0 flags="" ftmp
  local -a sts=() okst=() okmt=()
  OSCAN_NFLAG=0; OSCAN_ERRS=""
  _osv_reset_caches
  _now="$(date +%s)"
  if [ ! -r "$RUN" ] || [ ! -x "$RUN" ]; then
    _osc_err "cannot read stamps in $RUN; sweep skipped, flags unchanged"
    return 1
  fi

  # Every stamp's mtime in one batched stat (the 18h rule and the window both need
  # it); a stamp that vanishes before the stat drops out.
  for st in "$RUN"/session-start-*; do [ -e "$st" ] && sts[${#sts[@]}]="$st"; done
  n="${#sts[@]}"; i=0
  while [ "$i" -lt "$n" ]; do
    while IFS= read -r line; do
      okmt[${#okmt[@]}]="${line%% *}"; okst[${#okst[@]}]="${line#* }"
    done < <(stat -c '%Y %n' -- "${sts[@]:i:200}" 2>/dev/null)
    i=$((i + 200))
  done
  # A batch can return some mtimes while failing on another still-present stamp.
  # Replacing flags from that partial view would quietly drop unread evidence. Only
  # paths which actually vanished may be omitted from a completed sweep.
  for st in ${sts[@]+"${sts[@]}"}; do
    found=""
    for seen in ${okst[@]+"${okst[@]}"}; do [ "$seen" = "$st" ] && { found=1; break; }; done
    if [ -z "$found" ] && [ -e "$st" ]; then
      _osc_err "cannot read stamp mtimes in $RUN (GNU stat -c unavailable or failing); sweep skipped, flags unchanged"
      return 1
    fi
  done

  n="${#okst[@]}"
  for ((i = 0; i < n; i++)); do
    st="${okst[$i]}"; mt="${okmt[$i]}"
    k="${st##*/}"; k="${k#session-start-}"
    [ -n "$CUR" ] && [ "$k" = "$CUR" ] && continue
    raw=""
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in tmux=*) raw="${line#*=}"; break ;; esac
    done 2>/dev/null < "$st"
    if [ -n "$raw" ] && [ "$raw" != "-" ] && command -v tmux >/dev/null 2>&1; then
      tmux has-session -t "=$raw" 2>/dev/null && continue   # still alive: not abandoned
    else
      [ "$(( (_now - mt) / 3600 ))" -lt 18 ] && continue
    fi
    _osv_verdict_into "$st" "$mt"
    case "$OSV_VERDICT" in
      flag) nflag=$((nflag + 1)); [ "$nflag" -le 500 ] && flags="$flags$k"$'\n' ;;
      error) _osc_err "$OSV_REASON" ;;
    esac
  done
  OSCAN_NFLAG="$nflag"
  # An unreadable record can resemble an empty stamp: not a complete view of the
  # stamps, so the last good flags stay.
  [ -n "$OSCAN_ERRS" ] && return 1

  ftmp="$STATE/orphan-flags.tmp.$$"
  if [ ! -d "$STATE/orphan-flags" ] && printf '%s' "$flags" 2>/dev/null > "$ftmp" && mv -f "$ftmp" "$STATE/orphan-flags" 2>/dev/null; then :; else
    rm -f "$ftmp" 2>/dev/null; _osc_err "cannot write $STATE/orphan-flags"
  fi
  return 0
}

# orphan_scan_main <rundir> <state_dir> <cur_key> [force]: the scan process: lock,
# throttle re-check, sweep, status. Silent on stdout/stderr; its whole report is the
# state dir.
orphan_scan_main() {
  local RUN="$1" STATE="$2" CUR="$3" force="${4:-}" rc started finished runs state now
  [ -d "$RUN" ] || return 0
  cd / 2>/dev/null || true
  _OSC_STATE="$STATE"; _OSC_DONE=""; _OSC_STARTED=""; _OSC_RUNS=""; _OSC_LOCK=""
  _osc_lock_acquire "$STATE"; rc=$?
  if [ "$rc" -eq 1 ]; then return 0; fi   # another scan is running: its result is the result
  if [ "$rc" -ne 0 ]; then
    now="$(date +%s)"
    _osc_write_status "$STATE" error "$now" "$now" "" 0 "cannot take the scan lock in $STATE"
    return 1
  fi
  trap '_osc_exit_trap' EXIT
  if [ -z "$force" ] && ! orphan_scan_due "$STATE"; then _OSC_DONE=1; return 0; fi   # a scan finished just before this one got the lock

  _osc_read_status "$STATE"
  case "$OSC_RUNS" in ''|*[!0-9]*) runs=0 ;; *) runs="$OSC_RUNS" ;; esac
  runs=$((runs + 1)); started="$(date +%s)"
  _OSC_STARTED="$started"; _OSC_RUNS="$runs"
  if ! _osc_write_status "$STATE" running "$started" "" "$runs" 0 ""; then
    _OSC_DONE=1; return 1   # no sweep without a durable record that it started
  fi

  orphan_scan_run "$RUN" "$STATE" "$CUR"
  finished="$(date +%s)"
  if [ -n "$OSCAN_ERRS" ]; then state=error; else state=ok; fi
  if ! _osc_write_status "$STATE" "$state" "$started" "$finished" "$runs" "${OSCAN_NFLAG:-0}" "$OSCAN_ERRS"; then
    _OSC_DONE=1; return 1
  fi
  _OSC_DONE=1
  return 0
}

# orphan_scan_spawn <rundir> <state_dir> <cur_key> [bg|sync]: the ONLY orphan work on
# the boot path. Starts nothing when there are no stamps or the throttle says the last
# scan is fresh. A problem it can see right now (state dir not writable) goes to
# ORPHAN_SCAN_NOTE for the caller's Hygiene line. bg starts a detached scan; sync runs
# it inline and ignores the throttle.
orphan_scan_spawn() {
  local RUN="$1" STATE="$2" CUR="$3" mode="${4:-bg}" f any="" self rc
  ORPHAN_SCAN_NOTE=""
  if [ ! -r "$RUN" ] || [ ! -x "$RUN" ]; then
    ORPHAN_SCAN_NOTE="orphan-stamp scan not started: cannot read $RUN; flags unchanged"
    return 1
  fi
  for f in "$RUN"/session-start-*; do [ -e "$f" ] && { any=1; break; }; done
  if [ -z "$any" ]; then
    # No stamp left: nothing can be flagged, so clear any old flags.
    if [ -e "$STATE/orphan-flags" ] && ! rm -f "$STATE/orphan-flags" 2>/dev/null; then
      ORPHAN_SCAN_NOTE="orphan-stamp scan failed: cannot remove stale $STATE/orphan-flags"
      return 1
    fi
    return 0
  fi
  if ! mkdir -p "$STATE" 2>/dev/null || [ ! -w "$STATE" ]; then
    ORPHAN_SCAN_NOTE="orphan-stamp scan not started: cannot write $STATE"
    return 1
  fi
  if [ "$mode" = sync ]; then
    ( orphan_scan_main "$RUN" "$STATE" "$CUR" force )
    return $?
  fi
  orphan_scan_due "$STATE" || return 0
  self="${BASH_SOURCE[0]}"
  case "$self" in /*|?:*) ;; *) self="$PWD/$self" ;; esac
  # stdio to /dev/null lets the hook's pipe close while this supervisor waits.
  # Without it, a failed setsid/exec/source leaves no status and fails silently.
  # setsid -w also waits if setsid has to fork; ignore HUP for hosts without it.
  (
    trap '' HUP
    if command -v setsid >/dev/null 2>&1; then
      setsid -w "${BASH:-bash}" -c '. "$1" || exit; shift; orphan_scan_main "$@"' _ "$self" "$RUN" "$STATE" "$CUR"
    else
      "${BASH:-bash}" -c '. "$1" || exit; shift; orphan_scan_main "$@"' _ "$self" "$RUN" "$STATE" "$CUR"
    fi
    rc=$?
    if [ "$rc" -ne 0 ] && [ ! -e "$STATE/orphan-scan.error" ]; then
      printf 'scan process exited with rc=%s before completing successfully\n' "$rc" 2>/dev/null > "$STATE/orphan-scan.error"
    fi
  ) </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
  return 0
}

# orphan_scan_report <rundir> <state_dir> <cur_key>: what the boot says about the
# scan. Sets ORPHAN_SCAN_HYG to leading-space, " ·"-terminated Hygiene fragments
# ('' when clean): the count of flagged stamps that still exist (this session's own
# excluded), and a failed or vanished scan named every boot until a later scan
# passes.
orphan_scan_report() {
  local RUN="$1" STATE="$2" CUR="$3" k nflag=0 now detail
  ORPHAN_SCAN_HYG=""
  if [ -f "$STATE/orphan-flags" ]; then
    while IFS= read -r k || [ -n "$k" ]; do
      [ -n "$k" ] || continue
      [ -n "$CUR" ] && [ "$k" = "$CUR" ] && continue
      [ -e "$RUN/session-start-$k" ] && nflag=$((nflag + 1))
    done 2>/dev/null < "$STATE/orphan-flags"
  fi
  [ "$nflag" -gt 0 ] && ORPHAN_SCAN_HYG=" ${nflag} session(s) abandoned without a work-tracking reconciliation; work may be unlogged (run session-close to reconcile) ·"
  if [ -n "${ORPHAN_SCAN_NOTE:-}" ]; then
    ORPHAN_SCAN_HYG="$ORPHAN_SCAN_HYG $ORPHAN_SCAN_NOTE ·"
  elif [ -e "$STATE/orphan-scan.error" ]; then
    detail=""; IFS= read -r detail < "$STATE/orphan-scan.error" 2>/dev/null
    ORPHAN_SCAN_HYG="$ORPHAN_SCAN_HYG orphan-stamp scan failed: ${detail:-status or launch failure} (see $STATE/orphan-scan.error) ·"
  elif _osc_read_status "$STATE"; then
    case "$OSC_STATE" in
      error)
        ORPHAN_SCAN_HYG="$ORPHAN_SCAN_HYG orphan-stamp scan failed: ${OSC_ERRORS:-no detail} (see $STATE/orphan-scan.status) ·" ;;
      running)
        now="$(date +%s)"
        case "$OSC_STARTED" in ''|*[!0-9]*) ;; *)
          [ $((now - OSC_STARTED)) -ge 900 ] && \
            ORPHAN_SCAN_HYG="$ORPHAN_SCAN_HYG orphan-stamp scan started $(( (now - OSC_STARTED) / 60 ))m ago and never finished (see $STATE/orphan-scan.status) ·" ;;
        esac ;;
    esac
  fi
  return 0
}
