#!/usr/bin/env bash
# dodo-sidebar.sh — Conductor-style agent sidebar for ~/dodo/master.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/dodo-lib.sh"

# --- shared state gather (single git call) ---
declare -A WT_BRANCH
_load_branch_map() {
  WT_BRANCH=()
  local cur=""
  while IFS= read -r ln; do
    if [[ "$ln" == worktree\ * ]]; then cur="${ln#worktree }"
    elif [[ "$ln" == branch\ refs/heads/* ]]; then WT_BRANCH["$cur"]="${ln#branch refs/heads/}"; fi
  done < <(git -C "$DODO_DIR" worktree list --porcelain 2>/dev/null || true)
}

# merged set (single call)
_merged_set() {
  printf '\n%s\n' "$(git -C "$DODO_DIR" branch --merged master --format='%(refname:short)' 2>/dev/null || true)"
}

# claude working state for a live session: echoes "yes"/"no"
_claude_working() {
  local session="$1" pane content
  while IFS= read -r pane; do
    [[ -z "$pane" ]] && continue
    content=$(tmux capture-pane -t "$pane" -p 2>/dev/null | tail -8)
    [[ "$content" == *"esc to interrupt"* ]] && { echo "yes"; return; }
  done < <(tmux list-panes -s -t "$session" -F '#{pane_id}' 2>/dev/null)
  echo "no"
}

# Emit a rendered row for one worktree name.
_row_for() {
  local name="$1" merged_set="$2"
  local path="$WORKTREES_DIR/$name"
  local branch="${WT_BRANCH[$path]:-}"

  local live="no" working="no"
  if tmux has-session -t "$name" 2>/dev/null; then
    live="yes"; working="$(_claude_working "$name")"
  fi

  local merged="no" has_remote pr_state ci threads state
  if [[ -n "$branch" && "$branch" != "master" && "$branch" != "main" \
        && "$merged_set" == *$'\n'"$branch"$'\n'* ]]; then merged="yes"; fi
  has_remote="$(_cache_get "$branch" has_remote)"; [[ -z "$has_remote" ]] && has_remote="no"
  pr_state="$(_cache_get "$branch" pr_state)"; [[ -z "$pr_state" ]] && pr_state="none"
  ci="$(_cache_get "$branch" ci)"; [[ -z "$ci" ]] && ci="none"
  threads="$(_cache_get "$branch" unresolved_threads)"; [[ -z "$threads" ]] && threads=0
  state="$(_classify_branch_state "$merged" "$has_remote" "$pr_state")"

  _render_row "$name" "$working" "$live" "$state" "$ci" "$threads"
  printf '\n'
}

# names: active (tmux sessions matching a worktree dir) + recent (last-opened top 15)
_active_recent_names() {
  {
    if [[ -d "$LAST_OPENED_DIR" ]]; then
      find "$LAST_OPENED_DIR" -maxdepth 1 -type f -printf '%T@ %f\n' 2>/dev/null \
        | sort -rn | head -15 | cut -d' ' -f2-
    fi
    tmux list-sessions -F '#{session_name}' 2>/dev/null || true
  } | sort -u | while IFS= read -r n; do
        [[ -d "$WORKTREES_DIR/$n" ]] && echo "$n"
      done
}

_list() {
  _load_branch_map
  local merged_set; merged_set="$(_merged_set)"
  local name
  # ACTIVE group first (live sessions), then RECENT (rest of active+recent set).
  local -a active=() recent=()
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if tmux has-session -t "$name" 2>/dev/null; then active+=("$name"); else recent+=("$name"); fi
  done < <(_active_recent_names)

  if (( ${#active[@]} )); then
    for name in "${active[@]}"; do _row_for "$name" "$merged_set"; done
  fi
  if (( ${#recent[@]} )); then
    for name in "${recent[@]}"; do _row_for "$name" "$merged_set"; done
  fi
}

# Browse-all is a light, one-shot snapshot: local state only (no gh-cache reads,
# no per-name has-session storms). Merged is known from merged_set; everything
# else shows as a blank branch glyph. GH badges are intentionally omitted here
# (spec: browse-all is git-state only, GH lazy).
_list_all() {
  _load_branch_map
  local merged_set; merged_set="$(_merged_set)"
  local active; active=$'\n'"$(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)"$'\n'
  [[ -d "$WORKTREES_DIR" ]] || return 0
  local dir name branch live state
  for dir in "$WORKTREES_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    name="$(basename "$dir")"
    branch="${WT_BRANCH[${dir%/}]:-}"
    live="no"; [[ "$active" == *$'\n'"$name"$'\n'* ]] && live="yes"
    state=""
    if [[ -n "$branch" && "$branch" != master && "$branch" != main \
          && "$merged_set" == *$'\n'"$branch"$'\n'* ]]; then state="merged"; fi
    _render_row "$name" "no" "$live" "$state" "none" 0
    printf '\n'
  done
}

case "${1:-}" in
  --list)      _list ;;
  --list-all)  _list_all ;;
  --name-from) shift; _name_from_row "$*" ;;
esac
