#!/usr/bin/env bash
# sync-check.sh — walk PROJECTS/ git repos, fetch from remote, rebase,
# and shepherd uncommitted changes safely through the update.
# Linux port of Sync-Check.ps1.
#
# Usage:
#   ./sync-check.sh           interactive (default)
#   ./sync-check.sh --auto    non-interactive: skip dirty repos, no prompts

PROJECTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
SEPARATOR="$(printf '%.0s-' {1..70})"

AUTO=0
for arg in "$@"; do
  case "$arg" in
    --auto) AUTO=1 ;;
    -h|--help)
      sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown arg: $arg" >&2
      exit 2
      ;;
  esac
done

# Colors only when stdout is a tty
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'
  C_CYAN=$'\e[36m'
  C_GREEN=$'\e[32m'
  C_YELLOW=$'\e[33m'
  C_RED=$'\e[31m'
  C_GRAY=$'\e[90m'
  C_WHITE=$'\e[97m'
  C_BOLD=$'\e[1m'
else
  C_RESET=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_GRAY=""; C_WHITE=""; C_BOLD=""
fi

status()  { printf "%s%s%s\n" "$2" "$1" "$C_RESET"; }
explain() { printf "    %s(explain) %s%s\n" "$C_GRAY" "$1" "$C_RESET"; }
action()  { printf "    %s-> %s%s\n" "$C_CYAN" "$1" "$C_RESET"; }
good()    { printf "    %s[OK] %s%s\n" "$C_GREEN" "$1" "$C_RESET"; }
warn()    { printf "    %s[!!] %s%s\n" "$C_YELLOW" "$1" "$C_RESET"; }
bad()     { printf "    %s[XX] %s%s\n" "$C_RED" "$1" "$C_RESET"; }
info()    { printf "    %s%s%s\n" "$C_GRAY" "$1" "$C_RESET"; }

# read_choice "prompt" "K:description" "K2:description" ...
read_choice() {
  local prompt="$1"; shift
  local -a opts=("$@")
  local response entry
  while true; do
    echo
    printf "    %s%s%s\n" "$C_WHITE" "$prompt" "$C_RESET"
    for entry in "${opts[@]}"; do
      printf "      %s[%s] %s%s\n" "$C_GRAY" "${entry%%:*}" "${entry#*:}" "$C_RESET"
    done
    read -r -p "    Choice: " response
    response="$(echo "$response" | tr '[:lower:]' '[:upper:]' | xargs)"
    for entry in "${opts[@]}"; do
      if [[ "$response" == "${entry%%:*}" ]]; then
        echo "$response"
        return 0
      fi
    done
    printf "    %s(not a valid option, try again)%s\n" "$C_YELLOW" "$C_RESET"
  done
}

declare -a sum_synced=() sum_clean=() sum_attn=() sum_skipped=() sum_stashes=()

echo
status "GIT SYNC — $(date '+%Y-%m-%d %H:%M')" "$C_CYAN$C_BOLD"
status "$SEPARATOR" "$C_GRAY"
echo "What this does: for each project, it checks if the server has"
echo "newer changes, then updates your local copy. If you have unsaved"
echo "edits, it tucks them aside first so nothing gets lost."
[[ $AUTO -eq 1 ]] && status "(auto mode: no prompts, dirty+behind repos skipped)" "$C_GRAY"
echo

# Discover repos at any depth under PROJECTS_ROOT. A repo is any directory
# whose immediate child is a `.git` entry (dir for normal repos, file for
# worktrees/submodule pointers). -prune stops find from descending into .git.
mapfile -t REPOS < <(
  find "$PROJECTS_ROOT" -mindepth 2 \( -name .git \) \
       \( -type d -o -type f \) -prune -printf '%h\n' \
    | sort
)

for dir in "${REPOS[@]}"; do
  # Display name = path relative to PROJECTS_ROOT (e.g. "ExampleOrg/sample-app").
  # Falls back to basename if the repo somehow sits at the root.
  if [[ "$dir" == "$PROJECTS_ROOT"/* ]]; then
    name="${dir#"$PROJECTS_ROOT"/}"
  else
    name="$(basename "$dir")"
  fi

  status "[$name]" "$C_YELLOW$C_BOLD"

  action "Asking the server what's new..."
  explain "This doesn't change anything yet — it just downloads info."
  if ! fetch_out=$(git -C "$dir" fetch --all --prune 2>&1); then
    bad "Couldn't reach the server: $fetch_out"
    sum_skipped+=("$name")
    echo
    continue
  fi

  if ! branch=$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null); then
    warn "This repo isn't on a branch right now (detached state). Skipping."
    explain "Usually happens if you checked out a specific commit. Not dangerous, just unusual."
    sum_skipped+=("$name")
    echo
    continue
  fi

  if ! upstream=$(git -C "$dir" rev-parse --abbrev-ref "${branch}@{upstream}" 2>/dev/null); then
    warn "Branch '$branch' isn't connected to any server branch. Nothing to sync against."
    explain "You'd fix this with: git push -u origin $branch"
    sum_attn+=("$name (no upstream on $branch)")
    echo
    continue
  fi

  counts=$(git -C "$dir" rev-list --left-right --count "${branch}...${upstream}" 2>/dev/null || echo "0	0")
  ahead="${counts%%[[:space:]]*}"
  behind="${counts##*[[:space:]]}"
  [[ -z "$ahead" ]] && ahead=0
  [[ -z "$behind" ]] && behind=0

  dirty=$(git -C "$dir" status --porcelain 2>/dev/null)
  if [[ -n "$dirty" ]]; then
    uncommitted_count=$(printf "%s\n" "$dirty" | wc -l | xargs)
    is_dirty=1
  else
    uncommitted_count=0
    is_dirty=0
  fi

  info "Branch: $branch <-> $upstream"
  [[ "$ahead"  -gt 0 ]] && info "You have $ahead local commit(s) the server doesn't."
  [[ "$behind" -gt 0 ]] && info "Server has $behind commit(s) you don't."
  [[ $is_dirty -eq 1 ]] && info "You have $uncommitted_count uncommitted change(s) sitting locally."

  if [[ "$ahead" -eq 0 && "$behind" -eq 0 && $is_dirty -eq 0 ]]; then
    good "Already in sync. Nothing to do."
    sum_clean+=("$name")
    echo
    continue
  fi

  # Not behind — report and move on (match Windows: don't stash when there's nothing to rebase against)
  if [[ "$behind" -eq 0 ]]; then
    if [[ "$ahead" -gt 0 ]]; then
      good "You're ahead of the server. No rebase needed."
      explain "When you're ready to share these commits: git push"
    fi
    if [[ $is_dirty -eq 1 ]]; then
      warn "You have $uncommitted_count uncommitted change(s). Leaving them alone."
      explain "Nothing on the server to reconcile with, so no need to shelve them."
      sum_attn+=("$name (uncommitted changes)")
    else
      sum_clean+=("$name")
    fi
    echo
    continue
  fi

  # Auto mode: never touch a dirty tree that needs a rebase
  if [[ $AUTO -eq 1 && $is_dirty -eq 1 ]]; then
    warn "Dirty tree + behind. Auto mode skips this — run interactively to resolve."
    sum_attn+=("$name (dirty + behind, auto-skipped)")
    echo
    continue
  fi

  stash_ref=""
  stash_label=""
  if [[ $is_dirty -eq 1 ]]; then
    action "Shelving your uncommitted changes so the update can happen safely..."
    explain "In git terms this is called a 'stash'. Think of it as a labeled drawer."
    stash_label="sync-check-$name-$TIMESTAMP"
    if ! stash_out=$(git -C "$dir" stash push -u -m "$stash_label" 2>&1); then
      bad "Couldn't shelve changes: $stash_out"
      sum_attn+=("$name (stash failed)")
      echo
      continue
    fi
    stash_ref=$(git -C "$dir" stash list | grep -F "$stash_label" | head -n1 | sed -E 's/^(stash@\{[0-9]+\}).*/\1/')
    good "Changes shelved as: $stash_label"
  fi

  if [[ "$ahead" -gt 0 ]]; then
    action "Your history and the server's have diverged. Replaying your $ahead local commit(s) on top of the server's latest..."
    explain "This is a 'rebase'. Your local commits get re-applied one by one onto the newest server version, so history stays clean."
  else
    action "Updating your branch to match the server's latest..."
    explain "Fast-forward: no conflict possible, just catching up."
  fi

  if ! rebase_out=$(git -C "$dir" rebase "$upstream" 2>&1); then
    bad "Update hit a conflict and was cancelled. Your repo is back to how it was."
    explain "A conflict means the same lines were changed both locally and on the server. A script can't safely guess which version you want."
    git -C "$dir" rebase --abort >/dev/null 2>&1

    conflicts=$(printf "%s\n" "$rebase_out" | grep -i "CONFLICT" || true)
    if [[ -n "$conflicts" ]]; then
      printf "    %sConflicting files:%s\n" "$C_YELLOW" "$C_RESET"
      while IFS= read -r line; do printf "      %s%s%s\n" "$C_YELLOW" "$line" "$C_RESET"; done <<< "$conflicts"
    fi

    if [[ -n "$stash_ref" ]]; then
      action "Putting your shelved changes back so you're exactly where you started..."
      if git -C "$dir" stash pop "$stash_ref" >/dev/null 2>&1; then
        good "Shelved changes restored."
      else
        warn "Couldn't auto-restore the shelf. Run this manually: git stash pop $stash_ref"
        sum_stashes+=("$name ($stash_label)")
      fi
    fi

    sum_attn+=("$name (rebase conflict — manual resolution needed)")
    echo
    continue
  fi

  good "Update applied cleanly."

  if [[ -n "$stash_ref" ]]; then
    if [[ $AUTO -eq 1 ]]; then
      sum_stashes+=("$name ($stash_label)")
    else
      decided=0
      while [[ $decided -eq 0 ]]; do
        choice=$(read_choice "Your shelved changes are still tucked away. What do you want to do with them?" \
          "P:Put them back in the project (most common — you keep working)" \
          "K:Leave them on the shelf for later (see them with: git stash list)" \
          "D:Discard them permanently (you don't want these edits anymore)" \
          "V:Show me the shelved changes first, then ask again")
        case "$choice" in
          P)
            action "Putting shelved changes back..."
            explain "git calls this 'stash pop'."
            if git -C "$dir" stash pop "$stash_ref" >/dev/null 2>&1; then
              good "Done. Your edits are back in place."
            else
              warn "Putting them back caused a conflict with the newly pulled code."
              explain "Your edits and the server's updates touched the same lines. The shelf is still safe — resolve the conflict in your editor, or run: git stash drop $stash_ref to toss them."
              sum_stashes+=("$name ($stash_label)")
              sum_attn+=("$name (stash pop conflict)")
            fi
            decided=1
            ;;
          K)
            good "Left on the shelf. Recover later with: git stash pop $stash_ref"
            sum_stashes+=("$name ($stash_label)")
            decided=1
            ;;
          D)
            read -r -p "    Really discard? This can't be undone. Type YES to confirm: " confirm
            if [[ "$confirm" == "YES" ]]; then
              git -C "$dir" stash drop "$stash_ref" >/dev/null 2>&1
              good "Discarded."
              decided=1
            else
              printf "    %sCancelled. Pick again.%s\n" "$C_YELLOW" "$C_RESET"
            fi
            ;;
          V)
            echo
            printf "    %s--- Shelved changes ---%s\n" "$C_CYAN" "$C_RESET"
            git -C "$dir" stash show -p "$stash_ref" || true
            printf "    %s--- end ---%s\n" "$C_CYAN" "$C_RESET"
            ;;
        esac
      done
    fi
  fi

  sum_synced+=("$name")
  echo
done

print_section() {
  local title="$1" color="$2"; shift 2
  local count=$#
  [[ $count -eq 0 ]] && return
  printf "  %s%s (%d):%s\n" "$color" "$title" "$count" "$C_RESET"
  local it
  for it in "$@"; do
    printf "    %s- %s%s\n" "$color" "$it" "$C_RESET"
  done
}

status "$SEPARATOR" "$C_GRAY"
echo
status "SUMMARY" "$C_CYAN$C_BOLD"

print_section "Already in sync"     "$C_GREEN"  "${sum_clean[@]}"
print_section "Updated"              "$C_CYAN"   "${sum_synced[@]}"
if [[ ${#sum_stashes[@]} -gt 0 ]]; then
  print_section "Shelves left for later" "$C_YELLOW" "${sum_stashes[@]}"
  printf "    %s(see them anytime with: git stash list)%s\n" "$C_GRAY" "$C_RESET"
fi
print_section "Needs your attention" "$C_RED"    "${sum_attn[@]}"
print_section "Skipped"              "$C_GRAY"   "${sum_skipped[@]}"

echo
status "Done." "$C_GRAY"
