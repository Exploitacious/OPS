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
#   WARNED (exit 0, the warning goes to Claude as additionalContext):
#     a commit that would record merge conflict  (see "Conflict markers" for
#       markers: a staged line, or a file this     what counts, the limits,
#       call stages, starting with <<<<<<< ,       and why it never blocks)
#       |||||||, >>>>>>> or a lone =======
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
#
# rtk-awareness: rtk (a token-compressing CLI proxy some hosts register as a
# PreToolUse rewriter) turns `git push --force` into `rtk git push --force`,
# and an agent may type the rtk form itself. Every guard below must reach the
# same verdict either way, so RTKPRE lets an rtk invocation stand at any
# command position the guard already accepts: bare or absolute-path rtk, its
# own options, and the argv form of its command-running subcommands (run, err,
# summary, test, bypass, proxy). Without it `rtk git push --force` and
# `rtk git branch -D x` passed every check here. The push gate further down
# parses rtk itself, including the -c/--shell string forms. (The rtk string
# forms carry their command in quotes, which the git checks strip like any
# quoted span, the same known limit as `bash -c '<git command>'`.)
RTKPRE='(([^[:space:]|;&]*/)?rtk[[:space:]]+(-[^[:space:]]*[[:space:]]+)*((run|err|summary|test|bypass|proxy)[[:space:]]+(-[^[:space:]]*[[:space:]]+)*)?)?'
GITPOS='(^|[|;&][|&]?)[[:space:]]*([A-Z_]+=[^[:space:]]*[[:space:]]+)*(command[[:space:]]+)?'"$RTKPRE"'git[[:space:]]'
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
if printf '%s' "$CMD_RAW" | grep -qE '(^|[|;&][[:space:]]*)'"$RTKPRE"'rm[[:space:]]+(-[a-zA-Z]*[rf][a-zA-Z]*[[:space:]]+)+("?\$HOME"?|~|/home/[a-z]+|/[a-zA-Z]/[Uu]sers/[^/]+)/?(OPS|linuxploitacious|\.claude)?("|/)?([[:space:]]|$)'; then
  deny "recursive/forced rm aimed at a protected root tree (OPS / linuxploitacious / .claude): operator-gated."
fi

# tmux server protection: a bare `tmux kill-server`: or pkill/killall aimed
# at tmux: takes down EVERY tmux session on the box, including the one the
# Operator's own Claude runs in. Test cleanups must target their sandbox
# server EXPLICITLY on the same command line (`tmux -S <socket> kill-server` /
# `tmux -L <name> kill-server`); an env var set in an earlier Bash call does
# NOT persist and silently retargets the default socket. Explicit -S/-L forms
# pass; the bare form and tmux-wide pkill/killall are blocked.
if printf '%s' "$CMD" | grep -qE '(^|[|;&][[:space:]]*)'"$RTKPRE"'tmux[[:space:]]+((-f|-c)[[:space:]]+[^[:space:]]+[[:space:]]+)*kill-server' \
   && ! printf '%s' "$CMD" | grep -qE '(^|[|;&][[:space:]]*)'"$RTKPRE"'tmux[[:space:]]+[^|;&]*-(S|L)[[:space:]]*[^[:space:]]+[^|;&]*kill-server'; then
  deny "bare 'tmux kill-server' kills EVERY session on the box. Target your sandbox explicitly: tmux -S <socket> kill-server."
fi
if printf '%s' "$CMD_RAW" | grep -qE '(^|[|;&][[:space:]]*)'"$RTKPRE"'(pkill|killall)[[:space:]][^|;&]*tmux'; then
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

# git_records <cwd>: NUL-separated records for every git command in $CMD_RAW,
# each led by its kind, then the word ERROR if the command could not be read:
#   git base gitdir unresolved override count word...   (the push gate)
#   mk base gitdir count word...                        (the conflict-marker check)
# unresolved is 1 when the repo could not be resolved and the command may push
# (the caller then runs the fail-safe check); override names a setting the
# command carries that can move a push. The mk words are described in the
# parser below. The command reaches Python on stdin, never as an argument:
# Linux caps one argument at 128 KiB, and a long heredoc command must not turn
# into an uninspectable one.
git_records() {
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
# Conflict-marker records ("mk" first) feed the conflict-marker check at the end
# of the hook. One record per git command that stages content or records a
# commit: add or stage; commit; merge, cherry-pick, revert, rebase or am with
# --continue. Words: flags, kind (add, commit or continue), work tree, index
# file, then the command's own words after the subcommand. Flags: "u" when the
# repository is a guess (an unresolved -C, cd, git dir, work tree or index, or
# a cd to a directory that does not exist yet), "x" under xargs (more arguments
# arrive on stdin, unseen), "p" when an earlier command in this call may change
# files before this one runs (anything but cd and the other no-ops, read-only
# git commands, and the add and commit steps the check models), "-" for none.
# "p" only shapes the refusal's advice; it never decides a verdict.
MK_PRIOR = [False]
MK_QUIET = {"cd", "pushd", "popd", "true", ":", "pwd", "test", "["}
MK_READS = set("""status diff log show rev-parse ls-files ls-tree cat-file blame merge-base describe
fetch for-each-ref show-ref grep shortlog check-attr check-ignore var version help branch tag config
remote""".split())

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
    for v in ["git", base or "", gd or "", "1" if unresolved else "0", override, str(len(words)), *words]:
        sys.stdout.buffer.write(v.encode("utf-8", "surrogateescape") + b"\0")

def emit_mk(base, gd, words):
    for v in ["mk", base or "", gd or "", str(len(words)), *words]:
        sys.stdout.buffer.write(v.encode("utf-8", "surrogateescape") + b"\0")

def mk_step(prog, w):
    # git reports through git() below; a shell's -c body and an eval body are
    # walked as commands of their own, so the wrapper itself changes nothing.
    if prog in ("git", "git.exe", "eval") or prog in MK_QUIET:
        return
    if prog in SHELLS and any(a.startswith("-") and not a.startswith("--") and "c" in a[1:] for a in w):
        return
    MK_PRIOR[0] = True

def ansi_c(s):
    # Bash's $'...' escapes: \xHH, octal (a byte value, so \400 is NUL), \uHHHH,
    # \UHHHHHHHH and \cX as bash reads them; an unknown escape keeps its
    # backslash. $'\x67it' spells git, and so does its four-digit \u form.
    table = {"n": "\n", "t": "\t", "r": "\r", "a": "\a", "b": "\b", "e": "\x1b", "E": "\x1b", "f": "\f", "v": "\v",
             "\\": "\\", "'": "'", '"': '"', "?": "?"}
    def one(m):
        e = m.group(1)
        if e[0] == "x": return chr(int(e[1:], 16))
        if e[0] in "uU":
            v = int(e[1:], 16)
            return chr(v) if v <= 0x10FFFF else "?"
        if e[0] == "c" and len(e) == 2: return chr(ord(e[1]) & 31)
        if e[0] in "01234567": return chr(int(e, 8) & 0xFF)
        return table.get(e, "\\" + e)
    return re.sub(r"\\(x[0-9A-Fa-f]{1,2}|u[0-9A-Fa-f]{1,4}|U[0-9A-Fa-f]{1,8}|c.|[0-7]{1,3}|.)", one, s, flags=re.S)

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
    # written as "$(cat <<'EOF' ... EOF)" is text, not an open quote. A case
    # statement inside raises: its pattern's ")" cannot be told from the end of
    # the substitution here, and reading it as the end would leave the commands
    # after the pattern as quoted text, unseen. The caller's fail-safe check
    # then reads the raw command instead.
    depth, quote, n, pending, start = 1, None, len(text), [], i
    while i < n:
        c = text[i]
        if quote is None and c == "c" and re.match(r"case\b", text[i:i + 5]) and (i == start or text[i - 1] in " \t\n;&|("):
            raise ValueError("a case statement inside a command substitution")
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
                # Bash ends the string at its first NUL: $'git\0suffix' runs git.
                word = ansi_c("".join(body)).split("\0", 1)[0]
                out.append("'" + word.replace("'", "'\\''") + "'"); i = j + 1; start = False; continue
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
    # guess: a cd went to a directory that does not exist yet (made earlier in
    # the same call), so the base is stale; only the conflict-marker records
    # read it, and an absolute cd clears it.
    sh = {"base": base, "oldpwd": None, "dirs": [], "vars": {}, "exported": set(), "pos": [], "push_override": "", "git_config": [], "guess": False}
    if parent:
        sh.update(oldpwd=parent["oldpwd"], vars=dict(parent["vars"]), exported=set(parent["exported"]), pos=list(parent["pos"]), push_override=parent["push_override"], git_config=list(parent["git_config"]), guess=parent["guess"])
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
                stack.append((sh["base"], sh["oldpwd"], list(sh["dirs"]), dict(sh["vars"]), set(sh["exported"]), sh["guess"]))
            elif t == ")" and stack:
                sh["base"], sh["oldpwd"], sh["dirs"], sh["vars"], sh["exported"], sh["guess"] = stack.pop()
        else:
            seg.append((kind, t))

def command(seg, sh, depth, bodies, quoted, subs, piped):
    # Returns what the command writes to a pipe when that is knowable (echo,
    # printf, cat of a here-document), so `... | bash` parses it as a script.
    base = sh["base"]
    for kind, t in seg:
        for key in SUBST.findall(t):
            commands(subs[key], shell(base, sh), depth + 1, (bodies, quoted))
    env, w, stdin, i, xargs_run = {}, [], list(piped or []), 0, False
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
            if prog == "xargs": xargs_run = True
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
    mk_step(prog, w)
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
            sh["guess"] = True
            return None
        if not args or (args[0] != "-" and re.match(r"^(/|~|[A-Za-z]:[/\\])", expand(args[0], sh) or "")):
            sh["guess"] = False
        if prog == "pushd": sh["dirs"].append(base)
        sh["oldpwd"], sh["base"] = base, dest
    elif prog == "popd" and sh["dirs"]:
        sh["oldpwd"], sh["base"] = base, sh["dirs"].pop()
    elif prog in ("git", "git.exe"):
        git(w, base, sh, env, depth, xargs_run)
    return None

def push_override(key):
    k = key.lower()
    # An included config can set any push destination even when the include
    # key itself does not mention a remote. The gate never saw that config.
    return k.startswith(("remote.", "url.", "push.", "include.", "includeif.")) or (k.startswith("branch.") and k.rsplit(".", 1)[-1] in ("remote", "pushremote"))

def git(w, base, sh, env, depth, xargs_run=False):
    genv = {k: v for k, v in sh["vars"].items() if k in sh["exported"]}
    genv.update(env)
    unresolved = base is None
    gd, kv, override = "", list(sh["git_config"]), sh["push_override"]
    wt_word = genv.get("GIT_WORK_TREE", "")
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
            elif opt == "--work-tree":
                wt_word = val
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
    sub = w[0]
    kind = "add" if sub in ("add", "stage") else "commit" if sub == "commit" else None
    if sub in ("merge", "cherry-pick", "revert", "rebase", "am") and "--continue" in w[1:]:
        kind = "continue"
    if kind is None:
        if sub not in MK_READS: MK_PRIOR[0] = True
        return
    wt = path(wt_word, base, sh, True) if wt_word else ""
    idx = genv.get("GIT_INDEX_FILE", "")
    guess = unresolved or wt is None or idx is None or (wt_word is None) or sh["guess"]
    # A word that is still a placeholder or holds a variable is no literal
    # path: a leading "$" makes the check treat it as unknown.
    args = ["$" + a if not a.startswith("-") and (SUBST.search(a) or "`" in a) else a for a in w[1:]]
    flags = ("u" if guess else "") + ("x" if xargs_run else "") + ("p" if MK_PRIOR[0] else "")
    emit_mk(base, gd, [flags or "-", kind, wt or "", idx or "", *args])

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

# --- Conflict markers -----------------------------------------------------------
# Warns about a commit that would record an unresolved merge conflict. Why a
# hook: a lesson in memory does not stop the slip it describes. The failing
# shape is a resolver step that fails and writes nothing, with the git add and
# git commit on the next lines of the same Bash call running anyway, so the
# markers ship; in a harness repo a marker in a hook or script is a parse error
# that can turn a guard off. Prose did not change the behavior, so the hook
# speaks at the commit itself.
#
# Why a warning and never a block: a commit is the owner's content, and the
# template does not block an owner's content unless it is unsafe
# (CONTEXT/how-i-work.md, "The template and a copy's owner"). A marker in a
# commit is a mistake to fix, not a danger: the files already hold the markers
# before the commit, and a follow-up commit (or an amend before the push)
# removes them. A false block, or a check too slow to finish on a loaded box,
# would stop clean commits. So every outcome below exits 0: hits and an
# inspection that could not finish both go to Claude as PreToolUse
# additionalContext (and to the Operator as a one-line systemMessage), and the
# commit runs.
#
# What counts as a marker: a line that starts with exactly seven <, | or >
# characters followed by a space, a tab or the line's end, or exactly seven =
# characters with nothing but whitespace after them. That is git's own leftover
# conflict-marker rule (git diff --check), narrowed for = so a reStructuredText
# table border (======= followed by more columns) is not a marker, and it honors
# git's conflict-marker-size attribute for a path as git diff --check does
# (lengths below seven are not checked). Precision over breadth: a false warning
# on every commit in a repo teaches everyone to skip it, so the rule matches only
# what git writes. Mid-line markers, a line merely containing =======, eight =
# characters, binary files and the commit message are never markers. Markers
# inside fenced code in Markdown still warn: a real conflict looks the same.
#
# What "would record" means, per repository a command commits in:
#   - the staged diff (git diff --cached, against the amended commit's parent
#     for --amend, so an amend cannot carry markers the commit it replaces had);
#   - the files this Bash call stages first, read from the working tree,
#     because this hook runs before git add does: a git add earlier in the call
#     (its pathspecs, -A, -u, -f), commit -a (tracked files), and commit
#     <pathspec> (those paths; without -i the rest of the index is left out, as
#     git leaves it out). Each commit keeps its own snapshot of earlier staging,
#     so a later add cannot hide markers that an earlier commit would record.
#     Untracked files use git's binary attributes and clean-filter output too.
#     --only --amend without paths checks HEAD rather than the index. Amend
#     bases use the current HEAD even after an earlier commit in the call: that
#     commit may fail. Split the call if advancing HEAD would clear a hit.
# Commands: commit (including git -C <dir>, -a, --amend, and a merge commit via
# --no-edit), and merge, cherry-pick, revert, rebase or am with --continue,
# which record the index the same way. Aliases, shell -c bodies, command
# substitutions and scripts piped to a shell are expanded by the parser above.
#
# The hook sees the files before the Bash call runs. A call that resolves a
# conflict and commits in one go warns while the markers are still in the files;
# the warning says the resolving step may have cleared them, how to check the
# commit it made, and to run such a step in its own Bash call next time, so the
# guard reads the result.
#
# Cost: nothing for a command with no commit. Inspection costs one Python start,
# a git rev-parse per repository and a diff per commit snapshot; staging first
# adds a rev-parse of HEAD, ls-files and a diff per add. New files with filters,
# binary content or marker-like lines get a no-index diff; plain clean text needs
# only a scan. No network (GIT_NO_LAZY_FETCH=1), no index refresh
# (GIT_OPTIONAL_LOCKS=0), no external diff, textconv or fsmonitor program. A 6 s
# budget inside Python and a hard 8 s limit (timeout -k 1 8) around it bound the
# check. Working-tree diffs may run a path's clean filter (git-lfs, eol
# conversion), as git add itself will.
#
# Never silent, never a block: a git error, an expired budget or a crash lets
# the commit run with a warning that says the check could not inspect it, why,
# and how to check by hand. Not inspected, by design
# (the commit would fail on its own, or the guard cannot know what it records):
# a directory that is not a work tree, a repository the parser could not
# resolve (a computed path, a cd to a directory the call creates), --dry-run,
# and an amend with nothing to amend. When the parser cannot read the command at
# all and its text names commit or --continue, the check falls back to the
# staged diff of the hook's working directory. Without Python 3 the check does
# not run: the push gate keeps its raw-text fallback there because a missed push
# can publish private notes, while a missed marker costs a commit to fix. Narrow
# misses, documented: staging the guard cannot model (git add -p, -i, -e, -N,
# --pathspec-from-file, pathspecs with an unexpanded $VARIABLE or arriving
# through xargs) is not read from the working tree, though the staged diff still
# is; a command earlier in the call that creates a conflict (a merge, pull or
# stash pop chained with ; rather than &&) is not simulated; a commit inside a
# script file, a computed command or a non-git tool is not seen.
#
# Intended marker lines (a test fixture, a document quoting a conflict) should
# be generated at run time, or the path given a conflict-marker-size attribute
# in .gitattributes, so the check stays quiet for them. Both GIT_GUARD=off
# hatches skip the check, as they skip the rest of this hook. A test corpus with
# markers is written with a file tool or a script, never in a Bash heredoc,
# since this hook reads the whole command string (heredoc bodies included).
#
# Test seam (session environment only, never a command prefix: hooks do not
# inherit a command's prefix): GIT_GUARD_MARKER_BUDGET, seconds, can only lower
# the 6 s budget.
MK_DIR=() MK_AUX=() MK_OFF=() MK_LEN=() MK_W=()
MK_UNREAD=0

# mk_store <dir> <git dir> <word>...: keep one marker record for the check.
mk_store() {
  local dir="$1" gd="$2"; shift 2
  MK_DIR+=("$dir"); MK_AUX+=("$gd"); MK_OFF+=("${#MK_W[@]}"); MK_LEN+=("$#"); MK_W+=("$@")
}

# mk_records: the stored records, NUL framed (dir, git dir, word count, words),
# then an END word, so a truncated stream cannot pass as a complete one.
mk_records() {
  local i
  for ((i = 0; i < ${#MK_DIR[@]}; i++)); do
    printf '%s\0%s\0%s\0' "${MK_DIR[$i]}" "${MK_AUX[$i]}" "${MK_LEN[$i]}"
    printf '%s\0' "${MK_W[@]:${MK_OFF[$i]}:${MK_LEN[$i]}}"
  done
  printf 'END\0'
}

mk_program() {
  cat <<'MKPY'
import os, posixpath, re, signal, stat, subprocess, sys, tempfile, threading, time

class Stop(Exception):
    """The inspection cannot finish; the gate warns and shows the reason."""

# A file name the terminal's encoding cannot spell must not crash the warning.
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

try:
    budget = float(os.environ.get("GIT_GUARD_MARKER_BUDGET") or 6)
except ValueError:
    budget = 6.0
# The seam can only lower the budget (NaN fails every comparison, so it is reset).
if budget != budget or budget > 6:
    budget = 6.0
budget = max(budget, 0.1)
deadline = time.monotonic() + budget
SHOWN = 12
KEEP = 5000
BIG = 512 << 20   # git's default core.bigFileThreshold: bigger files diff as binary
ENV = dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0", GIT_NO_LAZY_FETCH="1")
for k in ("GIT_EXTERNAL_DIFF", "GIT_DIFF_OPTS", "GIT_PAGER"):
    ENV.pop(k, None)
# Explicit settings beat user config that would change the output parsed below.
CFG = ["-c", "core.fsmonitor=false", "-c", "diff.relative=false", "-c", "diff.noprefix=false",
       "-c", "diff.mnemonicPrefix=false"]
# Separate hunks explicitly: diff.suppressBlankEmpty can otherwise remove a
# context line's prefix and make a later addition invisible to the parser.
DIFF = ["-U0", "--inter-hunk-context=0", "--no-color", "--no-ext-diff", "--no-textconv", "-M",
        "--src-prefix=a/", "--dst-prefix=b/"]
HUNK = re.compile(rb"^@@ -[0-9]+(?:,[0-9]+)? \+([0-9]+)(?:,[0-9]+)? @@")
WS = b" \t\r\n\v\f"

def left():
    r = deadline - time.monotonic()
    if r <= 0:
        raise Stop("the check ran out of its %g s budget" % budget)
    return r

def native_path(p):
    if os.name == "nt":
        return subprocess.check_output(["cygpath", "-w", p], text=True).strip()
    return p

def text(b):
    return b.decode("utf-8", "surrogateescape")

def show(s, n=60):
    s = "".join(c if c.isprintable() else "?" for c in s)
    return s if len(s) <= n else s[:n] + "..."

def cmdline(ctx, base, args):
    c = ["git", "-C", native_path(base)]
    if ctx["gd"]:
        c.append("--git-dir=" + native_path(ctx["gd"]))
    if ctx["wt"]:
        c.append("--work-tree=" + native_path(ctx["wt"]))
    return c + CFG + args

def envof(ctx):
    return dict(ENV, GIT_INDEX_FILE=native_path(ctx["idx"])) if ctx["idx"] else ENV

# git runs in a session of its own and a deadline kills the whole group: a child
# git starts (a clean filter, a helper) can hold the output pipe open after git
# itself dies, and reading that pipe would then outlast the budget.
GROUP = os.name != "nt"

def spawn(ctx, base, args, stdin, stdout, stderr):
    return subprocess.Popen(cmdline(ctx, base, args), stdin=stdin, stdout=stdout, stderr=stderr,
                            env=envof(ctx), start_new_session=GROUP)

def kill(p):
    try:
        if GROUP:
            os.killpg(p.pid, signal.SIGKILL)
        else:
            p.kill()
    except (ProcessLookupError, PermissionError):
        pass   # the group is already gone

def git(ctx, base, args, data=None, may_fail=False):
    """stdout of one git call; None when it fails and may_fail is set."""
    remaining = left()
    p = spawn(ctx, base, args, subprocess.DEVNULL if data is None else subprocess.PIPE,
              subprocess.PIPE, subprocess.PIPE)
    try:
        out, err = p.communicate(data, timeout=remaining)
    except subprocess.TimeoutExpired:
        kill(p)
        p.communicate()
        raise Stop("git %s did not finish inside the %g s budget" % (args[0], budget))
    if p.returncode:
        if may_fail:
            return None
        raise Stop("git %s failed (exit %d): %s" % (args[0], p.returncode, show(text(err.strip()[-300:]), 300)))
    return out

def git_lines(ctx, base, args, codes=(0,)):
    """Stream git's output a line at a time; a timer kills it at the deadline."""
    remaining = left()
    err = tempfile.TemporaryFile()
    p = spawn(ctx, base, args, subprocess.DEVNULL, subprocess.PIPE, err)
    fired = []
    def stop():
        fired.append(1)
        kill(p)
    timer = threading.Timer(remaining, stop)
    timer.daemon = True
    timer.start()
    try:
        for line in p.stdout:
            yield line
        p.wait()
    finally:
        timer.cancel()
        if p.poll() is None:
            kill(p)
            p.wait()
        p.stdout.close()
    if fired:
        raise Stop("git %s did not finish inside the %g s budget" % (args[0], budget))
    if p.returncode not in codes:
        err.seek(0)
        raise Stop("git %s failed (exit %d): %s" % (args[0], p.returncode, show(text(err.read().strip()[-300:]), 300)))

def run_length(line):
    """Length of a line-start marker run that could be a conflict marker, else 0."""
    if not line or line[0] not in b"<=>|":
        return 0
    c, r = line[0], 1
    while r < len(line) and line[r] == c:
        r += 1
    if r < 7:
        return 0
    rest = line[r:]
    if c == 61:   # "=": git writes the separator alone on its line
        return r if not rest.strip(WS) else 0
    return r if not rest or rest[0] in WS else 0

def note(ctx, hits, path, n, line, source):
    r = run_length(line)
    if not r:
        return
    sizes = ctx.setdefault("sizes", {})
    if path not in sizes:
        sizes.update(marker_sizes(ctx, ctx["top"], [path]))
    # Filter before the storage limit: thousands of harmless eight-character
    # runs must neither cause a warning nor hide a real marker after them.
    if r == sizes.get(path, 7) and (path, n) not in hits:
        if len(hits) >= KEEP:
            hits[None] = hits.get(None, 0) + 1
            return
        hits[(path, n)] = (r, text(line.rstrip(b"\r\n")), source)

ESC = {ord("a"): 7, ord("b"): 8, ord("t"): 9, ord("n"): 10, ord("v"): 11, ord("f"): 12,
       ord("r"): 13, ord('"'): 34, ord("\\"): 92}

def unquote(b):
    """git's C-style quoting of an unusual path, as in a diff's +++ line."""
    if len(b) < 2 or b[:1] != b'"' or b[-1:] != b'"':
        return b
    out, i, end = bytearray(), 1, len(b) - 1
    while i < end:
        c = b[i]
        if c == 92 and i + 1 < end:
            o = b[i + 1:i + 4]
            if len(o) == 3 and i + 3 < end and all(48 <= x <= 55 for x in o):
                out.append(int(o, 8) & 255)
                i += 4
                continue
            if b[i + 1] in ESC:
                out.append(ESC[b[i + 1]])
                i += 2
                continue
        out.append(c)
        i += 1
    return bytes(out)

def diff_hits(ctx, base, args, source, hits, skip=(), select=None, codes=(0,)):
    path, n, hunk = None, 0, False
    for raw in git_lines(ctx, base, args, codes):
        if hunk:
            ch = raw[:1]
            if ch == b"+":
                if path is not None and path not in skip and (select is None or path in select):
                    note(ctx, hits, path, n, raw[1:], source)
                n += 1
                continue
            if ch == b" ":
                n += 1
                continue
            if ch in (b"-", b"\\"):
                continue
            hunk = False
        if raw.startswith(b"diff "):
            path = None
        elif raw.startswith(b"+++ "):
            name = raw[4:].rstrip(b"\n")
            if name.endswith(b"\t"):   # git adds a tab after a name with a space
                name = name[:-1]
            name = unquote(name)
            path = text(name[2:]) if name.startswith(b"b/") else None
        else:
            m = HUNK.match(raw)
            if m:
                n, hunk = int(m.group(1)), True

def ls_files(ctx, base, specs, others=False, force=False):
    args = ["ls-files", "-z", "--full-name"]
    if others:
        args += ["--others"] + ([] if force else ["--exclude-standard"])
    out = git(ctx, base, args + ["--"] + specs)
    return {text(p) for p in out.split(b"\0") if p}

def scan_file(ctx, top, rel, hits, filtered=False):
    full = posixpath.join(top, rel)   # top is git's own spelling, which Python opens
    try:
        st = os.lstat(full)
        regular = stat.S_ISREG(st.st_mode)
        if not regular and not stat.S_ISLNK(st.st_mode):
            return
        needs_diff = filtered or not regular or st.st_size > BIG
        if not needs_diff:
            with open(full, "rb") as f:
                needs_diff = b"\0" in f.read(8000)
                if not needs_diff:
                    f.seek(0)
                    for n, line in enumerate(f, 1):
                        if n % 4096 == 0:
                            left()
                        if run_length(line):
                            needs_diff = True
                            break
    except OSError:
        return   # gone or unreadable: git add cannot stage it either
    if needs_diff:
        # Git decides binary/text attributes, driver settings and clean-filter
        # output exactly as it does for tracked paths. Plain clean text needs no
        # extra process; a filter can create markers even without any on disk.
        diff_hits(ctx, top, ["diff", "--no-index"] + DIFF + ["--", "/dev/null", rel],
                  "untracked, staged by this call", hits, codes=(0, 1))

def attributes(ctx, top, paths, name):
    out = git(ctx, top, ["check-attr", "-z", "--stdin", name],
              data=b"".join(p.encode("utf-8", "surrogateescape") + b"\0" for p in paths))
    f = out.split(b"\0")
    return {text(f[i]): text(f[i + 2]) for i in range(0, len(f) - 2, 3)}

def marker_sizes(ctx, top, paths):
    """conflict-marker-size per path; git reads the value with atoi, and <= 0 means 7."""
    sizes = {}
    for path, value in attributes(ctx, top, paths, "conflict-marker-size").items():
        m = re.match(r"\s*\+?([0-9]+)", value)
        v = int(m.group(1)) if m else 0
        sizes[path] = v if v > 0 else 7
    return sizes

REDIRECT = set("<>&|")

def clean(args):
    """Drop redirections left as words (2>&1 can arrive as 2, >&, 1)."""
    out, i = [], 0
    while i < len(args):
        a = args[i]
        if a and set(a) <= REDIRECT and ("<" in a or ">" in a):
            if out and out[-1].isdigit():
                out.pop()
            i += 2
            continue
        out.append(a)
        i += 1
    return out

def expand(paths):
    out = []
    for p in paths:
        p = os.path.expandvars(posixpath.expanduser(p))
        if "$" in p:
            return None
        out.append(p)
    return out

def parse(args, short_value, long_value, short_attached=""):
    """git's option grammar: flags, values (attached or next word), pathspecs.
    short_attached: short options whose optional value can only be attached."""
    flags, paths, i, rest = set(), [], 0, False
    while i < len(args):
        a = args[i]
        i += 1
        if rest or a == "-" or not a.startswith("-"):
            paths.append(a)
        elif a == "--":
            rest = True
        elif a.startswith("--"):
            name, eq, _ = a[2:].partition("=")
            flags.add(name)
            if name in long_value and not eq:
                i += 1
        else:
            for j, c in enumerate(a[1:], 1):
                if c in short_value:
                    if j == len(a) - 1:
                        i += 1
                    break
                if c in short_attached:
                    break
                flags.add(c)
    return flags, paths

def add_cover(args, base):
    """(base, pathspecs or None for the whole tree, tracked only, force) for one git add."""
    flags, paths = parse(args, "", {"chmod", "pathspec-from-file"})
    if flags & {"n", "dry-run", "N", "intent-to-add", "refresh", "i", "interactive", "p", "patch", "e", "edit",
                "pathspec-from-file"}:
        return None   # stages nothing, or a subset this check cannot know
    whole = flags & {"A", "all", "no-ignore-removal"}
    tracked = bool(flags & {"u", "update", "renormalize"})
    force = bool(flags & {"f", "force"})
    if not paths:
        return (base, None, tracked, force) if whole or tracked else None
    paths = expand(paths)
    return None if paths is None else (base, paths, tracked, force)

def commit_spec(args, base, top):
    # -u<mode> and -S<keyid> take only an attached value.
    flags, paths = parse(args, "mFCct", {"message", "file", "reuse-message", "reedit-message", "fixup", "squash",
                                         "author", "date", "template", "cleanup", "trailer", "pathspec-from-file"}, "uS")
    if flags & {"dry-run", "short", "porcelain", "long"}:
        return None   # records nothing (--short, --porcelain and --long imply --dry-run)
    spec = {"amend": "amend" in flags, "staged": True, "covers": [], "select": None, "head_only": False}
    if flags & {"p", "patch", "interactive", "pathspec-from-file"}:
        return spec   # an interactive or listed subset: the staged diff only
    if flags & {"a", "all"}:
        if paths:
            return None   # git refuses -a with paths
        spec["covers"].append((top, None, True, False))
    elif paths:
        paths = expand(paths)
        if paths is not None:
            spec["covers"].append((base, paths, True, False))
            spec["staged"] = bool(flags & {"i", "include"})
            if not spec["staged"]:
                spec["select"] = (base, paths)
    elif flags & {"o", "only"}:
        if not spec["amend"]:
            return None   # no paths: fails, or records an empty commit with --allow-empty
        spec["head_only"] = True   # --only --amend retains HEAD and ignores the index
        spec["staged"] = False
    return spec

def records(data):
    f = data.split(b"\0")
    if len(f) < 2 or f[-1] != b"" or f[-2] != b"END":
        raise Stop("the record stream is incomplete")
    f, i, out = f[:-2], 0, []
    while i < len(f):
        n = int(f[i + 2])
        words = [text(w) for w in f[i + 3:i + 3 + n]]
        if n < 4 or len(words) != n:
            raise Stop("a malformed record")
        out.append((text(f[i]), text(f[i + 1]), words))
        i += 3 + n
    return out

repos = {}
def repo(base, gd, wt, idx):
    key = (base, gd, wt, idx)
    if key not in repos:
        ctx = {"gd": gd, "wt": wt, "idx": idx}
        out = git(ctx, base, ["rev-parse", "--absolute-git-dir", "--show-toplevel"], may_fail=True)
        lines = text(out).splitlines() if out is not None else []
        if out is not None and len(lines) != 2:
            raise Stop("git rev-parse gave %d lines, not 2" % len(lines))
        # Not a work tree: git commit fails on its own, so there is nothing to inspect.
        repos[key] = dict(ctx, top=lines[1], key=(lines[0], lines[1], idx)) if lines else None
    return repos[key]

def rev(ctx, name):
    out = git(ctx, ctx["top"], ["rev-parse", "-q", "--verify", name + "^{commit}"], may_fail=True)
    return text(out).strip() if out else None

def inspect(st):
    ctx, top, hits = st["ctx"], st["ctx"]["top"], {}
    tree = None   # None: git diff --cached picks HEAD, or the empty tree when unborn
    if st["amend"] or st["covers"]:
        head = rev(ctx, "HEAD")
        if st["amend"] and head is None:
            return []   # nothing to amend: git commit fails on its own
        tree = rev(ctx, "HEAD^1") if st["amend"] else head
        if tree is None:
            tree = text(git(ctx, top, ["hash-object", "-t", "tree", "--stdin"], data=b"")).strip()
    if st["head_only"]:
        diff_hits(ctx, top, ["diff"] + DIFF + [tree, "HEAD", "--"], "amended commit", hits)
    select = None
    if st["select"]:
        base, paths = st["select"]
        select = ls_files(ctx, base, paths) | ls_files(ctx, base, paths, others=True, force=True)
    whole = any(cv[1] is None for cv in st["covers"])
    specs = [(top, [":/"])] if whole else [(cv[0], cv[1]) for cv in st["covers"]]
    covered = set()
    for base, paths in specs:
        diff_hits(ctx, base, ["diff"] + DIFF + [tree, "--"] + paths,
                  "working tree, staged by this call", hits, select=select)
        if st["staged"] and not whole:
            covered |= ls_files(ctx, base, paths)
    for base, paths, tracked, force in st["covers"]:
        if not tracked:
            rels = sorted(p for p in ls_files(ctx, base, paths or [":/"], others=True, force=force)
                          if not p.endswith("/") and (select is None or p in select))
            filters = attributes(ctx, top, rels, "filter") if rels else {}
            for rel in rels:
                scan_file(ctx, top, rel, hits, filters.get(rel, "unspecified") not in {"unspecified", "set", "unset"})
    # A tracked path this call stages again is recorded from the working tree, so
    # its staged version (already read above) is left out; a whole-tree cover
    # stages every tracked path.
    if st["staged"] and not whole:
        diff_hits(ctx, top, ["diff", "--cached"] + DIFF + ([tree] if tree else []) + ["--"], "staged", hits, covered)
    extra = hits.pop(None, 0)
    if not hits:
        return [("", "", 0, "", "")] * extra
    found = [(top, p, n, line, src) for (p, n), (_, line, src) in hits.items()]
    return found + [("", "", 0, "", "")] * extra

def main(data):
    states, pending, previous = [], {}, set()
    for base, gd, words in records(data):
        flags, kind, wt, idx, args = words[0], words[1], words[2], words[3], clean(words[4:])
        if "u" in flags:
            continue   # a guessed directory could name another repository
        if idx and not posixpath.isabs(idx):
            idx = posixpath.join(base, idx)
        if kind == "add":
            cover = None if "x" in flags else add_cover(args, base)
            ctx = cover and repo(base, gd, wt, idx)
            if ctx:
                pending.setdefault(ctx["key"], []).append(cover)
            continue
        ctx = repo(base, gd, wt, idx)
        if ctx is None:
            continue
        spec = commit_spec(args, base, ctx["top"]) if kind == "commit" else {
            "amend": False, "staged": True, "covers": [], "select": None, "head_only": False}
        if spec is None:
            continue
        prior = ctx["key"] in previous
        covers = pending.setdefault(ctx["key"], [])
        covers += spec["covers"]
        # Snapshot each commit separately. Later staging cannot repair what an
        # earlier commit would record; earlier staging still updates later ones.
        st = dict(spec, ctx=ctx, covers=[] if spec["head_only"] else list(covers), prior="p" in flags or prior)
        states.append(st)
        previous.add(ctx["key"])
    found, seen, prior = [], set(), False
    for st in states:
        got = inspect(st)
        prior = prior or (bool(got) and st["prior"])
        for h in got:
            # The same line reached by two snapshots (or by the parse fallback
            # beside a parsed record) is one finding.
            if h[0] and (h[0], h[1], h[2]) in seen:
                continue
            seen.add((h[0], h[1], h[2]))
            found.append(h)
    if not found:
        return 0
    print("PRIOR" if prior else "-")
    shown = [h for h in found if h[0]][:SHOWN]
    for top, p, n, line, src in shown:
        print("  %s:%d: %s  [%s]" % (show(posixpath.join(top, p), 200), n, show(line), src))
    if len(found) > len(shown):
        print("  ... and %d more" % (len(found) - len(shown)))
    return 3

try:
    sys.exit(main(d))
except Stop as e:
    print(e)
    sys.exit(4)
except Exception as e:   # a defect here must warn, never pass silently
    print("internal error: %s: %s" % (type(e).__name__, e))
    sys.exit(4)
MKPY
}

# mk_emit <text> <one-line summary>: the warning, then exit 0 (the commit runs;
# see the header for why this check never blocks). PreToolUse JSON on stdout
# carries the text to Claude (additionalContext) and the summary to the
# Operator (systemMessage); the text also goes to stderr for the transcript.
# jq builds the JSON, else the Python the check ran with ($py, set by
# conflict_marker_gate); with neither, stderr alone carries it.
mk_emit() {
  local json=""
  json="$(jq -cn --arg c "$1" --arg s "$2" \
    '{systemMessage: $s, hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $c}}' 2>/dev/null)" \
    || json="$(printf '%s' "$1" | "${py:-python3}" -c 'import json, sys; print(json.dumps({"systemMessage": sys.argv[1], "hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": sys.stdin.read()}}))' "$2" 2>/dev/null)" \
    || json=""
  [ -z "$json" ] || printf '%s\n' "$json"
  printf '%s\n' "$1" >&2
  exit 0
}

mk_warn() {  # <first line> <hit lines>
  local msg
  msg="git-guard: WARNING (conflict markers): this commit records unresolved merge conflict markers. The commit was not stopped: a commit is the owner's content, so this check warns and never blocks.
$2
Each line above starts the way git writes a conflict marker (seven <, |, = or > characters; a ======= line stands alone)."
  if [ "$1" = PRIOR ]; then
    msg="$msg
This Bash call runs another command before the commit, and the guard read the index and working tree before the call started. If that step resolved these files, the commit may be clean: check it with git show --check HEAD. Next time, run such a step in its own Bash call, then stage and commit in the next, so the guard reads the result."
  fi
  msg="$msg
If the markers are not intended: in each file keep the content you want and delete the marker lines, then commit the fix (or amend the commit if it is not pushed yet), and confirm git show --check HEAD reports no leftover conflict marker before you push.
Intended marker lines (a test fixture, a document quoting a conflict): generate them at run time, or give the path a conflict-marker-size attribute in .gitattributes, and this check stays quiet for them."
  mk_emit "$msg" "git-guard: this commit records merge conflict markers (a warning; the commit ran)."
}

mk_warn_uninspectable() {  # <reason>
  mk_emit "git-guard: WARNING (conflict markers): cannot inspect what this commit records: $1. The commit was not stopped: this check warns and never blocks. Check it by hand once it has run: git show --check HEAD in the repository reports any leftover conflict marker." \
    "git-guard: could not check this commit for conflict markers (a warning; the commit ran)."
}

# mk_names_commit: the raw command names a commit or a --continue as a word
# (the parse fallback's trigger; see the header above).
mk_names_commit() {
  printf '%s' "$CMD_RAW" | grep -qE '(^|[^[:alnum:]_.-])(commit|--continue)([^[:alnum:]_-]|$)'
}

conflict_marker_gate() {
  local i py to rc out boot first commit=0
  local -a lim=()
  # A command the parser could not read: check the working directory's staged
  # content as a plain commit when the text names one.
  if [ "$MK_UNREAD" = 1 ] && mk_names_commit; then
    mk_store "$PUSH_CWD" "" - commit "" ""
  fi
  [ "${#MK_DIR[@]}" -gt 0 ] || return 0
  for ((i = 0; i < ${#MK_DIR[@]}; i++)); do
    [ "${MK_W[$((MK_OFF[i] + 1))]}" = add ] || commit=1
  done
  [ "$commit" = 1 ] || return 0
  py="$(hook_python)" || return 0   # no Python 3: not inspected (see the header)
  if to="$(hook_timeout)"; then lim=("$to" -k 1 8); fi
  # Program and records reach Python on stdin, split at the first NUL: no
  # argument-length limit and no quoting for a Windows launch.
  boot="import sys; p, d = sys.stdin.buffer.read().split(b'\\0', 1); exec(compile(p, 'git-guard-markers', 'exec'))"
  out="$( { mk_program && printf '\0' && mk_records; } | ${lim[@]+"${lim[@]}"} "$py" -c "$boot" 2>&1)"
  rc=$?
  case "$rc" in
    0) return 0 ;;
    3) first="${out%%$'\n'*}"; mk_warn "$first" "${out#*$'\n'}" ;;
    124|137) mk_warn_uninspectable "the check passed its hard 8 s limit" ;;
    4) mk_warn_uninspectable "$(printf '%s' "$out" | tail -n 1 | cut -c1-300)" ;;
    *) mk_warn_uninspectable "the check exited $rc: $(printf '%s' "$out" | tail -n 2 | tr '\n' ' ' | cut -c1-300)" ;;
  esac
}

PUSH_CWD="$(printf '%s' "$RAW_INPUT" | hook_field cwd)"; [ -n "$PUSH_CWD" ] || PUSH_CWD="$PWD"
PUSH_CWD="$(hook_pathnorm "$PUSH_CWD")"
# gg_parse_needed: 0 when the command could run git, so the parser must read it.
# The word git must appear for a git command to run, but quotes, backslashes and
# line continuations can split it (g"i"t, g\it), and $'...' can spell it in
# escapes, so the test strips the first three and always parses the last. A
# command with none of them that does not hold "git" skips the parse (and its
# Python start); the string rules above still ran on it.
gg_parse_needed() {
  local x
  case "$CMD_RAW" in
    *git*|*"\$'"*) return 0 ;;
    *[\"\'\\]*) ;;
    *) return 1 ;;
  esac
  x="$(printf '%s' "$CMD_RAW" | tr -d "\"'\\\\\n")" || return 0
  case "$x" in *git*) return 0 ;; esac
  return 1
}

# One parse feeds both gates: the push gate here and the conflict-marker check
# after it. A stream it cannot read (ERROR, or a record cut short) sends the push
# gate to its fail-safe check and the marker check to its parse fallback.
if gg_parse_needed; then
  PUSH_COARSE=0
  CHANGED_GATES=$'\n'
  while IFS= read -r -d '' kind; do
    case "$kind" in
      git) ;;
      mk)
        { IFS= read -r -d '' base && IFS= read -r -d '' gd && IFS= read -r -d '' count; } \
          || { PUSH_COARSE=1; MK_UNREAD=1; break; }
        words=()
        for ((i = 0; i < count; i++)); do IFS= read -r -d '' word || { PUSH_COARSE=1; MK_UNREAD=1; break 2; }; words+=("$word"); done
        mk_store "$base" "$gd" "${words[@]}"
        continue ;;
      *) PUSH_COARSE=1; MK_UNREAD=1; break ;;
    esac
    { IFS= read -r -d '' base && IFS= read -r -d '' gd && IFS= read -r -d '' unresolved \
      && IFS= read -r -d '' override && IFS= read -r -d '' count; } || { PUSH_COARSE=1; MK_UNREAD=1; break; }
    words=()
    for ((i = 0; i < count; i++)); do IFS= read -r -d '' word || { PUSH_COARSE=1; MK_UNREAD=1; break 2; }; words+=("$word"); done
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
  done < <(git_records "$PUSH_CWD")
  [ "$PUSH_COARSE" = 1 ] && coarse_check
  # Last: it is the only gate here that reads the index and working tree, so
  # the string rules and the push gate refuse their cases first (this one only warns).
  conflict_marker_gate
fi

exit 0
