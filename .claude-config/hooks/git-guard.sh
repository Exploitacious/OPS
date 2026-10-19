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
# .claude-config/bin/origin-private-check (or a linked worktree of one); pushes in
# any other repo (the project clones under PROJECTS/) are untouched. A push from
# an OPS copy is blocked unless that copy's own gate exits 0 AND prints its
# private verdict as its last line (an empty or truncated gate also exits 0), and
# unless it goes to origin, the only remote the gate verifies.
#
# What it is: a seatbelt for the pushes an agent makes while following normal
# instructions, not a sandbox against an agent trying to get round it. It aims
# for no false blocks, every common form caught, and a fail-safe check whenever
# it cannot follow a command. Each git command's repo is resolved the way the
# shell and git would: from the hook's cwd, cd (with cd - and cd chains),
# pushd/popd, subshells, `git -C` (physically, so a symlink then `..` lands where
# git lands), `--git-dir`, GIT_DIR, variables assigned in the same command,
# env/command/sudo/timeout/xargs/nohup prefixes, rtk and its command-running
# subcommands, `bash -c` (and -lc, never --norc or --rcfile), eval, scripts fed
# to a shell through a heredoc, a here-string or a pipe, $(...) and backticks
# (quoted or not), and git aliases read as data. Redirections (2>&1, &>/dev/null,
# >&2) are not arguments, so they never read as the remote. Python 3 tokenizes
# the command and reads Git config and repository paths. Those reads use the
# hook's trusted git and environment, with only Git's config inputs forwarded;
# a command's PATH or LD_PRELOAD must never choose code the hook executes.
#
# Also blocked on an OPS copy: a push carrying `-c`, `--config-env` or
# GIT_CONFIG_* settings that can move it (remote.*, url.*, push.*, includes,
# branch.<b>.remote or .pushRemote), plumbing pushes (send-pack, http-push,
# subtree push, lfs push), and a push in the same command as a change to where
# pushes go (git remote add/set-url, git config remote.*/url.*/ops.pushVerified,
# an upstream change): the gate runs before the command, so its verdict would be
# stale. Run the change, then push in a separate command.
#
# Fail-safe: without Python 3, when a command cannot be tokenized, or when a
# directory cannot be resolved (a loop variable, a computed path), the check
# falls back to the raw command, quotes kept: if it holds a push or send-pack
# word (or the name of a copy's own push alias), every OPS copy it touches (the
# cwd, and every directory named anywhere in it, chained through earlier ones) is
# checked against its gate. Coarser: it can stop a push in another repo when the
# command also names an OPS copy that is not verified, never the reverse.
#
# Not parsed (documented limits): exotic wrappers (setsid, stdbuf, flock, doas,
# su -c, ssh, script -c, find -exec, python -c and the like), a push inside a
# script file run by path or `source`, commands built at run time, and
# environment that points git at other config files (HOME, XDG_CONFIG_HOME). The
# real protection is a private origin; this hook catches the slip. The
# template's own development checkout is itself an OPS copy whose origin is
# public, so contributors push PR branches with the documented GIT_GUARD=off
# prefix after checking the branch carries no private content (CONTRIBUTING.md).
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

# push_records <cwd>: NUL-separated records "base gitdir unresolved override
# count word..." for every git command in $CMD_RAW, or the single record ERROR.
# unresolved is 1 when the repo could not be resolved and the command may push
# (the caller then runs the fail-safe check); override names a setting the
# command carries that can move a push. The command reaches Python on stdin,
# never as an argument: Linux caps one argument at 128 KiB, and a long heredoc
# command must not turn into an uninspectable one.
push_records() {
  local py boot
  py="$(hook_python)" || { printf 'ERROR\0'; return; }
  boot="import sys; p, c, tail = sys.stdin.buffer.read().split(b'\\0'); tail and sys.exit('unexpected bytes after command terminator'); raw = c.decode('utf-8', 'surrogateescape'); exec(compile(p, 'git-guard-push', 'exec'))"
  { cat <<'PYCODE' &&
import itertools, os, posixpath, re, shlex, shutil, subprocess, sys
cwd = sys.argv[1]
KEYS = itertools.count()  # one numbering for every lifted here-document body
# The git that reads aliases comes from the hook's own PATH, resolved once: a
# PATH or LD_PRELOAD the command sets must never choose code the hook runs.
GIT = shutil.which("git") or "git"
SUBST = re.compile(r"__push_subst_\d+__")
VAR = re.compile(r"\$(?:\{([A-Za-z_][A-Za-z_0-9]*)\}|([A-Za-z_][A-Za-z_0-9]*)|([0-9@*#?$!-]))")
ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z_0-9]*=")
OPS_RE = re.compile(r"<<<|<<-|<<|<>|<&|>&|>>|>\||&>>|&>|<\(|>\(|\|\||\|&|&&|;;&|;;|;&|[;&|()\n<>]")
REDIRECTS = {"<", ">", ">>", "<<", "<<-", "<<<", "<>", "<&", ">&", ">|", "&>", "&>>"}
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
KEYWORDS = {"if", "then", "else", "elif", "do", "while", "until", "!", "{", "}"}
# Prefixes that run the rest of the line as a command, with the options of each
# that take a separate value (so the value is not read as the program).
WRAPPERS = {
    "env": {"-u", "--unset", "-C", "--chdir", "-S", "--split-string"},
    "sudo": {"-u", "--user", "-g", "--group", "-h", "--host", "-p", "--prompt", "-C", "-D", "--chdir", "-r", "-t", "-T", "-U"},
    "xargs": {"-I", "-n", "-s", "-L", "-P", "-d", "-a", "-E", "--max-args", "--max-procs", "--delimiter", "--arg-file", "--max-chars", "--max-lines"},
    "timeout": {"-s", "-k", "--signal", "--kill-after"},
    "nice": {"-n", "--adjustment"}, "time": {"-f", "--format", "-o", "--output"}, "exec": {"-a"},
    "command": set(), "builtin": set(), "nohup": set(),
}
PUSHLIKE = {"push", "send-pack", "http-push", "subtree", "lfs"}
# Real git commands: git never lets an alias shadow one, so these skip the
# alias lookup, and an unresolved repo running one of them cannot be pushing.
BUILTINS = set("""commit merge rebase reset cherry-pick revert am pull update-ref switch stash
checkout branch tag worktree symbolic-ref add config status diff log show rev-parse fetch
ls-files blame merge-base remote describe update-index init clone gc ls-remote mv rm
restore grep shortlog notes clean submodule sparse-checkout bisect range-diff format-patch
apply reflog cat-file hash-object ls-tree for-each-ref show-ref name-rev var help version
maintenance count-objects fsck prune repack write-tree read-tree commit-tree mktree
verify-commit rerere archive bundle fast-export replace check-ignore check-attr diff-tree
diff-index diff-files rev-list whatchanged""".split())
# Aliases cannot shadow these publishing builtins either: alias.push=status
# must never make a real `git push` disappear from the inspection.
BUILTINS.update(("push", "send-pack", "http-push"))

def native_path(p):
    if os.name == "nt":
        return subprocess.check_output(["cygpath", "-w", p], text=True).strip()
    return p

def expand(word, sh):
    # $NAME / ${NAME} from variables this command assigned, then the hook's
    # environment; None when anything stays unknown (a loop variable, $(...)).
    if word is None or SUBST.search(word) or "`" in word:
        return None
    unknown = []
    def var(m):
        name = m.group(1) or m.group(2)
        if name:
            if name in sh["vars"]:
                if sh["vars"][name] is None: unknown.append(name)
                return sh["vars"][name] or ""
            if name in os.environ: return os.environ[name]
        elif m.group(3).isdigit() and 0 < int(m.group(3)) <= len(sh["pos"]):
            return sh["pos"][int(m.group(3)) - 1]
        unknown.append(m.group(0)); return m.group(0)
    out = VAR.sub(var, word)
    if unknown or "${" in out: return None
    return posixpath.expanduser(out) if out.startswith("~") else out

def path(p, base, sh, physical=False):
    p = expand(p, sh)
    if p is None or re.search(r"[*?\[]", p): return None
    if os.name == "nt" and re.match(r"^[A-Za-z]:[/\\]", p):
        p = subprocess.check_output(["cygpath", "-u", p], text=True).strip()
    if not posixpath.isabs(p):
        if base is None: return None
        p = posixpath.join(base, p)
    # cd is logical, as the shell's is; git -C and --git-dir chdir physically,
    # so x/link/.. lands beside the link's target, not beside the link.
    if physical and os.name != "nt": return os.path.realpath(p)
    return posixpath.normpath(p)

def emit(base, gd, unresolved, override, words):
    for v in [base or "", gd or "", "1" if unresolved else "0", override, str(len(words)), *words]:
        sys.stdout.buffer.write(v.encode("utf-8", "surrogateescape") + b"\0")

def ansi_c(s):
    table = {"n": "\n", "t": "\t", "r": "\r", "a": "\a", "b": "\b", "e": "\x1b", "E": "\x1b", "f": "\f", "v": "\v"}
    def one(m):
        e = m.group(1)
        if e[0] == "x": return chr(int(e[1:], 16))
        if e[0] in "01234567": return chr(int(e, 8) & 0xFF)
        return table.get(e, e)
    return re.sub(r"\\(x[0-9A-Fa-f]{1,2}|[0-7]{1,3}|.)", one, s)

def heredocs(text):
    # Here-document bodies are stdin data, not command lines. An unquoted
    # delimiter still expands $(...) in the body; quoted ones keep it literal.
    lines = text.splitlines(keepends=True)
    result, bodies, quoted = [], {}, set()
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
            if delim.startswith("__push_stdin_"): continue  # lifted out by an enclosing pass
            body = []
            while i < len(lines) and lines[i].rstrip("\r\n").lstrip("\t" if m[1] else "") != delim:
                body.append(lines[i]); i += 1
            if i == len(lines):
                raise ValueError("unterminated here-document")
            i += 1
            key = "__push_stdin_%d" % next(KEYS)
            bodies[key] = "".join(body)
            if m[2] is not None or m[3] is not None: quoted.add(key)
            line = line.replace(m[0], "<< " + key, 1)
        result.append(line)
    return "".join(result), bodies, quoted

HEREDOC = re.compile(r"""<<(-?)\s*(?:'([^']+)'|"([^"]+)"|([A-Za-z_][A-Za-z_0-9]*))""")

def close_paren(text, i):
    # Index of the ")" that closes a "$(" whose body starts at i. Here-document
    # bodies inside it are skipped, so the apostrophe in a commit message
    # written as "$(cat <<'EOF' ... EOF)" is text, not an open quote.
    depth, quote, n, pending = 1, None, len(text), []
    while i < n:
        c = text[i]
        if quote == "'":
            if c == "'": quote = None
            i += 1; continue
        if c == "\\": i += 2; continue
        if quote is None and text.startswith("<<", i) and not text.startswith("<<<", i):
            m = HEREDOC.match(text, i)
            if m:
                delim = next(x for x in m.groups()[1:] if x is not None)
                if not delim.startswith("__push_stdin_"):  # not one heredocs() already lifted out
                    pending.append((delim, m[1] == "-"))
                i = m.end(); continue
        if quote is None and c == "\n" and pending:
            i += 1
            for delim, strip in pending:
                while True:
                    if i >= n: raise ValueError("unterminated here-document")
                    k = text.find("\n", i); k = n if k < 0 else k
                    line = text[i:k].rstrip("\r")
                    i = k + 1
                    if (line.lstrip("\t") if strip else line) == delim: break
            pending = []; continue
        if text.startswith("$(", i): i = close_paren(text, i + 2) + 1; continue
        if c == "`":
            j = text.find("`", i + 1)
            if j < 0: raise ValueError("unterminated backquote")
            i = j + 1; continue
        if quote == '"':
            if c == '"': quote = None
        elif c in "'\"": quote = c
        elif c == "(": depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0: return i
        i += 1
    raise ValueError("unterminated command substitution")

def prescan(text, subs):
    # One quote-aware pass before shlex, which cannot see these: $(...) and
    # backticks (quoted or not) become placeholders whose bodies are parsed as
    # commands, $'...' becomes a plain quoted word, comments go, and the fd
    # number of a redirection (2>&1) goes so it never reads as an argument.
    out, i, n, quote, start = [], 0, len(text), None, True
    def placeholder(body):
        key = "__push_subst_%d__" % len(subs); subs[key] = body; return key
    while i < n:
        c = text[i]
        if quote == "'":
            out.append(c); i += 1
            if c == "'": quote = None
            continue
        if c == "\\" and i + 1 < n:
            out.append(text[i:i + 2]); i += 2; start = False; continue
        if text.startswith("$(", i):
            j = close_paren(text, i + 2)
            out.append(placeholder(text[i + 2:j])); i = j + 1; start = False; continue
        if c == "`":
            j = i + 1
            while j < n and text[j] != "`": j += 2 if text[j] == "\\" else 1
            if j >= n: raise ValueError("unterminated backquote")
            out.append(placeholder(re.sub(r"\\([`$\\])", r"\1", text[i + 1:j]))); i = j + 1; start = False; continue
        if quote is None:
            if c == "#" and start:
                j = text.find("\n", i); i = n if j < 0 else j; continue
            if text.startswith("$'", i):
                j, body = i + 2, []
                while j < n and text[j] != "'":
                    body.append(text[j:j + 2] if text[j] == "\\" else text[j]); j += 2 if text[j] == "\\" else 1
                if j >= n: raise ValueError("unterminated $'...' string")
                out.append("'" + ansi_c("".join(body)).replace("'", "'\\''") + "'"); i = j + 1; start = False; continue
            if c.isdigit() and start:
                j = i
                while j < n and text[j].isdigit(): j += 1
                if j < n and text[j] in "<>": i = j; start = False; continue
            if c in "'\"": quote = c
        elif c == '"':
            quote = None
        out.append(c); i += 1
        start = quote is None and c in " \t\r\n;&|()<>"
    if quote: raise ValueError("unterminated quote")
    return "".join(out)

def substitutions(body):
    # $(...) and backticks in an unquoted here-document body.
    found, i = [], 0
    while i < len(body):
        if body[i] == "\\": i += 2; continue
        if body.startswith("$(", i):
            j = close_paren(body, i + 2); found.append(body[i + 2:j]); i = j + 1; continue
        if body[i] == "`":
            j = body.find("`", i + 1)
            if j < 0: raise ValueError("unterminated backquote")
            found.append(body[i + 1:j]); i = j + 1; continue
        i += 1
    return found

def tokens(text):
    lex = shlex.shlex(text, posix=True, punctuation_chars=";&|()\n<>")
    lex.whitespace, lex.whitespace_split, lex.commenters = " \t\r", True, ""
    out = []
    for t in lex:
        if t and all(c in ";&|()\n<>" for c in t):
            out += [("op", o) for o in OPS_RE.findall(t)]
        else:
            out.append(("w", t))
    return out

def shell(base, parent=None, env=None):
    sh = {"base": base, "oldpwd": None, "dirs": [], "vars": {}, "exported": set(), "pos": [], "push_override": "", "git_config": []}
    if parent:
        sh.update(oldpwd=parent["oldpwd"], vars=dict(parent["vars"]), exported=set(parent["exported"]), pos=list(parent["pos"]), push_override=parent["push_override"], git_config=list(parent["git_config"]))
    for k, v in (env or {}).items():
        sh["vars"][k] = v; sh["exported"].add(k)
    return sh

def commands(text, sh, depth, outer=({}, set())):
    # outer: the enclosing text's here-document bodies, which a $(...) body
    # can still name (x=$(cat <<EOF ... EOF) is lifted before the $(...) is).
    if depth > 8:
        raise ValueError("shell wrapper nesting exceeds the inspection limit")
    text, bodies, quoted = heredocs(text)
    bodies, quoted = {**outer[0], **bodies}, outer[1] | quoted
    subs = {}
    text = prescan(text.replace("\\\n", ""), subs)
    seg, stack, piped = [], [], None
    for kind, t in tokens(text) + [("op", ";")]:
        if kind == "op" and t not in REDIRECTS:
            out = command(seg, sh, depth, bodies, quoted, subs, piped) if seg else None
            seg = []
            piped = out if t in ("|", "|&") else None
            if t in ("(", "<(", ">("):
                stack.append((sh["base"], sh["oldpwd"], list(sh["dirs"]), dict(sh["vars"]), set(sh["exported"])))
            elif t == ")" and stack:
                sh["base"], sh["oldpwd"], sh["dirs"], sh["vars"], sh["exported"] = stack.pop()
        else:
            seg.append((kind, t))

def command(seg, sh, depth, bodies, quoted, subs, piped):
    # Returns what the command writes to a pipe when that is knowable (echo,
    # printf, cat of a here-document), so `... | bash` parses it as a script.
    base = sh["base"]
    for kind, t in seg:
        for key in SUBST.findall(t):
            commands(subs[key], shell(base, sh), depth + 1, (bodies, quoted))
    env, w, stdin, i = {}, [], list(piped or []), 0
    while i < len(seg):
        kind, t = seg[i]
        if kind == "op":
            arg = seg[i + 1][1] if i + 1 < len(seg) and seg[i + 1][0] == "w" else None
            if arg is not None and t in ("<<", "<<-") and arg in bodies:
                stdin.append(bodies[arg])
                if arg not in quoted:
                    for inner in substitutions(bodies[arg]): commands(inner, shell(base, sh), depth + 1)
            elif arg is not None and t == "<<<":
                stdin.append(arg)
            i += 2
            continue
        if t in ("$@", "$*"): w += sh["pos"]
        else: w.append(t)
        i += 1
    while w:
        if ASSIGN.match(w[0]):
            k, v = w.pop(0).split("=", 1); env[k] = expand(v, sh); continue
        prog = posixpath.basename(w[0])
        if prog in KEYWORDS:
            w.pop(0); continue
        if prog in WRAPPERS:
            w.pop(0)
            while w and w[0].startswith("-"):
                opt = w.pop(0)
                if opt == "--": break
                if opt in WRAPPERS[prog] and w:
                    val = w.pop(0)
                    if (prog, opt) in (("env", "-C"), ("env", "--chdir"), ("sudo", "-D"), ("sudo", "--chdir")): base = path(val, base, sh)
                    if prog == "env" and opt in ("-S", "--split-string"): w = shlex.split(val) + w
                elif prog in ("env", "sudo") and opt.startswith("--chdir="):
                    base = path(opt.split("=", 1)[1], base, sh)
            if prog == "timeout" and w: w.pop(0)
            continue
        if prog == "rtk":
            # rtk git ..., and the subcommands that run a command: run/err/
            # summary/test/bypass/proxy take argv, or a string with -c/--shell.
            w.pop(0)
            while w and w[0].startswith("-"): w.pop(0)
            if w and w[0] in ("run", "err", "summary", "test", "bypass", "proxy"):
                w.pop(0); script, as_shell = None, False
                while w and w[0].startswith("-"):
                    opt = w.pop(0)
                    if opt == "--": break
                    if opt in ("-c", "--command") and w: script = w.pop(0)
                    elif opt.startswith("--command="): script = opt.split("=", 1)[1]
                    elif opt == "--shell" and w: w.pop(0); as_shell = True
                    elif opt.startswith("--shell="): as_shell = True
                if script is None and as_shell and w: script = w.pop(0)
                if script is not None:
                    commands(script, shell(base, sh, env), depth + 1)
                    return None
            continue
        break
    if not w:
        for k, v in env.items(): sh["vars"][k] = v
        return None
    prog = posixpath.basename(w.pop(0))
    if prog == "export":
        for a in w:
            k, eq, v = a.partition("=")
            if ASSIGN.match(a): sh["vars"][k] = expand(v, sh)
            if re.match(r"^[A-Za-z_][A-Za-z_0-9]*$", k): sh["exported"].add(k)
    elif prog in ("echo", "printf"):
        args = w if prog == "printf" else [a for a in w if not re.match(r"^-[neE]+$", a)]
        return [ansi_c(" ".join(args))]
    elif prog == "cat" and not w:
        return stdin
    elif prog in SHELLS:
        # Only a real -c (alone or in a cluster such as -lc) takes the command
        # string, which is the first operand after the options; --norc and
        # --rcfile are long options, and -o/-O/--rcfile/--init-file take a value.
        c_flag = s_flag = False; i = 0
        while i < len(w):
            a = w[i]
            if a == "--": i += 1; break
            if a in ("-o", "+o", "-O", "+O", "--rcfile", "--init-file"): i += 2; continue
            if a.startswith("--"): i += 1; continue
            if len(a) > 1 and a[0] in "-+":
                if a[0] == "-": c_flag |= "c" in a[1:]; s_flag |= "s" in a[1:]
                i += 1; continue
            break
        rest, child = w[i:], shell(base, sh, env)
        if c_flag:
            if rest:
                child["pos"] = rest[2:]
                commands(rest[0], child, depth + 1)
        elif s_flag or not rest:
            for body in stdin: commands(body, shell(base, child), depth + 1)
    elif prog == "eval":
        commands(" ".join(w), sh, depth + 1)
    elif prog in ("cd", "pushd"):
        args = [x for x in w if x != "--"]
        physical = "-P" in args
        args = [x for x in args if x not in ("-P", "-L", "-e", "-@")]
        if not args: dest = path("~", base, sh) if prog == "cd" else None
        elif args[0] == "-": dest = sh["oldpwd"]
        else: dest = path(args[0], base, sh, physical)
        if dest is not None and not os.path.isdir(native_path(dest)):
            return None
        if prog == "pushd": sh["dirs"].append(base)
        sh["oldpwd"], sh["base"] = base, dest
    elif prog == "popd" and sh["dirs"]:
        sh["oldpwd"], sh["base"] = base, sh["dirs"].pop()
    elif prog in ("git", "git.exe"):
        git(w, base, sh, env, depth)
    return None

def push_override(key):
    k = key.lower()
    # An included config can set any push destination even when the include
    # key itself does not mention a remote. The gate never saw that config.
    return k.startswith(("remote.", "url.", "push.", "include.", "includeif.")) or (k.startswith("branch.") and k.rsplit(".", 1)[-1] in ("remote", "pushremote"))

def git(w, base, sh, env, depth):
    genv = {k: v for k, v in sh["vars"].items() if k in sh["exported"]}
    genv.update(env)
    unresolved = base is None
    gd, kv, override = "", list(sh["git_config"]), sh["push_override"]
    # Config reads are data-only. Forward exactly the config inputs, never
    # PATH, LD_PRELOAD, GIT_EXEC_PATH, or other command execution settings.
    config_env = dict(os.environ)
    # GIT_CONFIG affects only `git config`, not Git's own alias lookup. Letting
    # it replace this read could hide a real push alias behind an empty file.
    config_env.pop("GIT_CONFIG", None)
    for k, v in genv.items():
        if v is not None and (k in ("GIT_CONFIG_PARAMETERS", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_CONFIG_COUNT", "GIT_CONFIG_NOSYSTEM") or re.fullmatch(r"GIT_CONFIG_(KEY|VALUE)_\d+", k)):
            config_env[k] = v
    for k in ("GIT_CONFIG_PARAMETERS", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_CONFIG"):
        if k in genv: override = override or k + " in the environment"
    if "GIT_CONFIG_COUNT" in genv:
        try: count = int(genv["GIT_CONFIG_COUNT"] or "")
        except ValueError: count, override = 0, override or "GIT_CONFIG_COUNT in the environment"
        kv += [(genv.get("GIT_CONFIG_KEY_%d" % n) or "", genv.get("GIT_CONFIG_VALUE_%d" % n)) for n in range(count)]
    if "GIT_DIR" in genv:
        gd = path(genv["GIT_DIR"], base, sh, True) if genv["GIT_DIR"] is not None else None
        unresolved |= gd is None
    for _ in range(8):
        # A non-shell alias may itself begin with global options. Parse them
        # on every expansion, as Git does, before deciding what command runs.
        while w and w[0].startswith("-"):
            opt, val = w.pop(0), None
            if opt in ("-C", "-c", "--git-dir", "--work-tree", "--namespace", "--super-prefix", "--config-env"):
                val = w.pop(0) if w else ""
            elif opt.startswith("-C") and len(opt) > 2: opt, val = "-C", opt[2:]
            elif opt.startswith("-c") and not opt.startswith("--") and len(opt) > 2: opt, val = "-c", opt[2:]
            elif opt.startswith("--") and "=" in opt: opt, val = opt.split("=", 1)
            else: continue
            if opt == "-C":
                base = path(val, base, sh, True); unresolved |= base is None
            elif opt == "--git-dir":
                gd = path(val, base, sh, True); unresolved |= gd is None
            elif opt == "-c":
                k, eq, v = val.partition("="); kv.append((k, v if eq else "true"))
            elif opt == "--config-env":
                k, eq, name = val.partition("=")
                kv.append((k, genv.get(name, os.environ.get(name)) if eq else None))
        bad = [k for k, v in kv if push_override(k)]
        if bad: override = override or "-c " + bad[0]
        aliases = {k[6:].lower(): v for k, v in kv if k.lower().startswith("alias.") and v}
        config_args = [arg for k, v in kv if v is not None for arg in ("-c", k + "=" + v)]
        if not w or w[0] in BUILTINS: break
        value = aliases.get(w[0].lower())
        if value is None and not unresolved:
            args = [GIT, "-C", native_path(base)] + (["--git-dir=" + native_path(gd)] if gd else []) + config_args
            result = subprocess.run(args + ["config", "--get", "alias." + w[0]], stdout=subprocess.PIPE,
                                    stderr=subprocess.DEVNULL, text=True, timeout=5, env=config_env)
            value = result.stdout.strip() if result.returncode == 0 else ""
        if not value: break
        w.pop(0)
        if value.startswith("!"):
            # git runs a shell alias as `sh -c '<alias> "$@"'` with the call's arguments.
            # Its cwd is the work-tree root, not the caller's subdirectory.
            # Relative -C/cd in the alias must reach the same repo Git reaches.
            alias_base = base
            if not unresolved:
                args = [GIT, "-C", native_path(base)] + (["--git-dir=" + native_path(gd)] if gd else []) + config_args
                result = subprocess.run(args + ["rev-parse", "--show-toplevel"], stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, text=True, timeout=5, env=config_env)
                if result.returncode == 0:
                    alias_base = path(result.stdout.rstrip("\n"), base, sh, True)
            child = shell(alias_base, sh, genv)
            # Git also exports its -c/--config-env settings to shell aliases.
            # Keep a destination override attached to every nested git call;
            # otherwise alias.publish='!git push' silently lost this check.
            child["push_override"] = override
            child["git_config"] = list(kv)
            if gd: child["vars"]["GIT_DIR"] = gd; child["exported"].add("GIT_DIR")
            child["pos"] = list(w)
            commands(value[1:] + ' "$@"', child, depth + 1)
            return
        w = shlex.split(value) + w
    else:
        raise ValueError("git alias nesting exceeds the inspection limit")
    if not w: return
    w = [x if x.startswith("-") else (expand(x, sh) or x) for x in w]
    maybe_push = w[0] in PUSHLIKE or w[0] not in BUILTINS
    emit(base, gd, unresolved and maybe_push, override, ["git", *w])

try:
    commands(raw, shell(cwd), 0)
except Exception as e:
    print("git-guard: cannot inspect shell command: " + str(e), file=sys.stderr)
    sys.stdout.buffer.write(b"ERROR\0")
PYCODE
    printf '\0%s\0' "$CMD_RAW"
  } | "$py" -c "$boot" "$1" 2>/dev/null || printf 'ERROR\0'
}

# Each record's repo is acted on through the context below: its --git-dir when
# the command named one, else its work tree.
PG_ROOT="" PG_GD=""
pg_git() { if [ -n "$PG_GD" ]; then git --git-dir="$PG_GD" "$@"; else git -C "$PG_ROOT" "$@"; fi; }

# push_remote_ok <push args...>: 0 when the push goes to origin. An explicit
# repository argument (or --repo) must be "origin"; with none, git's own default
# applies: branch pushRemote, then remote.pushDefault, then the branch's remote,
# then origin. A remote the parser could not resolve (a variable, a $(...)) is
# not origin.
push_remote_ok() {
  local a remote="" br r
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
    br="$(pg_git symbolic-ref --short -q HEAD 2>/dev/null)"
    for r in ${br:+"branch.$br.pushRemote"} remote.pushDefault ${br:+"branch.$br.remote"}; do
      remote="$(pg_git config --get "$r" 2>/dev/null)" && [ -n "$remote" ] && break
      remote=""
    done
  fi
  PUSH_REMOTE="${remote:-origin}"
  case "$PUSH_REMOTE" in
    *'$'*|*__push_subst_*|*'`'*) PUSH_REMOTE="$PUSH_REMOTE (a variable or command substitution the guard cannot resolve; name the remote literally)"; return 1 ;;
  esac
  [ "$PUSH_REMOTE" = origin ]
}

# ops_push_check <root> <gate-root> resolved|coarse [push args...]: deny unless
# the OPS copy is proven private by the gate at <gate-root> and, for a resolved
# push, the push goes to origin. The fail-safe path cannot tie arguments to a
# repo, so it checks only the gate. Each gate runs once per command.
OPS_PUSH_SEEN=$'\n'
ops_push_check() {
  local root="$1" gate_root="$2" mode="$3" reason rc=0; shift 3
  if [ "$mode" = resolved ] && ! push_remote_ok "$@"; then
    deny "push from the OPS copy at $root goes to '$PUSH_REMOTE', not origin: the push gate verifies origin only, so push this copy to origin."
  fi
  case "$OPS_PUSH_SEEN" in *$'\n'"$gate_root"$'\n'*) return 0 ;; esac
  OPS_PUSH_SEEN="$OPS_PUSH_SEEN$gate_root"$'\n'
  reason="$(bash "$gate_root/$OPS_GATE_REL" "$root" 2>&1 >/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    deny "push from the OPS copy at $root: origin is not verified private. ${reason:-origin-private-check printed nothing (exit $rc)}"
  fi
  if ! push_gate_proved "$reason"; then
    deny "push from the OPS copy at $root: $OPS_GATE_REL exited 0 without its private verdict (${reason:-no output}), so it is empty or truncated; restore it from the template."
  fi
}

# repo_root <dir> [gitdir]: the physical work-tree root of the repo a git
# command acts on. With a git dir, that is the git dir's own work tree (git
# rev-parse --show-toplevel would answer with the cwd instead); a bare repo has
# none and fails.
repo_root() {
  local base="$1" gd="${2:-}" wt=""
  if [ -z "$gd" ]; then git -C "$base" rev-parse --show-toplevel 2>/dev/null; return; fi
  [ -d "$gd" ] || return 1
  if [ -f "$gd/commondir" ] && [ -f "$gd/gitdir" ]; then
    wt="$(cat "$gd/gitdir")"; wt="${wt%/.git}"
  elif wt="$(git --git-dir="$gd" config --get core.worktree 2>/dev/null)" && [ -n "$wt" ]; then
    case "$wt" in /*) ;; *) wt="$gd/$wt" ;; esac
  elif [ "${gd##*/}" = .git ]; then
    wt="${gd%/.git}"
  else
    return 1
  fi
  (cd "$wt" 2>/dev/null && pwd -P)
}

# ops_root <root>: the root whose gate guards <root>, or exit 1 for a repo that
# is not an OPS copy. A linked worktree checked out at a commit without the gate
# still shares the copy's remotes, so it falls back to the main work tree's gate.
ops_root() {
  local root="$1" common
  if [ -f "$root/$OPS_GATE_REL" ]; then printf '%s' "$root"; return 0; fi
  [ -f "$root/.git" ] || return 1
  common="$(git -C "$root" rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$common" in /*) ;; *) common="$root/$common" ;; esac
  [ "${common##*/}" = .git ] || return 1
  common="$(cd "$common/.." 2>/dev/null && pwd -P)" || return 1
  [ -f "$common/$OPS_GATE_REL" ] || return 1
  printf '%s' "$common"
}

# is_push <subcommand> <args...>: a git command that publishes commits.
is_push() {
  local sub="$1" a; shift
  case "$sub" in
    push|send-pack|http-push) return 0 ;;
    subtree|lfs) for a in "$@"; do [ "$a" = push ] && return 0; done ;;
  esac
  return 1
}

# changes_push_config <subcommand> <args...>: a git command that changes where a
# later push goes, or whether the gate passes.
changes_push_config() {
  local sub="$1" a rc=1; shift
  case "$sub" in
    remote) case "${1:-}" in add|set-url|rename|remove|rm|set-branches) return 0 ;; esac ;;
    config)
      for a in "$@"; do
        case "$a" in --get|--get-all|--get-regexp|--get-urlmatch|-l|--list|get|list) return 1 ;; esac
      done
      shopt -s nocasematch
      for a in "$@"; do
        case "$a" in remote.*|url.*|push.*|include.*|includeif.*|branch.*.remote|branch.*.pushremote|ops.pushverified) rc=0; break ;; esac
      done
      shopt -u nocasematch
      return "$rc" ;;
    branch|checkout|switch)
      for a in "$@"; do case "$a" in -u|--set-upstream-to|--set-upstream-to=*|-t|--track|--track=*) return 0 ;; esac; done ;;
  esac
  return 1
}

# toplevel_of <dir>: the nearest directory at or above <dir> holding .git,
# found without running git (the fail-safe path may test many directories).
toplevel_of() {
  local d="$1"
  while :; do
    [ -e "$d/.git" ] && { printf '%s' "$d"; return 0; }
    case "$d" in ""|/) return 1 ;; esac
    d="${d%/*}"
  done
}

# coarse_check: the fail-safe for a command the parser could not follow (no
# Python 3, a tokenize error, or a directory it could not resolve). It reads the
# RAW command, quotes kept, so a push inside a quoted bash -c or eval body still
# counts: a push, send-pack or http-push word, or the name of a push alias of a
# copy the command touches, triggers it. It then checks the gate of every OPS
# copy the command touches: the cwd's, and that of every directory named
# anywhere in it, each word resolved against the cwd and against every
# directory named before it (so `cd .. && cd pub` reaches pub), physically.
COARSE_OVERRIDE=""
coarse_check() {
  local trigger=0 tok w b c d root gate found=$'\n' gates=() bases=("$PUSH_CWD") line name value cands
  printf '%s' "$CMD_RAW" | grep -qE '(^|[^[:alnum:]_.-])(push|send-pack|http-push)([^[:alnum:]_-]|$)' && trigger=1
  # Words: each quoted span whole (a path with spaces), then every piece of the
  # command split at whitespace, quotes, backslashes and shell punctuation, in
  # order, so a path inside a quoted or escaped bash -c body is seen too.
  while IFS= read -r tok; do
    w="${tok#[\"\']}"; w="${w%[\"\']}"; w="${w#-C}"
    case "$w" in \~|\~/*) w="$HOME${w#\~}" ;; '$HOME'*) w="$HOME${w#\$HOME}" ;; '${HOME}'*) w="$HOME${w#\$\{HOME\}}" ;; esac
    [ -n "$w" ] || continue
    cands=()
    case "$w" in /*) cands=("$w") ;; *) for b in "${bases[@]}"; do cands+=("$b/$w"); done ;; esac
    for c in "${cands[@]}"; do
      [ -d "$c" ] || continue
      d="$(cd "$c" 2>/dev/null && pwd -P)" || continue
      case "$found" in *$'\n'"$d"$'\n'*) continue ;; esac
      found="$found$d"$'\n'; bases+=("$d")
    done
  done < <(printf '%s' "$CMD_RAW" | grep -oE "\"[^\"]*\"|'[^']*'"; printf '%s' "$CMD_RAW" | grep -oE "[^][:space:];&|()<>=\`\"'\\\\]+")
  d="$(cd "$PUSH_CWD" 2>/dev/null && pwd -P)" && found="$found$d"$'\n'
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    root="$(toplevel_of "$d")" || continue
    gate="$(ops_root "$root")" || continue
    case " ${gates[*]-} " in *" $gate "*) continue ;; esac
    gates+=("$gate")
    if [ "$trigger" = 0 ]; then
      # A copy's own alias for push hides the word: `git p` with alias.p=push.
      while IFS= read -r line; do
        name="${line%% *}"; name="${name#alias.}"; value="${line#* }"
        case "$value" in *push*|*send-pack*) ;; *) continue ;; esac
        printf '%s' "$CMD_RAW" | grep -qE "(^|[^[:alnum:]_.-])$name([^[:alnum:]_-]|\$)" && trigger=1
      done < <(git -C "$root" config --get-regexp '^alias\.' 2>/dev/null)
    fi
  done <<< "$found"
  [ "$trigger" = 1 ] || return 0
  for gate in ${gates[@]+"${gates[@]}"}; do
    [ -z "$COARSE_OVERRIDE" ] || deny "push from the OPS copy at $gate carries $COARSE_OVERRIDE, which can send it somewhere other than the origin the gate verifies; drop the override and push origin."
    ops_push_check "$gate" "$gate" coarse
  done
}

PUSH_CWD="$(printf '%s' "$RAW_INPUT" | hook_field cwd)"; [ -n "$PUSH_CWD" ] || PUSH_CWD="$PWD"
PUSH_CWD="$(hook_pathnorm "$PUSH_CWD")"
# The word "git" must appear for any git command to run; skip the parse otherwise.
case "$CMD_RAW" in *git*)
  PUSH_COARSE=0
  CHANGED_GATES=$'\n'
  while IFS= read -r -d '' base; do
    if [ "$base" = ERROR ]; then PUSH_COARSE=1; break; fi
    { IFS= read -r -d '' gd && IFS= read -r -d '' unresolved && IFS= read -r -d '' override \
      && IFS= read -r -d '' count; } || { PUSH_COARSE=1; break; }
    words=()
    for ((i = 0; i < count; i++)); do IFS= read -r -d '' word || { PUSH_COARSE=1; break 2; }; words+=("$word"); done
    sub="${words[1]:-}"
    if [ "$unresolved" = 1 ]; then
      PUSH_COARSE=1
      is_push "${words[@]:1}" && [ -n "$override" ] && COARSE_OVERRIDE="$override"
      continue
    fi
    if changes_push_config "${words[@]:1}"; then
      root="$(repo_root "$base" "$gd")" && gate="$(ops_root "$root")" && CHANGED_GATES="$CHANGED_GATES$gate"$'\n'
      continue
    fi
    is_push "${words[@]:1}" || continue
    # A push whose repo cannot be resolved (a missing directory, an xargs
    # placeholder) goes to the fail-safe check, never through unchecked.
    root="$(repo_root "$base" "$gd")" && [ -n "$root" ] || { PUSH_COARSE=1; continue; }
    gate="$(ops_root "$root")" || continue
    PG_ROOT="$root" PG_GD="$gd"
    case "$sub" in
      send-pack|http-push|subtree|lfs)
        deny "'git $sub' from the OPS copy at $root is a plumbing push that skips the origin check; push this copy with git push origin." ;;
    esac
    if [ -n "$override" ]; then
      deny "push from the OPS copy at $root carries $override, which can send it somewhere other than the origin the gate verifies; drop the override and push origin."
    fi
    case "$CHANGED_GATES" in *$'\n'"$gate"$'\n'*)
      deny "this command changes where pushes from the OPS copy at $root go (a remote, url, push or upstream setting, or ops.pushVerified) and then pushes; the gate runs before the command, so its verdict would be stale. Run the change on its own, then push in a separate command." ;;
    esac
    ops_push_check "$root" "$gate" resolved "${words[@]:2}"
  done < <(push_records "$PUSH_CWD")
  [ "$PUSH_COARSE" = 1 ] && coarse_check
;; esac

exit 0
