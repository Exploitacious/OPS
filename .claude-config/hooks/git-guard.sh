#!/usr/bin/env bash
# git-guard.sh: PreToolUse(Bash) hook: machine-enforces the doctrine's hard
# gates (how-i-work.md P3/P6) that used to be prose-only. Under the
# full-autonomy standing order (2026-07-06) no human sits between plan and
# merge, so the named bans must be mechanical:
#
#   BLOCKED (exit 2: Claude gets the reason and must surface to operator):
#     git ... --no-verify / --no-gpg-sign      (commit-hook bypass ban, P6)
#     git push --force / -f / --force-with-lease (history overwrite, P3)
#     git ... filter-branch / filter-repo       (history rewrite, P3)
#     git branch -D / push --delete on a remote (deleting possibly-unmerged
#                                                work; -d lowercase is safe)
#     rm -r/-f targeting protected roots        (~/OPS, ~/linuxploitacious,
#                                                ~/.claude as WHOLE trees)
#     bare tmux kill-server / pkill tmux        (kills every session on the
#                                                box, the Operator's included)
#     git push from an OPS copy whose origin    (would publish the Operator's
#       origin-private-check cannot prove private   memory and notes; see the
#       or to a remote other than origin           push gate at the end)
#
# NOT blocked: normal push/merge/commit (autonomy default), rebase of local
# unpushed work, rm inside scratch/tmp. Operator escape hatch for a
# deliberately-approved action: GIT_GUARD=off <command>  (or approve in chat
# and export for the one call). Read-only otherwise; exit 0 = allow.
set -uo pipefail

[ "${GIT_GUARD:-on}" = "off" ] && exit 0

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HOOK_DIR/hooklib.sh"

RAW_INPUT="$(cat)"
if ! TOOL="$(printf '%s' "$RAW_INPUT" | hook_field tool_name)"; then
  # No JSON parser (jq/python) available: cannot inspect the command. Fail
  # CLOSED: these are doctrine hard gates (P3/P6) that must NEVER silently
  # disable. On Windows the old `python3 -c` resolved to 127 and `|| exit 0`
  # turned every gate off: that is the exact bug this replaces.
  echo "git-guard: no JSON parser (jq/python) available: cannot verify command; BLOCKING." >&2
  echo "Install jq (a harness dependency), or prefix one approved command with GIT_GUARD=off." >&2
  exit 2
fi
[ "$TOOL" = "Bash" ] || exit 0
CMD="$(printf '%s' "$RAW_INPUT" | hook_field tool_input.command)"
[ -n "$CMD" ] || exit 0

# The documented escape hatch is an inline prefix on the approved command
# (`GIT_GUARD=off <command>`). Hooks run in their OWN process and never
# inherit inline assignments from the tool command, so the env check above
# can only fire if the whole Claude session exports it: honor the prefix
# by inspecting the command string itself. Anchored at the very start of
# the command ONLY, so an approval can't hide mid-pipeline or in a quoted
# string.
case "$CMD" in
  "GIT_GUARD=off "*) exit 0 ;;
esac

deny() {
  {
    echo "git-guard: BLOCKED: $1"
    echo "This is a doctrine hard gate (P3/P6): it requires the operator's explicit,"
    echo "per-action approval. Surface the need + reason to the operator; on approval,"
    echo "re-run the single command prefixed with GIT_GUARD=off."
    echo "If the operator is not actively responding in this session, send a"
    echo "PushNotification NOW naming this blocker and the decision needed: a blocked"
    echo "autonomous run must never wait silently (core.md § Intake, then autonomy)."
  } >&2
  exit 2
}

# git must sit at a command position (line start or after | ; & && ||, with
# optional env-var prefixes): prose that merely MENTIONS a banned flag inside
# a quoted string must not trip the guard. For the git checks we also strip
# quoted spans first (real git flags are never quoted; commit messages and
# echo strings are): the rm check below keeps the RAW string because rm
# targets legitimately appear quoted.
GITPOS='(^|[|;&][|&]?)[[:space:]]*([A-Z_]+=[^[:space:]]*[[:space:]]+)*(command[[:space:]]+)?git[[:space:]]'
CMD_RAW="$CMD"
CMD="$(printf '%s' "$CMD" | sed -e "s/'[^']*'//g" -e 's/"[^"]*"//g')"

if printf '%s' "$CMD" | grep -qE "${GITPOS}[^|;&]*(--no-verify|--no-gpg-sign)"; then
  deny "commit-hook bypass (--no-verify/--no-gpg-sign) is banned (P6 named ban)."
fi

if printf '%s' "$CMD" | grep -qE "${GITPOS}[^|;&]*push[^|;&]*(--force(-with-lease)?([[:space:]]|$|=)|[[:space:]]-f([[:space:]]|$))"; then
  deny "force push detected: history overwrite is operator-gated (P3)."
fi

if printf '%s' "$CMD" | grep -qE "${GITPOS}[^|;&]*(filter-branch|filter-repo)"; then
  deny "history rewrite (filter-branch/filter-repo) is operator-gated (P3)."
fi

if printf '%s' "$CMD" | grep -qE "${GITPOS}[^|;&]*push[^|;&]*(--delete|[[:space:]]:[^[:space:]])" \
   || printf '%s' "$CMD" | grep -qE "${GITPOS}[^|;&]*branch[^|;&]*[[:space:]]-D([[:space:]]|$)"; then
  deny "branch deletion (-D / push --delete) may destroy unmerged work: operator-gated (P3). Lowercase -d (merged-only) is allowed."
fi

# Protected-root rm: the home prefix may be $HOME, ~, a Linux /home/<user>, or
# a Git Bash /<drive>/Users/<user> form: Windows sessions must not slip past
# a pattern that only knows /home.
if printf '%s' "$CMD_RAW" | grep -qE '(^|[|;&][[:space:]]*)rm[[:space:]]+(-[a-zA-Z]*[rf][a-zA-Z]*[[:space:]]+)+("?\$HOME"?|~|/home/[a-z]+|/[a-zA-Z]/[Uu]sers/[^/]+)/?(OPS|linuxploitacious|\.claude)?("|/)?([[:space:]]|$)'; then
  deny "recursive/forced rm aimed at a protected root tree (OPS / linuxploitacious / .claude): operator-gated."
fi

# tmux server protection: a bare `tmux kill-server`: or pkill/killall aimed
# at tmux: takes down EVERY tmux session on the box, including the one the
# Operator's own Claude runs in. Test cleanups must target their sandbox
# server EXPLICITLY on the same command line (`tmux -S <socket> kill-server` /
# `tmux -L <name> kill-server`); an env var set in an earlier Bash call does
# NOT persist and silently retargets the default socket. Explicit -S/-L forms
# pass; the bare form and tmux-wide pkill/killall are blocked.
if printf '%s' "$CMD" | grep -qE '(^|[|;&][[:space:]]*)tmux[[:space:]]+((-f|-c)[[:space:]]+[^[:space:]]+[[:space:]]+)*kill-server' \
   && ! printf '%s' "$CMD" | grep -qE '(^|[|;&][[:space:]]*)tmux[[:space:]]+[^|;&]*-(S|L)[[:space:]]*[^[:space:]]+[^|;&]*kill-server'; then
  deny "bare 'tmux kill-server' kills EVERY session on the box. Target your sandbox explicitly: tmux -S <socket> kill-server."
fi
if printf '%s' "$CMD_RAW" | grep -qE '(^|[|;&][[:space:]]*)(pkill|killall)[[:space:]][^|;&]*tmux'; then
  deny "pkill/killall tmux kills every session on the box: kill your own server via tmux -S <socket> kill-server."
fi

# --- Push gate for an OPS copy -------------------------------------------------
# An OPS copy holds the Operator's memory, context and notes, and agents are told
# to commit and push it (batons, the memory mirror, direct-to-trunk work). A copy
# whose origin is public (a tryout clone of the template, a public fork, a repo
# made public by mistake) would publish all of it. The unattended pushes
# (daily-sync.sh, memory-init) already go through bin/origin-private-check; an
# instruction in a skill is prose an agent can skip, so agent pushes go through
# the same gate here. "An OPS copy" is a repo whose root holds
# .claude-config/bin/origin-private-check; pushes in any other repo (the project
# clones under PROJECTS/) are untouched. A push from an OPS copy is blocked
# unless that copy's own gate exits 0 AND prints its private verdict as its last
# line (an empty or truncated gate also exits 0), and unless it goes to origin,
# the only remote the gate verifies.
#
# Each git command's directory is resolved the way the shell would: from the
# hook's cwd, cd/pushd/popd, subshells, `git -C` and `--git-dir`, through
# env/command/rtk/sudo/timeout prefixes, `bash -c` and `eval`, and git aliases
# read as data. Python 3 only tokenizes the command; nothing is executed. Without
# Python 3, or on a command it cannot tokenize, a push is checked against every
# directory the command names (the cwd, each `-C` and `cd`/`pushd` operand):
# coarser, so it can stop a push in another repo when the same command also
# names an OPS copy that is not verified, but it never skips one. Not covered:
# a push hidden in a script file, a variable, or a computed command.
OPS_GATE_REL=".claude-config/bin/origin-private-check"

# The gate's own private verdict lines; daily-sync.sh and memory-init carry the
# same test (gate_proved); keep the three in step.
push_gate_proved() {
  case "${1##*$'\n'}" in
    "origin-private-check: private: "?*) return 0 ;;
    "origin-private-check: private by opt-in (ops.pushVerified=true): "?*) return 0 ;;
  esac
  return 1
}

# push_records <cwd>: NUL-separated records "base gitdir count word..." for every
# git command in $CMD_RAW, or the single record ERROR. The command reaches Python
# on stdin, never as an argument: Linux caps one argument at 128 KiB, and a long
# heredoc command must not turn into an uninspectable one.
push_records() {
  local py boot
  py="$(hook_python)" || { printf 'ERROR\0'; return; }
  boot="import sys; p, c, tail = sys.stdin.buffer.read().split(b'\\0'); tail and sys.exit('unexpected bytes after command terminator'); raw = c.decode('utf-8', 'surrogateescape'); exec(compile(p, 'git-guard-push', 'exec'))"
  { cat <<'PYCODE' &&
import os, posixpath, re, shlex, subprocess, sys
cwd = sys.argv[1]

def path(p, base):
    p = os.path.expandvars(posixpath.expanduser(p))
    if os.name == "nt" and re.match(r"^[A-Za-z]:[/\\]", p):
        p = subprocess.check_output(["cygpath", "-u", p], text=True).strip()
    return posixpath.normpath(p if posixpath.isabs(p) else posixpath.join(base, p))

def native_path(p):
    if os.name == "nt":
        return subprocess.check_output(["cygpath", "-w", p], text=True).strip()
    return p

def emit(base, gd, words):
    for v in [base, gd, str(len(words)), *words]:
        sys.stdout.buffer.write(v.encode("utf-8", "surrogateescape") + b"\0")

def heredocs(text):
    # Here-document bodies are stdin data, not command lines.
    lines = text.splitlines(keepends=True)
    result, bodies = [], {}
    pattern = re.compile(r"""(?<!<)<<(-?)\s*(?:'([^']+)'|"([^"]+)"|([A-Za-z_][A-Za-z_0-9]*))""")
    i = 0
    while i < len(lines):
        line = lines[i]; i += 1
        def unquoted(offset):
            quote, escaped = "", False
            for c in line[:offset]:
                if escaped: escaped = False; continue
                if c == "\\" and quote != "'": escaped = True; continue
                if c == quote: quote = ""
                elif not quote and c in "\"'": quote = c
            return not quote
        for m in [m for m in pattern.finditer(line) if unquoted(m.start())]:
            delim = next(x for x in m.groups()[1:] if x is not None)
            body = []
            while i < len(lines) and lines[i].rstrip("\r\n").lstrip("\t" if m[1] else "") != delim:
                body.append(lines[i]); i += 1
            if i == len(lines):
                raise ValueError("unterminated here-document")
            i += 1
            key = "__push_stdin_" + str(len(bodies))
            bodies[key] = "".join(body)
            line = line.replace(m[0], "<< " + key, 1)
        result.append(line)
    return "".join(result), bodies

def commands(text, base, inherited=None, depth=0):
    if depth > 8:
        raise ValueError("shell wrapper nesting exceeds the inspection limit")
    text, bodies = heredocs(text)
    lex = shlex.shlex(text.replace("\\\n", ""), posix=True, punctuation_chars=";&|(){}\n<>")
    lex.whitespace = " \t\r"
    lex.wordchars += "~$./:-="
    seg, stack, dirs = [], [], []
    env = dict(inherited or {})
    for token in list(lex) + [";"]:
        if token and all(c in ";&|(){}\n" for c in token):
            if seg:
                base = command(seg, base, env, dirs, depth, bodies)
                seg = []
            for c in token:
                if c == "(": stack.append(base)
                elif c == ")" and stack: base = stack.pop()
        else:
            seg.append(token)

def command(words, base, inherited, dirs, depth, bodies):
    shell_base = base
    env = dict(inherited)
    w, stdin = [], []
    i = 0
    while i < len(words):
        if words[i] and all(c in "<>" for c in words[i]):
            if i + 1 < len(words) and words[i+1] in bodies:
                stdin.append(bodies[words[i+1]])
            if w and w[-1].isdigit(): w.pop()
            i += 2
        else:
            w.append(words[i]); i += 1
    while w:
        prog = os.path.basename(w[0])
        if re.match(r"^[A-Za-z_][A-Za-z_0-9]*=", w[0]):
            k, v = w.pop(0).split("=", 1); env[k] = v
            continue
        if prog in ("if", "then", "else", "elif", "do", "while", "until", "!", "{", "}"):
            w.pop(0); continue
        if prog in ("env", "command", "builtin", "exec", "nohup", "time", "nice", "sudo", "xargs", "rtk", "timeout"):
            w.pop(0)
            while w and w[0].startswith("-"):
                opt = w.pop(0)
                if opt == "--": break
                if opt in ("-u", "-n", "-I", "-g", "-s", "-k", "--signal", "--kill-after", "-C", "--chdir") and w:
                    val = w.pop(0)
                    if prog == "env" and opt in ("-C", "--chdir"): base = path(val, base)
                elif prog == "env" and opt.startswith("--chdir="):
                    base = path(opt.split("=", 1)[1], base)
            if prog == "timeout" and w: w.pop(0)
            continue
        break
    if not w: return base
    prog = os.path.basename(w.pop(0))
    if prog in ("bash", "sh", "zsh", "dash", "ksh"):
        for i, arg in enumerate(w):
            if arg.startswith("-") and "c" in arg and i + 1 < len(w):
                commands(w[i+1], base, env, depth+1); break
        else:
            for body in stdin: commands(body, base, env, depth+1)
    elif prog == "eval":
        commands(" ".join(w), base, env, depth+1)
    elif prog in ("cd", "pushd"):
        args = [x for x in w if x not in ("--", "-P", "-L")]
        dest = path(args[0] if args else "~", base)
        if os.path.isdir(native_path(dest)):
            if prog == "pushd": dirs.append(base)
            return dest
    elif prog == "popd" and dirs:
        return dirs.pop()
    elif prog in ("git", "git.exe"):
        gd = env.get("GIT_DIR", "")
        aliases, config = {}, []
        while w and w[0].startswith("-"):
            opt = w.pop(0)
            if opt in ("-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--super-prefix", "--config-env"):
                val = w.pop(0) if w else ""
            elif opt.startswith("-C") and len(opt) > 2: opt, val = "-C", opt[2:]
            elif opt.startswith("-c") and not opt.startswith("--") and len(opt) > 2: opt, val = "-c", opt[2:]
            elif "=" in opt: opt, val = opt.split("=", 1)
            else: continue
            if opt == "-C": base = path(val, base)
            elif opt == "--git-dir": gd = val
            elif opt == "-c":
                config += ["-c", val]
                if val.startswith("alias.") and "=" in val:
                    name, value = val[6:].split("=", 1); aliases[name] = value
        if gd: gd = path(gd, base)
        builtins = set("commit push merge rebase reset cherry-pick revert am pull update-ref switch stash checkout branch tag worktree symbolic-ref add config status diff log show rev-parse fetch ls-files blame merge-base remote describe update-index".split())
        # Aliases are read as data, never run: `git p` for push is still a push.
        for _ in range(8):
            if not w or w[0] in builtins: break
            value = aliases.get(w[0])
            if value is None:
                args = ["git", "-C", native_path(base)]
                if gd: args.append("--git-dir=" + native_path(gd))
                result = subprocess.run(args + config + ["config", "--get", "alias." + w[0]],
                                        env=dict(os.environ, **env), stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, text=True, timeout=5)
                value = result.stdout.strip() if result.returncode == 0 else ""
            if not value: break
            w.pop(0)
            if value.startswith("!"):
                if gd: env["GIT_DIR"] = gd
                commands(value[1:], base, env, depth+1)
                return shell_base
            w = shlex.split(value) + w
        else:
            raise ValueError("git alias nesting exceeds the inspection limit")
        if w: emit(base, gd, ["git", *w])
    return shell_base

try:
    commands(raw, cwd)
except (ValueError, IndexError, OSError, subprocess.SubprocessError) as e:
    print("git-guard: cannot inspect shell command: " + str(e), file=sys.stderr)
    sys.stdout.buffer.write(b"ERROR\0")
PYCODE
    printf '\0%s\0' "$CMD_RAW"
  } | "$py" -c "$boot" "$1" 2>/dev/null || printf 'ERROR\0'
}

# push_remote_ok <root> <push args...>: 0 when the push goes to origin. An
# explicit repository argument (or --repo) must be "origin"; with none, git's
# own default applies: branch pushRemote, then remote.pushDefault, then the
# branch's remote, then origin.
push_remote_ok() {
  local root="$1" a remote="" br r; shift
  while [ "$#" -gt 0 ]; do
    a="$1"; shift
    case "$a" in
      --) [ "$#" -gt 0 ] && remote="$1"; break ;;
      --repo=*) remote="${a#--repo=}"; break ;;
      --repo) remote="${1:-}"; break ;;
      -o|--push-option|--receive-pack|--exec) [ "$#" -gt 0 ] && shift ;;
      -*) ;;
      *) remote="$a"; break ;;
    esac
  done
  if [ -z "$remote" ]; then
    br="$(git -C "$root" symbolic-ref --short -q HEAD 2>/dev/null)"
    for r in ${br:+"branch.$br.pushRemote"} remote.pushDefault ${br:+"branch.$br.remote"}; do
      remote="$(git -C "$root" config --get "$r" 2>/dev/null)" && [ -n "$remote" ] && break
      remote=""
    done
  fi
  PUSH_REMOTE="${remote:-origin}"
  [ "$PUSH_REMOTE" = origin ]
}

# ops_push_check <root> resolved|coarse [push args...]: deny unless the OPS copy
# at <root> is proven private and, for a resolved push, the push goes to
# origin. The coarse fallback cannot tie arguments to a repo, so it checks only
# the gate. Each root's gate runs once per command.
OPS_PUSH_SEEN=$'\n'
ops_push_check() {
  local root="$1" mode="$2" reason rc=0; shift 2
  if [ "$mode" = resolved ] && ! push_remote_ok "$root" "$@"; then
    deny "push from the OPS copy at $root goes to '$PUSH_REMOTE', not origin: the push gate verifies origin only, so push this copy to origin."
  fi
  case "$OPS_PUSH_SEEN" in *$'\n'"$root"$'\n'*) return 0 ;; esac
  OPS_PUSH_SEEN="$OPS_PUSH_SEEN$root"$'\n'
  reason="$(bash "$root/$OPS_GATE_REL" "$root" 2>&1 >/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    deny "push from the OPS copy at $root: origin is not verified private. ${reason:-origin-private-check printed nothing (exit $rc)}"
  fi
  if ! push_gate_proved "$reason"; then
    deny "push from the OPS copy at $root: $OPS_GATE_REL exited 0 without its private verdict (${reason:-no output}), so it is empty or truncated; restore it from the template."
  fi
}

# repo_root <dir> [gitdir]: the work-tree root a git command in <dir> acts on.
repo_root() {
  if [ -n "${2:-}" ]; then git -C "$1" --git-dir="$2" rev-parse --show-toplevel 2>/dev/null
  else git -C "$1" rev-parse --show-toplevel 2>/dev/null; fi
}

PUSH_CWD="$(printf '%s' "$RAW_INPUT" | hook_field cwd)"; [ -n "$PUSH_CWD" ] || PUSH_CWD="$PWD"
PUSH_CWD="$(hook_pathnorm "$PUSH_CWD")"
# The word "git" must appear for any git command to run; skip the parse otherwise.
case "$CMD_RAW" in *git*)
  PUSH_FALLBACK=0
  while IFS= read -r -d '' base; do
    if [ "$base" = ERROR ]; then PUSH_FALLBACK=1; break; fi
    IFS= read -r -d '' gd && IFS= read -r -d '' count || { PUSH_FALLBACK=1; break; }
    words=()
    for ((i = 0; i < count; i++)); do IFS= read -r -d '' word || { PUSH_FALLBACK=1; break 2; }; words+=("$word"); done
    [ "${words[1]:-}" = push ] || continue
    root="$(repo_root "$base" "$gd")" || continue
    [ -n "$root" ] && [ -f "$root/$OPS_GATE_REL" ] || continue
    ops_push_check "$root" resolved "${words[@]:2}"
  done < <(push_records "$PUSH_CWD")
  if [ "$PUSH_FALLBACK" = 1 ] \
     && printf '%s' "$CMD" | grep -qE '(^|[|;&(][|&]?)[[:space:]]*([A-Z_]+=[^[:space:]]*[[:space:]]+)*((command|env|rtk|sudo|nohup|time|nice|exec)[[:space:]]+)*([^[:space:]]*/)?git[[:space:]][^|;&]*push'; then
    # Coarse fallback (see above): every directory the command names.
    dirs=("$PUSH_CWD")
    while IFS= read -r w; do
      w="$(printf '%s' "$w" | sed -E 's/^[[:space:];&|(]?(-C|cd|pushd)[[:space:]]+//')"
      w="${w#[\"\']}"; w="${w%[\"\']}"
      case "$w" in "~"|"~/"*) w="$HOME${w#\~}" ;; '$HOME'*) w="$HOME${w#\$HOME}" ;; '${HOME}'*) w="$HOME${w#\$\{HOME\}}" ;; esac
      case "$w" in /*) ;; *) w="$PUSH_CWD/$w" ;; esac
      dirs+=("$w")
    done < <(printf '%s' "$CMD_RAW" | grep -oE '(-C|(^|[[:space:];&|(])(cd|pushd))[[:space:]]+("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:];&|)]+)')
    for d in "${dirs[@]}"; do
      [ -d "$d" ] || continue
      root="$(repo_root "$d")" || continue
      [ -n "$root" ] && [ -f "$root/$OPS_GATE_REL" ] || continue
      ops_push_check "$root" coarse
    done
  fi
;; esac

exit 0
