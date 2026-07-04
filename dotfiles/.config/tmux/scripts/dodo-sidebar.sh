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

_preview() {
  local line="$1"
  local name; name="$(_name_from_row "$line")"
  [[ -z "$name" ]] && return 0
  local path="$WORKTREES_DIR/$name"
  local branch=""
  [[ -e "$path/.git" ]] && branch=$(git -C "$path" branch --show-current 2>/dev/null || echo "")

  echo "╭─ 🐦 $name ─╮"
  printf "  🌿 %s\n" "${branch:-—}"

  local pr_state ci ci_detail threads pr_url pr_number updated
  pr_state="$(_cache_get "$branch" pr_state)"
  ci="$(_cache_get "$branch" ci)"
  ci_detail="$(_cache_get "$branch" ci_detail)"
  threads="$(_cache_get "$branch" unresolved_threads)"
  pr_url="$(_cache_get "$branch" pr_url)"
  pr_number="$(_cache_get "$branch" pr_number)"
  updated="$(_cache_get "$branch" updated_at)"

  # Branch/PR state line
  local merged="no"
  if [[ -n "$branch" && "$branch" != master && "$branch" != main ]] \
     && git -C "$DODO_DIR" merge-base --is-ancestor "$branch" master 2>/dev/null; then
    merged="yes"
  fi
  local has_remote; has_remote="$(_cache_get "$branch" has_remote)"; [[ -z "$has_remote" ]] && has_remote="no"
  local state; state="$(_classify_branch_state "$merged" "$has_remote" "${pr_state:-none}")"
  case "$state" in
    merged)    printf "  🟢 merged into master\n" ;;
    review)    printf "  👀 In review · PR #%s\n" "${pr_number:-?}" ;;
    tracked)   printf "  ⬆ tracked (pushed, no PR)\n" ;;
    untracked) printf "  ◽ untracked (local only)\n" ;;
  esac
  [[ -n "$pr_url" ]] && printf "     %s\n" "$pr_url"

  # CI
  case "$ci" in
    passing) printf "  ✅ CI passing\n" ;;
    failing) printf "  ❌ CI failing: %s\n" "${ci_detail:-?}" ;;
    running) printf "  🟡 CI running\n" ;;
    *)       : ;;
  esac
  [[ -n "$threads" && "$threads" -gt 0 ]] 2>/dev/null && printf "  💬 %s unresolved review thread(s)\n" "$threads"
  [[ -n "$updated" ]] && printf "  ⏱ gh cache: %s\n" "$updated"

  # Local git state
  if [[ -e "$path/.git" ]]; then
    local dirty; dirty=$(git -C "$path" status --porcelain 2>/dev/null || true)
    if [[ -n "$dirty" ]]; then
      printf "  📝 dirty · %s file(s)\n" "$(wc -l <<<"$dirty" | tr -d ' ')"
    else
      printf "  ✨ clean\n"
    fi
    echo ""
    echo "  📝 recent commits:"
    git -C "$path" log --oneline -5 2>/dev/null | sed 's/^/    /'
  fi
  echo "╰─────────────╯"

  # Live session capture
  if tmux has-session -t "$name" 2>/dev/null; then
    echo ""
    echo "╭─ 📺 live ─╮"
    local pane_info win_name pane_id
    for pane_info in $(tmux list-panes -s -t "$name" -F "#{window_name}:#{pane_id}" 2>/dev/null); do
      win_name="${pane_info%%:*}"; pane_id="${pane_info#*:}"
      echo "  🪟 $win_name"
      tmux capture-pane -t "$pane_id" -p 2>/dev/null | tail -12 | sed 's/^/    /'
      echo ""
    done
    echo "╰──────────╯"
  fi
}

# Enter: open/attach the selected worktree (asks dev-server questions if new).
_open() {
  local name; name="$(_name_from_row "$*")"
  [[ -z "$name" ]] && return 0
  open_worktree_session "$name" "$WORKTREES_DIR/$name"
}

# ^r: force-refresh gh cache for the selected row's branch, synchronously.
_refresh_row() {
  local name; name="$(_name_from_row "$*")"
  [[ -z "$name" ]] && return 0
  "$HERE/dodo-gh-daemon.sh" --refresh "$name" >/dev/null 2>&1 || true
}

# ^n: new worktree via the palette (choose "New Dodo Worktree").
# Runs under fzf's `execute` binding, which grants a real tty — so do NOT
# redirect its output or the palette's own fzf UI breaks.
_new() {
  "$HERE/dodo-palette.sh" || true
}

# ^x: remove the selected worktree if safe (delegates to gw; git refuses dirty).
_remove() {
  local name; name="$(_name_from_row "$*")"
  [[ -z "$name" ]] && return 0
  tmux has-session -t "$name" 2>/dev/null && return 0   # never remove an open agent
  (cd "$DODO_DIR" && "$GW" delete "$name" >/dev/null 2>&1) || true
  rm -f "$LAST_OPENED_DIR/$name" 2>/dev/null || true
}

VIEW_FILE="$WORKFLOW_DIR/.sidebar-view"

# --current: render whichever view is active (default list vs browse-all).
_current() {
  local v="list"; [[ -f "$VIEW_FILE" ]] && v="$(cat "$VIEW_FILE" 2>/dev/null || echo list)"
  case "$v" in all) _list_all ;; *) _list ;; esac
}

# _run_fzf <mode>   mode: pane (embedded, narrow, list-only) | popup (launcher w/ preview)
#
# Both use `--listen 0` so each instance gets its own auto-assigned port — this
# lets many agent sidebars run at once without colliding. A background loop reads
# that port (written by the fzf `start` binding) and reloads the current view
# every 3s while in the default list view (never on a timer in browse-all).
_run_fzf() {
  local mode="$1"
  mkdir -p "$WORKFLOW_DIR"
  echo list > "$VIEW_FILE"

  # Auto-refresh interval (seconds). Set DODO_REFRESH_SECS=off (or 0) to disable
  # live updates entirely and only refresh on keypress (^r) or view change.
  local interval="${DODO_REFRESH_SECS:-3}"
  local pf lf; pf="$(mktemp)"; lf="$(mktemp)"
  local refresher=""
  if [[ "$interval" != "off" && "$interval" != "0" ]]; then
    # Only pushes a redraw when the list CONTENT actually changed — so the pane
    # sits still when nothing's happening, and updates the instant a status flips.
    ( for _ in $(seq 1 50); do [[ -s "$pf" ]] && break; sleep 0.1; done
      local port; port="$(cat "$pf" 2>/dev/null)"; [[ -z "$port" ]] && exit 0
      local last="" cur
      while sleep "$interval"; do
        [[ "$(cat "$VIEW_FILE" 2>/dev/null || echo list)" == "list" ]] || continue
        cur="$("$HERE/dodo-sidebar.sh" --list 2>/dev/null)"
        [[ "$cur" == "$last" ]] && continue          # unchanged → no repaint
        last="$cur"
        printf '%s' "$cur" > "$lf"
        curl -s -XPOST "localhost:$port" -d "reload(cat '$lf')" >/dev/null 2>&1 || break
      done ) &
    refresher=$!
  fi
  # shellcheck disable=SC2064
  trap "[[ -n '$refresher' ]] && kill $refresher 2>/dev/null; rm -f '$pf' '$lf'" EXIT

  local -a args=(
    --ansi --listen 0 --track --no-sort --no-multi --reverse
    --border rounded --border-label ' 🐦 dodo '
    --color='header:italic:blue,border:blue,label:blue'
    --bind "start:execute-silent(echo \$FZF_PORT > '$pf')"
    --bind "ctrl-n:execute($HERE/dodo-sidebar.sh --new)+reload($HERE/dodo-sidebar.sh --current)"
    --bind "ctrl-x:execute-silent($HERE/dodo-sidebar.sh --remove {})+reload($HERE/dodo-sidebar.sh --current)"
    --bind "ctrl-r:execute-silent($HERE/dodo-sidebar.sh --refresh-row {})+reload($HERE/dodo-sidebar.sh --current)"
    --bind "/:execute-silent(echo all > '$VIEW_FILE')+reload($HERE/dodo-sidebar.sh --list-all)"
    --bind "esc:execute-silent(echo list > '$VIEW_FILE')+reload($HERE/dodo-sidebar.sh --list)"
  )

  if [[ "$mode" == "pane" ]]; then
    # Narrow, embedded to the left of an agent's claude window. No inline preview
    # (too little room); full detail on demand via ^p in a popup. Enter switches
    # to the selected agent — whose own claude window also carries this sidebar.
    args+=(
      --prompt '❯ '
      --header $'🐦 agents\n↵ go · ^n new · ^x rm\n^r sync · / all · ^p info'
      --header-first
      --bind "enter:execute($HERE/dodo-sidebar.sh --open {})"
      --bind "ctrl-p:execute(tmux display-popup -E -w 80% -h 80% \"$HERE/dodo-sidebar.sh --preview-popup {}\")"
    )
  else
    # Launcher popup (prefix+a from anywhere): list + preview; enter opens and closes.
    args+=(
      --prompt '  ❯ '
      --header $'  🐦 dodo agents\n  ↵ open · ^n new · ^x rm · ^r sync · / browse all · esc back\n  🔔 input · ⚙ working · 💤 off  ·  ◽⬆👀🟢 state  ·  ✅❌🟡 ci · 💬 threads\n'
      --header-first --padding 1
      --preview "$HERE/dodo-sidebar.sh --preview {}"
      --preview-window 'right:60%:wrap'
      --bind "enter:execute($HERE/dodo-sidebar.sh --open {})+accept"
    )
  fi

  "$HERE/dodo-sidebar.sh" --list | fzf "${args[@]}" || true
}

case "${1:-}" in
  --list)      _list ;;
  --list-all)  _list_all ;;
  --name-from) shift; _name_from_row "$*" ;;
  --preview)   shift; _preview "$*" ;;
  --preview-popup) shift; _preview "$*"; printf '\n  (press any key to close)'; read -rsn1 ;;
  --open)      shift; _open "$*" ;;
  --refresh-row) shift; _refresh_row "$*" ;;
  --new)       _new ;;
  --remove)    shift; _remove "$*" ;;
  --current)   _current ;;
  --pane)      _run_fzf pane ;;
  --popup|--ui|"") _run_fzf popup ;;
esac
