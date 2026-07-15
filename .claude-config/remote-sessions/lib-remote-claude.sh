#!/usr/bin/env bash
# Shared library for remote-controlled Claude sessions.
# Sourced by start-remote-claude.sh (@reboot boot) and new-remote-claude.sh (on-demand).
# Single source of truth for naming, launching, resume-vs-create, and the session registry.
# Paths derive from $HOME; override any of them via the RC_* env vars below.
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

ENVFILE="${RC_ENVFILE:-$HOME/.claude-mcp.env}"          # optional MCP secrets; sourced with 2>/dev/null (may not exist)
DEFAULT_WORKDIR="${RC_DEFAULT_WORKDIR:-$HOME}"
REGISTRY="${RC_REGISTRY:-$HOME/.claude-remote-sessions.tsv}"           # live — boot script launches these. NAME<TAB>WORKDIR<TAB>SESSION_ID[<TAB>CONFIG_DIR]
ARCHIVE="${RC_ARCHIVE:-$HOME/.claude-remote-sessions.archive.tsv}"    # parked — same schema, IGNORED on boot; revivable with full history

# CONFIG_DIR (optional 4th column) enables a SECONDARY Claude Code profile. A session launched under
# CLAUDE_CONFIG_DIR=<dir> (e.g. a personal account beside a work one) keeps its transcript under
# <dir>/projects, so resume must search there and relaunch with that env — otherwise the session silently
# starts FRESH under the default profile. Empty/missing 4th column means the default $HOME/.claude profile;
# every reader tolerates 3-column rows ($4 absent -> default).

# Sessions the boot script always guarantees (self-healing). Defined here so the boot loop and the
# archive guard share one source of truth — a guaranteed name must never be archived (boot re-seeds
# it with a fresh id, which would orphan its archived history).
RC_GUARANTEED_NAMES=(  )  # sessions the boot script always keeps registered + running; e.g. ( "Main" )
rc_is_guaranteed() {  # arg: name -> 0 if guaranteed
  local n; for n in "${RC_GUARANTEED_NAMES[@]}"; do [ "$n" = "$1" ] && return 0; done; return 1
}

# Title-Case each word, hyphen-join (Life / Kali-Yoga / Development). Preserves existing caps.
# Strips everything outside [A-Za-z0-9-]: quotes would break the launch line rc_launch builds,
# and dots/colons collide with tmux's target syntax ("session:window.pane").
rc_normalize_name() {
  printf '%s' "$1" | tr ' _' '--' | tr -cd 'A-Za-z0-9-' \
    | awk -F'-' 'BEGIN{OFS="-"}{for(i=1;i<=NF;i++)if(length($i)>0)$i=toupper(substr($i,1,1)) substr($i,2);print}' \
    | sed 's/--*/-/g; s/^-//; s/-$//'
}

# Kernel-native UUID — no python3 dependency (pyenv shim won't resolve in a bare @reboot cron env).
rc_new_uuid() { cat /proc/sys/kernel/random/uuid; }

# Does a transcript for this session-id exist on disk? (encoding-agnostic — searches all project dirs.)
# args: session_id [config_dir] — searches <config_dir>/projects so secondary profiles resolve; an empty
# or absent config_dir falls back to the default $HOME/.claude.
rc_transcript_exists() {
  local sid="$1" cfg="${2:-}"; [ -n "$cfg" ] || cfg="$HOME/.claude"
  find "$cfg/projects" -maxdepth 2 -name "$sid.jsonl" -print -quit 2>/dev/null | grep -q .
}

# Registry helpers -----------------------------------------------------------
rc_lookup() {  # arg: name -> prints "WORKDIR<TAB>SESSION_ID<TAB>CONFIG_DIR" (empty if absent). $4 absent -> empty CONFIG_DIR (default profile).
  [ -f "$REGISTRY" ] || return 0
  awk -F'\t' -v n="$1" '$1==n {print $2"\t"$3"\t"$4; exit}' "$REGISTRY"
}
rc_register() {  # args: name workdir session_id [config_dir]  (upsert). Empty config_dir writes a clean 3-column row (default profile).
  touch "$REGISTRY"
  local tmp; tmp="$(mktemp)"
  awk -F'\t' -v n="$1" '$1!=n && NF>0' "$REGISTRY" > "$tmp"
  if [ -n "${4:-}" ]; then
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$tmp"
  else
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$tmp"
  fi
  mv "$tmp" "$REGISTRY"
}
rc_deregister() {  # arg: name  (stop it returning on reboot)
  [ -f "$REGISTRY" ] || return 0
  local tmp; tmp="$(mktemp)"
  awk -F'\t' -v n="$1" '$1!=n' "$REGISTRY" > "$tmp"
  mv "$tmp" "$REGISTRY"
}

# Launch (or resume) ONE session in a fresh detached tmux session.
# args: name workdir session_id [config_dir] ; echoes an OK/ERR/SKIP status line.
# All tmux -t targets in this lib use "=$name" (exact match): bare names
# unique-prefix-match in tmux, so with prefix families like Dev/Dev2 or
# Ops/Opswork a bare -t can hit (or kill) the WRONG session.
# A non-default config_dir launches the in-tmux command under CLAUDE_CONFIG_DIR=<dir> so a secondary
# profile resumes its OWN transcript instead of silently starting fresh under the default profile.
rc_launch() {
  local name="$1" workdir="$2" sid="$3" cfg="${4:-}"
  if tmux has-session -t "=$name" 2>/dev/null; then
    echo "SKIP name=$name (already running)"; return 0
  fi
  [ -d "$workdir" ] || { echo "ERR_DIR name=$name dir=$workdir (skipped)" >&2; return 4; }

  local cfgdir="$cfg"; [ -n "$cfgdir" ] || cfgdir="$HOME/.claude"

  local launchflag mode
  if rc_transcript_exists "$sid" "$cfgdir"; then
    launchflag="-r '$sid'";           mode="resume"
  else
    launchflag="--session-id '$sid'"; mode="create"
  fi

  # Prefix CLAUDE_CONFIG_DIR only for a non-default profile — the default launch line stays byte-identical.
  local cfgprefix="" profile="default"
  if [ "$cfgdir" != "$HOME/.claude" ]; then
    cfgprefix="CLAUDE_CONFIG_DIR='$cfgdir' "
    profile="$(basename "$cfgdir")"
  fi

  tmux new-session -d -s "$name" -c "$workdir"
  tmux send-keys -t "=$name" "set -a; source '$ENVFILE' 2>/dev/null; set +a; ${cfgprefix}claude --remote-control '$name' $launchflag" Enter
  # First-run "enable project MCP servers?" prompt (create only); Enter accepts it. No-op on resume.
  sleep 10
  tmux send-keys -t "=$name" Enter
  sleep 2

  local cwd; cwd="$(tmux display-message -p -t "=$name" -F '#{pane_current_path}' 2>/dev/null)"
  echo "OK name=$name cwd=${cwd:-unknown} session_id=$sid mode=$mode profile=$profile remote_control=on"
}

# Archive helpers ------------------------------------------------------------
# Archiving parks a session: its row moves from the live registry to the archive file (so the boot
# script no longer launches it) and its running tmux session is killed (so it leaves your phone/desktop).
# Nothing is destroyed — the transcript persists on disk keyed by session-id, and the archive row keeps
# the exact id + workdir needed to revive it later with full history.

# Resolve any user-typed name (any case/spacing) to the actual stored NAME in a registry file, by a
# canonical key (lowercase, spaces/underscores -> hyphens, collapsed). Exact stored casing is returned,
# so acronyms like "MCP-Dev-Lab" match "mcp dev lab". Prints the stored name, empty if no match.
rc_resolve_name() {  # args: input_name file
  [ -f "$2" ] || return 0
  awk -F'\t' -v raw="$1" '
    function canon(s){ gsub(/[ _]/,"-",s); s=tolower(s); gsub(/-+/,"-",s); sub(/^-/,"",s); sub(/-$/,"",s); return s }
    BEGIN{ k=canon(raw) }
    NF>0 && canon($1)==k { print $1; exit }
  ' "$2"
}

rc_archive() {  # arg: name (any casing/spacing) — live registry -> archive, kill tmux. Preserves id + workdir + history.
  local input="$1" name
  name="$(rc_resolve_name "$input" "$REGISTRY")"
  if [ -z "$name" ]; then
    local aname; aname="$(rc_resolve_name "$input" "$ARCHIVE")"
    if [ -n "$aname" ]; then echo "SKIP name=$aname (already archived)"; return 0; fi
    echo "ERR_NOT_FOUND name=$input (not in live registry)" >&2; return 6
  fi
  if rc_is_guaranteed "$name"; then
    echo "ERR_GUARANTEED name=$name (guaranteed session — boot re-seeds it fresh; archiving would orphan its history)" >&2
    return 5
  fi
  local row workdir sid cfg
  row="$(rc_lookup "$name")"   # WORKDIR<TAB>SESSION_ID<TAB>CONFIG_DIR
  workdir="$(printf '%s' "$row" | cut -f1)"
  sid="$(printf '%s' "$row" | cut -f2)"
  cfg="$(printf '%s' "$row" | cut -f3)"
  # upsert into archive (dedupe by name), then drop from the live registry. Carry CONFIG_DIR through so a
  # parked secondary-profile session revives under its own profile.
  touch "$ARCHIVE"
  local tmp; tmp="$(mktemp)"
  awk -F'\t' -v n="$name" '$1!=n && NF>0' "$ARCHIVE" > "$tmp"
  if [ -n "$cfg" ]; then
    printf '%s\t%s\t%s\t%s\n' "$name" "$workdir" "$sid" "$cfg" >> "$tmp"
  else
    printf '%s\t%s\t%s\n' "$name" "$workdir" "$sid" >> "$tmp"
  fi
  mv "$tmp" "$ARCHIVE"
  rc_deregister "$name"
  local tmuxstate="not running"
  if tmux has-session -t "=$name" 2>/dev/null; then
    tmux kill-session -t "=$name" && tmuxstate="killed"
  fi
  echo "OK archived name=$name session_id=$sid workdir=$workdir tmux=$tmuxstate (revive: archive-remote-claude.sh revive $name)"
}

rc_revive() {  # arg: name (any casing/spacing) — archive -> live registry, then launch now (resumes history via -r).
  local input="$1" name
  name="$(rc_resolve_name "$input" "$ARCHIVE")"
  if [ -z "$name" ]; then
    local lname; lname="$(rc_resolve_name "$input" "$REGISTRY")"
    if [ -n "$lname" ]; then echo "SKIP name=$lname (already live, not archived)"; return 0; fi
    echo "ERR_NOT_FOUND name=$input (not in archive)" >&2; return 6
  fi
  local row workdir sid cfg
  row="$(awk -F'\t' -v n="$name" '$1==n {print $2"\t"$3"\t"$4; exit}' "$ARCHIVE")"
  workdir="$(printf '%s' "$row" | cut -f1)"
  sid="$(printf '%s' "$row" | cut -f2)"
  cfg="$(printf '%s' "$row" | cut -f3)"
  rc_register "$name" "$workdir" "$sid" "$cfg"    # back onto the live registry (returns on reboot again)
  local tmp; tmp="$(mktemp)"                      # remove from archive
  awk -F'\t' -v n="$name" '$1!=n' "$ARCHIVE" > "$tmp"
  mv "$tmp" "$ARCHIVE"
  rc_launch "$name" "$workdir" "$sid" "$cfg"      # launches now; resumes since the transcript exists (under its profile)
}

rc_archive_list() {  # print parked sessions: NAME  WORKDIR  SESSION_ID  PROFILE (config dir, "(default)" when unset)
  [ -f "$ARCHIVE" ] && [ -s "$ARCHIVE" ] || { echo "(no archived sessions)"; return 0; }
  awk -F'\t' 'NF>0 {printf "%-42s %-28s %-38s %s\n", $1, $2, $3, ($4==""?"(default)":$4)}' "$ARCHIVE"
}

# Locate a session's transcript file (echoes the path, empty if none). Mirror of
# rc_transcript_exists but returns the path so callers can stat it.
rc_transcript_path() {  # args: session_id [config_dir]
  local sid="$1" cfg="${2:-}"; [ -n "$cfg" ] || cfg="$HOME/.claude"
  find "$cfg/projects" -maxdepth 2 -name "$sid.jsonl" -print -quit 2>/dev/null
}

# Health view of the LIVE registry — the surface that actually boot-resumes. For each row shows a
# STATUS flag, transcript age, whether it is really in tmux, and its profile, so stale/zombie rows
# that would silently reboot into old context are visible at a glance. Read-only: parks nothing.
#   ZOMBIE  in the registry but NOT in tmux -> reboot spawns a fresh/old session from its id
#   STALE   transcript older than RC_STALE_DAYS (default 7) -> likely a finished purpose left unparked
#   IDLE    live in tmux but not attached (normal for a background session)
#   OK      live + attached (or freshly active)
# Also flags case/format COLLISIONS: >1 live tmux session normalizing to one registry name (only the
# canonically-named one may hold the row; a stray like "dev" vs "Dev" would otherwise clobber it).
rc_sweep() {
  local stale_days="${RC_STALE_DAYS:-7}" now; now="$(date +%s)"
  echo "LIVE registry ($REGISTRY) — these boot-resume on reboot:"
  if [ ! -s "$REGISTRY" ]; then
    echo "  (empty — nothing boots)"
  else
    printf '  %-8s %-24s %-5s %-6s %-9s %s\n' STATUS NAME AGE TMUX PROFILE SESSION_ID
    while IFS=$'\t' read -r name workdir sid cfg; do
      [ -z "${name:-}" ] && continue
      case "$name" in \#*) continue ;; esac
      local cfgdir tp mt age_days age tmuxstate status prof
      cfgdir="$cfg"; [ -n "$cfgdir" ] || cfgdir="$HOME/.claude"
      tp="$(rc_transcript_path "$sid" "$cfgdir")"
      if [ -n "$tp" ]; then
        mt="$(date -r "$tp" +%s 2>/dev/null || echo "$now")"
        age_days="$(( (now - mt) / 86400 ))"; age="${age_days}d"
      else
        mt="$now"; age_days=0; age="-"
      fi
      if tmux has-session -t "=$name" 2>/dev/null; then
        if [ "$(tmux display-message -p -t "=$name" '#{session_attached}' 2>/dev/null)" = "1" ]; then
          tmuxstate="live*"   # attached
        else
          tmuxstate="live"
        fi
      else
        tmuxstate="gone"
      fi
      # status priority: ZOMBIE (not in tmux) > STALE (old transcript) > IDLE (detached) > OK
      if [ "$tmuxstate" = "gone" ]; then
        status="ZOMBIE"
      elif [ -n "$tp" ] && [ "$age_days" -ge "$stale_days" ]; then
        status="STALE"
      elif [ "$tmuxstate" = "live" ]; then
        status="IDLE"
      else
        status="OK"
      fi
      if [ -n "$cfg" ]; then prof="$(basename "$cfg")"; prof="${prof#.claude-}"; [ "$prof" = ".claude" ] && prof="default"; else prof="default"; fi
      printf '  %-8s %-24s %-5s %-6s %-9s %s\n' "$status" "$name" "$age" "$tmuxstate" "$prof" "${sid:0:8}"
    done < "$REGISTRY"
  fi

  # Collision scan: multiple LIVE tmux sessions whose raw names normalize to the same registry name.
  if command -v tmux >/dev/null 2>&1; then
    local collisions
    collisions="$(tmux list-sessions -F '#{session_name}' 2>/dev/null | while read -r s; do
        [ -n "$s" ] && printf '%s\t%s\n' "$(rc_normalize_name "$s")" "$s"
      done | awk -F'\t' '{c[$1]++; raw[$1]=raw[$1] " [" $2 "]"} END{for(k in c) if(c[k]>1) printf "  %s  <- %s\n", k, raw[k]}')"
    if [ -n "$collisions" ]; then
      echo
      echo "COLLISIONS (multiple live tmux sessions map to one registry name — park/rename the stray):"
      printf '%s\n' "$collisions"
    fi
  fi

  local acount=0
  [ -f "$ARCHIVE" ] && acount="$(awk 'NF>0' "$ARCHIVE" | grep -c .)"
  echo
  echo "Archived (parked, do NOT boot): $acount   —   park a live one: archive-remote-claude.sh archive <name>"
}
