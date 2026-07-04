#!/usr/bin/env bash
# ╔══════════════════════════════════════════════╗
# ║  🐦 Dodo Command Palette — Ctrl+s o         ║
# ║  Centered fzf UI for dev worktree management ║
# ║  Uses gw (git worktree manager) under the    ║
# ║  hood for all worktree operations.           ║
# ╚══════════════════════════════════════════════╝

set -euo pipefail

WORKFLOW_DIR="$HOME/.local/share/tmux-workflows"
WORKFLOW_LOG="$WORKFLOW_DIR/workflows.jsonl"
DODO_DIR="$HOME/dodo/master"
WORKTREES_DIR="$DODO_DIR/.worktrees"
GW="$HOME/.scripts/bash/gw"
LAST_OPENED_DIR="$WORKFLOW_DIR/last-opened"
SORT_STATE_FILE="$WORKFLOW_DIR/.worktree-sort-mode"
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dodo-lib.sh"

mkdir -p "$WORKFLOW_DIR" "$LAST_OPENED_DIR"

# ─── Worktree metadata helpers ──────────────────────────────────────────────

_last_opened_ts() {
  local name="$1"
  local f="$LAST_OPENED_DIR/$name"
  if [[ -f "$f" ]]; then
    stat -c %Y "$f" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

_creation_ts() {
  local name="$1"
  local path="$2"
  if [[ -f "$WORKFLOW_LOG" ]]; then
    local ts
    ts=$(python3 - "$name" "$WORKFLOW_LOG" <<'PY' 2>/dev/null || true
import sys, json
from datetime import datetime
name = sys.argv[1]
log_path = sys.argv[2]
best = 0
try:
    with open(log_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                e = json.loads(line)
            except json.JSONDecodeError:
                continue
            if e.get("folder_name") == name or e.get("ticket") == name:
                try:
                    ts = int(datetime.fromisoformat(e["created_at"]).timestamp())
                    if ts > best:
                        best = ts
                except Exception:
                    pass
except Exception:
    pass
print(best)
PY
)
    if [[ -n "$ts" && "$ts" != "0" ]]; then
      echo "$ts"
      return
    fi
  fi
  if [[ -d "$path" ]]; then
    stat -c %Y "$path" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

_is_merged() {
  local branch="$1"
  [[ -z "$branch" || "$branch" == "master" || "$branch" == "main" ]] && { echo "no"; return; }
  if git -C "$DODO_DIR" merge-base --is-ancestor "$branch" master 2>/dev/null; then
    echo "yes"
  else
    echo "no"
  fi
}

_has_dirty() {
  local path="$1"
  local out
  out=$(git -C "$path" status --porcelain 2>/dev/null || true)
  [[ -n "$out" ]] && echo "yes" || echo "no"
}

# Stashes live in the main repo, not in the per-worktree directory.
# Filter by the "(WIP )?[Oo]n <branch>:" prefix in each stash's reflog subject
# to count only entries that were created from this worktree's branch.
_stash_branches_raw() {
  git -C "$DODO_DIR" stash list --format='%gs' 2>/dev/null \
    | sed -nE 's/^(WIP )?[Oo]n ([^:]+):.*/\2/p' || true
}

_stash_count_for_branch() {
  local branch="$1"
  [[ -z "$branch" ]] && { echo 0; return; }
  local n
  n=$(_stash_branches_raw | grep -cFx "$branch" 2>/dev/null) || n=0
  echo "$n"
}

_fmt_date() {
  local ts="$1"
  if [[ -z "$ts" || "$ts" == "0" ]]; then
    echo "—"
  else
    date -d "@$ts" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "—"
  fi
}

_get_sort_mode() {
  [[ -f "$SORT_STATE_FILE" ]] && cat "$SORT_STATE_FILE" || echo "alpha"
}

_set_sort_mode() {
  echo "$1" > "$SORT_STATE_FILE"
}

_toggle_sort_mode() {
  local current next
  current=$(_get_sort_mode)
  [[ "$current" == "alpha" ]] && next="recent" || next="alpha"
  _set_sort_mode "$next"
  echo "$next"
}

# Emits one fzf line per worktree. Opened worktrees first, then closed,
# each group sorted by the given mode ("alpha" or "recent"). Tabs are
# used internally as sort keys and stripped before output.
_list_worktrees() {
  local sort_mode="${1:-alpha}"
  [[ ! -d "$WORKTREES_DIR" ]] && return 0

  # ─── Precompute repo-wide state (single git call each) ─────────────────
  local merged_set stash_branches
  merged_set=$'\n'"$(git -C "$DODO_DIR" branch --merged master --format='%(refname:short)' 2>/dev/null || true)"$'\n'
  stash_branches=$'\n'"$(_stash_branches_raw)"$'\n'

  # path → branch map from a single `git worktree list --porcelain` call
  declare -A wt_branch
  local cur_path=""
  while IFS= read -r ln; do
    if [[ "$ln" == worktree\ * ]]; then
      cur_path="${ln#worktree }"
    elif [[ "$ln" == branch\ refs/heads/* ]]; then
      wt_branch["$cur_path"]="${ln#branch refs/heads/}"
    fi
  done < <(git -C "$DODO_DIR" worktree list --porcelain 2>/dev/null || true)

  # ─── Gather worktree dirs ──────────────────────────────────────────────
  local -a names dirs
  for dir in "$WORKTREES_DIR"/*/; do
    [[ ! -d "$dir" ]] && continue
    names+=("$(basename "$dir")")
    dirs+=("${dir%/}")
  done

  # ─── Parallel: detect dirty state per worktree ────────────────────────
  local tmpdir
  tmpdir=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$tmpdir'" RETURN
  mkdir -p "$tmpdir/dirty"

  if (( ${#dirs[@]} > 0 )); then
    printf '%s\0' "${dirs[@]}" \
      | xargs -0 -P 16 -I {} bash -c '
          d="$1"; out_dir="$2"
          name=$(basename "$d")
          if [[ -n "$(git -C "$d" status --porcelain 2>/dev/null)" ]]; then
            : > "$out_dir/$name"
          fi
        ' _ {} "$tmpdir/dirty" 2>/dev/null || true
  fi

  # ─── Build lines ──────────────────────────────────────────────────────
  local opened_buf="" closed_buf=""
  local i
  for i in "${!names[@]}"; do
    local name="${names[$i]}"
    local dir="${dirs[$i]}"
    local last_ts line
    last_ts="$(_last_opened_ts "$name")"

    local branch merged stash_n prefix label color reset
    branch="${wt_branch[$dir]:-}"

    merged="no"
    if [[ -n "$branch" && "$branch" != "master" && "$branch" != "main" \
          && "$merged_set" == *$'\n'"$branch"$'\n'* ]]; then
      merged="yes"
    fi

    stash_n=0
    if [[ -n "$branch" && "$stash_branches" == *$'\n'"$branch"$'\n'* ]]; then
      stash_n=1
    fi

    # Dirty wins over stash for coloring
    color=""; reset=""
    if [[ -f "$tmpdir/dirty/$name" ]]; then
      color=$'\e[33m'; reset=$'\e[0m'
    elif [[ "$stash_n" -gt 0 ]]; then
      color=$'\e[90m'; reset=$'\e[0m'
    fi

    if tmux has-session -t "$name" 2>/dev/null; then
      prefix="📺 "
      label="opened │ $name"
      line="${prefix}${color}${label}${reset}"
      opened_buf+="$(printf '%010d\t%s\t%s' "$last_ts" "$name" "$line")"$'\n'
    else
      if [[ "$merged" == "yes" ]]; then prefix="✅ "; else prefix="   "; fi
      label="closed │ $name"
      line="${prefix}${color}${label}${reset}"
      closed_buf+="$(printf '%010d\t%s\t%s' "$last_ts" "$name" "$line")"$'\n'
    fi
  done

  local sort_cmd
  if [[ "$sort_mode" == "recent" ]]; then
    sort_cmd=(sort -t$'\t' -k1,1nr)
  else
    sort_cmd=(sort -t$'\t' -k2,2)
  fi

  if [[ -n "$opened_buf" ]]; then
    printf '%s' "$opened_buf" | "${sort_cmd[@]}" | cut -f3-
  fi
  if [[ -n "$closed_buf" ]]; then
    printf '%s' "$closed_buf" | "${sort_cmd[@]}" | cut -f3-
  fi
}

# Find worktrees that are safe to delete: merged into master, no stash on that
# branch, working tree clean, no active tmux session. Branch must not be
# master/main. Returns names via stdout, one per line.
_cleanup_candidates() {
  local merged_set stash_branches
  merged_set=$'\n'"$(git -C "$DODO_DIR" branch --merged master --format='%(refname:short)' 2>/dev/null || true)"$'\n'
  stash_branches=$'\n'"$(_stash_branches_raw)"$'\n'

  declare -A wt_branch
  local cur_path=""
  while IFS= read -r ln; do
    if [[ "$ln" == worktree\ * ]]; then
      cur_path="${ln#worktree }"
    elif [[ "$ln" == branch\ refs/heads/* ]]; then
      wt_branch["$cur_path"]="${ln#branch refs/heads/}"
    fi
  done < <(git -C "$DODO_DIR" worktree list --porcelain 2>/dev/null || true)

  for dir in "$WORKTREES_DIR"/*/; do
    [[ ! -d "$dir" ]] && continue
    local name="$(basename "$dir")"
    local path="${dir%/}"
    local branch="${wt_branch[$path]:-}"

    tmux has-session -t "$name" 2>/dev/null && continue
    [[ -z "$branch" || "$branch" == "master" || "$branch" == "main" ]] && continue
    [[ "$merged_set" != *$'\n'"$branch"$'\n'* ]] && continue
    [[ "$stash_branches" == *$'\n'"$branch"$'\n'* ]] && continue

    local dirty_out
    dirty_out=$(git -C "$path" status --porcelain 2>/dev/null || true)
    [[ -n "$dirty_out" ]] && continue

    printf '%s\t%s\n' "$name" "$branch"
  done
}

# Verify a single worktree is still safe to delete RIGHT NOW. Returns 0 if
# safe, non-zero otherwise. State can change between candidate-listing and
# deletion (user opens a session, makes a change, creates a stash), so we
# re-check every guard rail just before the destructive call.
_is_still_safe_to_delete() {
  local name="$1" branch="$2" path="$3"
  [[ -z "$branch" || "$branch" == "master" || "$branch" == "main" ]] && return 1
  [[ ! -d "$path" ]] && return 1
  tmux has-session -t "$name" 2>/dev/null && return 1
  git -C "$DODO_DIR" merge-base --is-ancestor "$branch" master 2>/dev/null || return 1
  local dirty_out
  dirty_out=$(git -C "$path" status --porcelain 2>/dev/null || true)
  [[ -n "$dirty_out" ]] && return 1
  if git -C "$DODO_DIR" stash list --format='%gs' 2>/dev/null \
     | sed -nE 's/^(WIP )?[Oo]n ([^:]+):.*/\2/p' \
     | grep -qFx "$branch"; then
    return 1
  fi
  return 0
}

# Interactive ctrl-u handler. Computes candidates, shows them, asks for
# confirmation, then deletes one-by-one with a re-check before each removal.
_cleanup_worktrees_interactive() {
  local candidates
  candidates=$(_cleanup_candidates)

  if [[ -z "$candidates" ]]; then
    printf '%s\n' "  (nothing to clean up)" "  " "  No worktree is merged + clean + stash-free + closed." \
      | fzf --header $'  🧹 Cleanup: nothing to do' \
            --reverse --border rounded --padding 1 --no-sort \
            --color='header:italic:yellow,border:yellow' \
            --bind 'esc:abort,enter:abort' >/dev/null 2>&1 || true
    return 0
  fi

  local count
  count=$(printf '%s\n' "$candidates" | wc -l | tr -d ' ')

  local listfile
  listfile=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '$listfile'" RETURN
  printf '%s\n' "$candidates" | awk -F'\t' '{ printf "  • %s  ←  %s\n", $1, $2 }' > "$listfile"

  local choice
  choice=$(printf '%s\n' \
    "❌ Cancel — do nothing" \
    "✅ Yes — delete all $count listed worktrees" | \
    fzf --ansi \
        --header "  🧹 Cleanup: $count merged + clean worktrees ready to delete"$'\n  ─────────────────────────────────────────────────\n  preview lists what will go  •  enter: confirm  •  esc: back\n' \
        --header-first \
        --prompt '  confirm ❯ ' \
        --no-sort --no-multi --reverse \
        --border rounded --border-label " 🧹 Cleanup Worktrees " --padding 1 \
        --color='header:italic:red,border:red,label:red' \
        --preview "cat '$listfile'" \
        --preview-window 'right:60%:wrap' \
        --bind 'esc:abort') || return 0

  [[ "$choice" != *"Yes"* ]] && return 0

  local deleted=0 skipped=0
  local resultfile
  resultfile=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '$listfile' '$resultfile'" RETURN

  while IFS=$'\t' read -r sel_name sel_branch; do
    [[ -z "$sel_name" ]] && continue
    local sel_path="$WORKTREES_DIR/$sel_name"

    if ! _is_still_safe_to_delete "$sel_name" "$sel_branch" "$sel_path"; then
      printf '  ⚠️  %s — skipped (state changed; no longer safe)\n' "$sel_name" >> "$resultfile"
      ((skipped++))
      continue
    fi

    # Worktree remove without --force; git itself refuses dirty trees.
    if git -C "$DODO_DIR" worktree remove "$sel_path" 2>/dev/null; then
      # Safe branch delete: -d (not -D) refuses unmerged branches as a
      # final defensive layer even though we already verified merged status.
      if git -C "$DODO_DIR" branch -d "$sel_branch" 2>/dev/null; then
        printf '  ✅ %s (branch %s)\n' "$sel_name" "$sel_branch" >> "$resultfile"
      else
        printf '  ✅ %s — worktree removed; branch %s kept (git refused -d)\n' \
          "$sel_name" "$sel_branch" >> "$resultfile"
      fi
      ((deleted++))
    else
      printf '  ⚠️  %s — git worktree remove refused\n' "$sel_name" >> "$resultfile"
      ((skipped++))
    fi
  done <<< "$candidates"

  {
    printf '  🧹 Cleanup complete\n'
    printf '  ────────────────────\n'
    printf '  deleted: %d  •  skipped: %d\n\n' "$deleted" "$skipped"
    cat "$resultfile"
    printf '\n  (enter or esc to dismiss)\n'
  } | fzf --header "" \
          --reverse --border rounded --padding 1 --no-sort --ansi \
          --color='header:italic:green,border:green' \
          --bind 'esc:abort,enter:abort' >/dev/null 2>&1 || true
}

_extract_name() {
  local line="$1"
  local clean
  clean=$(printf '%s' "$line" | sed 's/\x1b\[[0-9;]*m//g')
  echo "$clean" | sed 's/^.*│ *//' | awk '{print $1}'
}

_preview_worktree() {
  local line="$1"
  local wt_name wt_path
  wt_name=$(_extract_name "$line")
  [[ -z "$wt_name" ]] && return 0
  wt_path="$WORKTREES_DIR/$wt_name"

  echo "╭─── 📋 Worktree Info ───╮"
  printf "  📁 Name:    %s\n" "$wt_name"
  printf "  📁 Path:    %s\n" "$wt_path"

  local branch="—"
  if [[ -d "$wt_path/.git" || -f "$wt_path/.git" ]]; then
    branch=$(git -C "$wt_path" branch --show-current 2>/dev/null || echo "—")
  fi
  printf "  🌿 Branch:  %s\n" "$branch"

  local created_ts last_ts
  created_ts=$(_creation_ts "$wt_name" "$wt_path")
  last_ts=$(_last_opened_ts "$wt_name")
  printf "  📅 Created: %s\n" "$(_fmt_date "$created_ts")"
  printf "  ⏰ Opened:  %s\n" "$(_fmt_date "$last_ts")"

  local active="no"
  tmux has-session -t "$wt_name" 2>/dev/null && active="yes"

  echo ""
  echo "  Status:"
  if [[ "$active" == "yes" ]]; then
    printf "    📺 tmux session active\n"
  fi
  if [[ -d "$wt_path/.git" || -f "$wt_path/.git" ]]; then
    local merged dirty stash_n
    merged=$(_is_merged "$branch")
    dirty=$(_has_dirty "$wt_path")
    stash_n=$(_stash_count_for_branch "$branch")

    if [[ "$merged" == "yes" ]]; then
      printf "    ✅ merged to master\n"
    else
      printf "    ⛔ not merged to master\n"
    fi
    if [[ "$dirty" == "yes" ]]; then
      printf "    📝 uncommitted changes\n"
    else
      printf "    ✨ working tree clean\n"
    fi
    if [[ -n "$stash_n" && "$stash_n" -gt 0 ]]; then
      printf "    💾 %s stash entr%s\n" "$stash_n" "$([[ $stash_n -eq 1 ]] && echo y || echo ies)"
    fi

    echo ""
    echo "  📝 Recent commits:"
    git -C "$wt_path" log --oneline -5 2>/dev/null | sed "s/^/    /"
  fi
  echo "╰─────────────────────────╯"
  echo ""

  if [[ "$active" == "yes" ]]; then
    echo "╭─── 📺 Live Session ───╮"
    for pane_info in $(tmux list-panes -t "$wt_name" -a -F "#{window_name}:#{pane_id}" 2>/dev/null); do
      local win_name="${pane_info%%:*}"
      local pane_id="${pane_info#*:}"
      echo "  ── 🪟 $win_name ──"
      tmux capture-pane -t "$pane_id" -p 2>/dev/null | tail -15
      echo ""
    done
    echo "╰────────────────────────╯"
  fi
}

# ─── Internal subcommand dispatch (used by fzf reload/preview) ──────────────

case "${1:-}" in
  --list-worktrees)
    _list_worktrees "$(_get_sort_mode)"
    exit 0
    ;;
  --list-worktrees-toggle)
    new_mode=$(_toggle_sort_mode)
    _list_worktrees "$new_mode"
    exit 0
    ;;
  --preview-worktree)
    shift
    _preview_worktree "$*"
    exit 0
    ;;
  --sort-prompt)
    printf '  🔍 [%s] ' "$(_get_sort_mode)"
    exit 0
    ;;
  --sync-worktrees)
    git -C "$DODO_DIR" fetch --all --prune --quiet >/dev/null 2>&1 || true
    git -C "$DODO_DIR" pull --ff-only --quiet origin master >/dev/null 2>&1 || true
    _list_worktrees "$(_get_sort_mode)"
    exit 0
    ;;
  --cleanup-worktrees)
    _cleanup_worktrees_interactive
    exit 0
    ;;
esac

# ─── Main Menu ───────────────────────────────────────────────────────────────

main_menu() {
  local choice
  choice=$(printf '%s\n' \
    "🎯  O1 — Tutor Session" \
    "🚀  New Dodo Worktree" \
    "📂  Open Existing Worktree" | \
    fzf --ansi \
        --header $'  ✨ dodo command palette ✨\n  ─────────────────────────\n  enter: select  •  esc: close\n' \
        --header-first \
        --prompt '  ❯ ' \
        --no-sort \
        --no-multi \
        --reverse \
        --border rounded \
        --border-label " 🐦 dodo " \
        --margin 0 \
        --padding 1 \
        --color='header:italic:yellow,border:blue,label:blue' \
        --bind 'esc:abort') || return 0

  case "$choice" in
    *"O1"*)            create_o1_session ;;
    *"New Dodo"*)      new_dodo_worktree ;;
    *"Open Existing"*) open_existing_worktree ;;
  esac
}

# ─── O1: Tutor Session ──────────────────────────────────────────────────────

create_o1_session() {
  local SESSION="o1-session"
  local O1_DIR="$HOME/Documents/o1"

  if tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux switch-client -t "$SESSION"
    return
  fi

  tmux new-session -d -s "$SESSION" -c "$O1_DIR"

  # Window 1 — Claude (o1-tutor)
  tmux rename-window -t "$SESSION:1" "o1-tutor"
  tmux send-keys -t "$SESSION:1" "claude" C-m

  # Window 2 — nvim (editor)
  tmux new-window -t "$SESSION:2" -n "editor" -c "$O1_DIR"
  tmux send-keys -t "$SESSION:2" "nvim" C-m

  # Window 3 — ranger (browser)
  tmux new-window -t "$SESSION:3" -n "browser" -c "$O1_DIR"
  tmux send-keys -t "$SESSION:3" "ranger" C-m

  tmux switch-client -t "$SESSION:1"
}

# ─── New Dodo Worktree ──────────────────────────────────────────────────────

new_dodo_worktree() {
  # ┌─ Step 1/2: Linear Ticket ─┐
  local ticket
  # --print-query with empty input always exits 1 (no match), so we
  # capture output regardless of exit code and check for esc (empty) after.
  ticket=$(printf '' | fzf \
    --ansi \
    --header $'  🎫 Enter Linear Ticket ID\n  ─────────────────────────\n  enter: continue  •  esc: back\n' \
    --header-first \
    --prompt '  🔖 Ticket: ' \
    --print-query \
    --no-sort \
    --reverse \
    --border rounded \
    --border-label " 🚀 New Dodo Worktree — Step 1/3 " \
    --padding 1 \
    --color='header:italic:cyan,border:magenta,label:magenta' \
    --bind 'esc:abort' | head -1) || true

  [[ -z "$ticket" ]] && { main_menu; return; }

  # ┌─ Step 2/2: Production DB? ─┐
  local use_prod
  use_prod=$(printf '%s\n' \
    "❌ No  — Use development DB (localhost)" \
    "✅ Yes — Use production DATABASE_URL" | \
    fzf --ansi \
        --header $'  🗄️  Use Production DATABASE_URL?\n  ──────────────────────────────────\n  enter: confirm  •  esc: back\n' \
        --header-first \
        --prompt '  💾 DB: ' \
        --no-sort \
        --no-multi \
        --reverse \
        --border rounded \
        --border-label " 🚀 New Dodo Worktree — Step 2/3 " \
        --padding 1 \
        --color='header:italic:cyan,border:magenta,label:magenta' \
        --bind 'esc:abort') || { new_dodo_worktree; return; }

  [[ -z "$use_prod" ]] && { new_dodo_worktree; return; }

  local prod_db=false
  [[ "$use_prod" == *"Yes"* ]] && prod_db=true

  # ┌─ Step 3/3: Dev Servers? ─┐
  local start_backend=false
  local start_frontend=false

  local server_choices
  server_choices=$(printf '%s\n' \
    "⏭️  Skip — no servers" \
    "🖥️  Backend" \
    "🌐 Frontend" | \
    fzf --ansi \
        --multi \
        --header $'  ⚡ Start dev servers?\n  ──────────────────────────\n  tab: toggle  •  enter: confirm  •  esc: back\n' \
        --header-first \
        --prompt '  ⚡ Servers: ' \
        --no-sort \
        --reverse \
        --border rounded \
        --border-label " 🚀 New Dodo Worktree — Step 3/3 " \
        --padding 1 \
        --color='header:italic:cyan,border:magenta,label:magenta' \
        --bind 'esc:abort') || { new_dodo_worktree; return; }

  if [[ "$server_choices" != *"Skip"* ]]; then
    [[ "$server_choices" == *"Backend"* ]] && start_backend=true
    [[ "$server_choices" == *"Frontend"* ]] && start_frontend=true
  fi

  # ── Create worktree via gw ──
  local gw_output
  local gw_args=("workflow-create" "$ticket" "--ticket" "$ticket" "--stack" "fullstack")
  [[ "$prod_db" == true ]] && gw_args+=("--prod-db")

  gw_output=$(cd "$DODO_DIR" && "$GW" "${gw_args[@]}" 2>/dev/null | tail -1) || true

  # Parse the JSON output from gw
  local workflow_id worktree_path
  if [[ -n "$gw_output" ]] && echo "$gw_output" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
    workflow_id=$(echo "$gw_output" | python3 -c "import sys,json; print(json.load(sys.stdin)['workflow_id'])")
    worktree_path=$(echo "$gw_output" | python3 -c "import sys,json; print(json.load(sys.stdin)['worktree_path'])")
  else
    # Fallback: worktree may already exist, use DODO_DIR
    worktree_path="$DODO_DIR"
    workflow_id="wf-$(date +%s)-$$"
  fi

  # gw names the worktree folder after the LAST path segment of the branch
  # (it strips any "feature/" prefix). The tmux session — and every later
  # has-session / _mark_opened lookup, including "Open Existing Worktree" —
  # keys off that folder name, so derive the session name identically. Using
  # the raw ticket left a "/" in the name, which made _mark_opened's
  # `touch "$LAST_OPENED_DIR/<name>"` fail on a nonexistent nested dir and,
  # under `set -e`, abort the palette before the session was ever created.
  local session_name
  session_name="$(basename "$worktree_path")"

  # ── Create tmux session in the worktree ──
  if tmux has-session -t "$session_name" 2>/dev/null; then
    _mark_opened "$session_name"
    tmux switch-client -t "$session_name"
    return
  fi

  _create_session "$session_name" "$worktree_path" "$workflow_id" "$prod_db" "$start_backend" "$start_frontend"
}

# ─── Open Existing Worktree ─────────────────────────────────────────────────

open_existing_worktree() {
  local worktrees_dir="$WORKTREES_DIR"

  if [[ ! -d "$worktrees_dir" ]] || [[ -z "$(ls -A "$worktrees_dir" 2>/dev/null)" ]]; then
    printf '%s\n' "  (empty)" | \
      fzf --header $'  📂 No worktrees found in .worktrees/\n  Start one with \"New Dodo Worktree\"' \
          --reverse --border rounded --padding 1 --no-sort \
          --color='header:italic:yellow,border:blue' \
          --bind 'esc:abort,enter:abort' || true
    main_menu
    return
  fi

  _set_sort_mode "recent"

  local choice prompt
  prompt=$("$SCRIPT_PATH" --sort-prompt)
  choice=$("$SCRIPT_PATH" --list-worktrees | fzf --ansi \
      --header $'  📂 Existing Worktrees (.worktrees/)\n  ──────────────────────────────────────\n  enter: attach/create  •  ctrl-r: sort  •  ctrl-s: sync  •  ctrl-u: cleanup  •  esc: back\n\n  📺 opened  •  ✅ merged  •  \e[33mdirty\e[0m  •  \e[90mstash\e[0m\n' \
      --header-first \
      --prompt "$prompt" \
      --no-sort \
      --no-multi \
      --reverse \
      --border rounded \
      --border-label " 📂 Existing Worktrees " \
      --padding 1 \
      --color='header:italic:green,border:green,label:green' \
      --preview "$SCRIPT_PATH --preview-worktree {}" \
      --preview-window 'right:55%:wrap' \
      --bind "ctrl-r:reload($SCRIPT_PATH --list-worktrees-toggle)+transform-prompt($SCRIPT_PATH --sort-prompt)" \
      --bind "ctrl-s:reload($SCRIPT_PATH --sync-worktrees)" \
      --bind "ctrl-u:execute($SCRIPT_PATH --cleanup-worktrees)+reload($SCRIPT_PATH --list-worktrees)" \
      --bind 'esc:abort') || { main_menu; return; }

  [[ -z "$choice" ]] && { main_menu; return; }

  local wt_name
  wt_name=$(_extract_name "$choice")
  local wt_path="$worktrees_dir/$wt_name"

  if tmux has-session -t "$wt_name" 2>/dev/null; then
    _mark_opened "$wt_name"
    tmux switch-client -t "$wt_name"
    return
  fi

  # No tmux session — create one in the existing worktree
  # Try to get workflow metadata from gw if available
  local prod_db="false" workflow_id="wf-$(date +%s)-$$"

  # Check if gw has metadata for this worktree
  if [[ -f "$WORKFLOW_LOG" ]] && [[ -s "$WORKFLOW_LOG" ]]; then
    local wf_json
    wf_json=$(cd "$DODO_DIR" && "$GW" workflow-list 2>/dev/null | while IFS= read -r json_line; do
      local t
      t=$(echo "$json_line" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ticket',''))")
      if [[ "$t" == "$wt_name" ]]; then
        echo "$json_line"
        break
      fi
    done) || true

    if [[ -n "$wf_json" ]]; then
      prod_db=$(echo "$wf_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('prod_db',False))")
      workflow_id=$(echo "$wf_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))")
      [[ -z "$workflow_id" ]] && workflow_id="wf-$(date +%s)-$$"
    fi
  fi

  # ┌─ Ask which dev servers to start ─┐
  local start_backend=false
  local start_frontend=false

  local server_choices
  server_choices=$(printf '%s\n' \
    "⏭️  Skip — no servers" \
    "🖥️  Backend" \
    "🌐 Frontend" | \
    fzf --ansi \
        --multi \
        --header $'  ⚡ Start dev servers?\n  ──────────────────────────\n  tab: toggle  •  enter: confirm  •  esc: back\n' \
        --header-first \
        --prompt '  ⚡ Servers: ' \
        --no-sort \
        --reverse \
        --border rounded \
        --border-label " 📂 Open Worktree — Dev Servers " \
        --padding 1 \
        --color='header:italic:green,border:green,label:green' \
        --bind 'esc:abort') || { open_existing_worktree; return; }

  if [[ "$server_choices" != *"Skip"* ]]; then
    [[ "$server_choices" == *"Backend"* ]] && start_backend=true
    [[ "$server_choices" == *"Frontend"* ]] && start_frontend=true
  fi

  _create_session "$wt_name" "$wt_path" "$workflow_id" "$prod_db" "$start_backend" "$start_frontend"
}

# ─── Entry Point ─────────────────────────────────────────────────────────────
main_menu
