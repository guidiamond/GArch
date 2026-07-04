#!/usr/bin/env bash
# dodo-lib.sh — shared constants + pure helpers for the dodo palette & sidebar.
# SOURCE ONLY. Do not set -e here; do not run top-level logic.

# --- Constants ---
DODO_DIR="${DODO_DIR:-$HOME/dodo/master}"
WORKTREES_DIR="${WORKTREES_DIR:-$DODO_DIR/.worktrees}"
GW="${GW:-$HOME/.scripts/bash/gw}"
DODO_OWNER="Dodo-Inc"
DODO_REPO="dodo_app"
WORKFLOW_DIR="${WORKFLOW_DIR:-$HOME/.local/share/tmux-workflows}"
WORKFLOW_LOG="${WORKFLOW_LOG:-$WORKFLOW_DIR/workflows.jsonl}"
GH_CACHE="${GH_CACHE:-$WORKFLOW_DIR/gh-cache.json}"
LAST_OPENED_DIR="${LAST_OPENED_DIR:-$WORKFLOW_DIR/last-opened}"

# Directory of this library, so we can locate sibling scripts (the sidebar) no
# matter who sources us. The sidebar is embedded as a left pane in each agent.
DODO_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DODO_SIDEBAR="${DODO_SIDEBAR:-$DODO_LIB_DIR/dodo-sidebar.sh}"
DODO_SIDEBAR_WIDTH="${DODO_SIDEBAR_WIDTH:-46}"

# --- Pure presentation helpers ---

# _claude_glyph <working:yes|no> <live:yes|no>
_claude_glyph() {
  if [[ "${2:-no}" != "yes" ]]; then printf '💤'; return; fi
  if [[ "${1:-no}" == "yes" ]]; then printf '⚙'; else printf '🔔'; fi
}

# _state_glyph <untracked|tracked|review|merged>
_state_glyph() {
  case "${1:-}" in
    untracked) printf '◽' ;;
    tracked)   printf '⬆' ;;
    review)    printf '👀' ;;
    merged)    printf '🟢' ;;
    *)         printf '·' ;;
  esac
}

# _ci_glyph <passing|failing|running|none>
_ci_glyph() {
  case "${1:-}" in
    passing) printf '✅' ;;
    failing) printf '❌' ;;
    running) printf '🟡' ;;
    *)       printf '─' ;;
  esac
}

# _classify_branch_state <merged:yes|no> <has_remote:yes|no> <pr_state:OPEN|MERGED|none|"">
_classify_branch_state() {
  local merged="${1:-no}" has_remote="${2:-no}" pr="${3:-none}"
  if [[ "$merged" == "yes" || "$pr" == "MERGED" ]]; then echo "merged"; return; fi
  if [[ "$pr" == "OPEN" ]]; then echo "review"; return; fi
  if [[ "$has_remote" == "yes" ]]; then echo "tracked"; return; fi
  echo "untracked"
}

# _ci_from_rollup <statusCheckRollup-json-array>
# Precedence: any running -> running; else any failure -> failing;
# else if there are checks -> passing; else none.
_ci_from_rollup() {
  local json="${1:-[]}"
  local n running failing
  n=$(jq 'length' <<<"$json" 2>/dev/null || echo 0)
  [[ "$n" -eq 0 ]] && { echo "none"; return; }
  running=$(jq '[.[] | select(
      (.status? // "" | test("IN_PROGRESS|QUEUED|PENDING|WAITING|REQUESTED"))
      or (.state? // "" | test("PENDING|EXPECTED"))
    )] | length' <<<"$json" 2>/dev/null || echo 0)
  [[ "$running" -gt 0 ]] && { echo "running"; return; }
  failing=$(jq '[.[] | select(
      (.conclusion? // "" | test("FAILURE|TIMED_OUT|CANCELLED|ACTION_REQUIRED|STARTUP_FAILURE"))
      or (.state? // "" | test("FAILURE|ERROR"))
    )] | length' <<<"$json" 2>/dev/null || echo 0)
  [[ "$failing" -gt 0 ]] && { echo "failing"; return; }
  echo "passing"
}

# _cache_get <branch> <field> — reads GH_CACHE, empty string if absent.
_cache_get() {
  [[ -f "$GH_CACHE" ]] || { echo ""; return; }
  jq -r --arg b "$1" --arg f "$2" '(.[$b][$f]) // "" | if type=="array" then join(",") else . end' \
    "$GH_CACHE" 2>/dev/null || echo ""
}

# _mark_opened <name> — bookkeeping; never abort under set -e.
_mark_opened() {
  mkdir -p "$LAST_OPENED_DIR"
  touch "$LAST_OPENED_DIR/$1" 2>/dev/null || true
}

# ask_dev_servers <border-label>
# Prints "<start_backend> <start_frontend>" as true/false. Returns 1 on esc.
ask_dev_servers() {
  local label="${1:-  Dev Servers }"
  local server_choices
  server_choices=$(printf '%s\n' \
    "⏭️  Skip — no servers" \
    "🖥️  Backend" \
    "🌐 Frontend" | \
    fzf --ansi --multi \
        --header $'  ⚡ Start dev servers?\n  ──────────────────────────\n  tab: toggle  •  enter: confirm  •  esc: back\n' \
        --header-first --prompt '  ⚡ Servers: ' \
        --no-sort --reverse --border rounded \
        --border-label " $label " --padding 1 \
        --color='header:italic:green,border:green,label:green' \
        --bind 'esc:abort') || return 1

  local start_backend=false start_frontend=false
  if [[ "$server_choices" != *"Skip"* ]]; then
    [[ "$server_choices" == *"Backend"* ]] && start_backend=true
    [[ "$server_choices" == *"Frontend"* ]] && start_frontend=true
  fi
  printf '%s %s' "$start_backend" "$start_frontend"
}

# _create_session <session_name> <worktree_path> <workflow_id> [prod_db] [start_backend] [start_frontend]
_create_session() {
  local session_name="$1"
  local worktree_path="$2"
  local workflow_id="$3"
  local prod_db="${4:-false}"
  local start_backend="${5:-true}"
  local start_frontend="${6:-true}"

  _mark_opened "$session_name"

  tmux new-session -d -s "$session_name" -c "$worktree_path"
  tmux set-environment -t "$session_name" DODO_WORKFLOW_ID "$workflow_id"
  tmux set-environment -t "$session_name" DODO_WORKTREE_PATH "$worktree_path"

  tmux rename-window -t "$session_name:1" "claude"
  # Pin the always-visible agent sidebar to the LEFT of the claude window, then
  # run claude in the (now right-hand) original pane and focus it.
  local claude_pane
  claude_pane=$(tmux list-panes -t "$session_name:1" -F '#{pane_id}' | head -1)
  tmux split-window -h -b -l "$DODO_SIDEBAR_WIDTH" -t "$claude_pane" -c "$worktree_path" \
    "exec $DODO_SIDEBAR --pane"
  tmux send-keys -t "$claude_pane" "export DODO_WORKFLOW_ID='$workflow_id'" C-m
  tmux send-keys -t "$claude_pane" "claude --dangerously-skip-permissions" C-m
  tmux select-pane -t "$claude_pane"

  local ready_file="/tmp/dodo-ready-${session_name}"
  rm -f "$ready_file"

  tmux new-window -t "$session_name:2" -n "editor" -c "$worktree_path"
  tmux send-keys -t "$session_name:2" "export DODO_WORKFLOW_ID='$workflow_id'" C-m
  tmux send-keys -t "$session_name:2" "pnpm i && pnpm build:packages && touch '$ready_file' && nvim" C-m

  local db_prefix=""
  if [[ "$prod_db" == "True" || "$prod_db" == true ]]; then
    local prod_url
    prod_url=$(grep '^DATABASE_URL=' "$DODO_DIR/.env.production" | head -1 | cut -d= -f2-)
    prod_url="${prod_url%\"}"; prod_url="${prod_url#\"}"
    db_prefix="DATABASE_URL=\"$prod_url\" "
  fi

  local wait_cmd="echo 'Waiting for pnpm build to finish...' && while [ ! -f '$ready_file' ]; do sleep 1; done"

  if [[ "$start_backend" == true ]]; then
    tmux new-window -t "$session_name" -n "backend" -c "$worktree_path"
    tmux send-keys -t "$session_name:backend" "export DODO_WORKFLOW_ID='$workflow_id'" C-m
    tmux send-keys -t "$session_name:backend" "$wait_cmd && ${db_prefix}pnpm dev:backend" C-m
  fi

  if [[ "$start_frontend" == true ]]; then
    tmux new-window -t "$session_name" -n "frontend" -c "$worktree_path"
    tmux send-keys -t "$session_name:frontend" "export DODO_WORKFLOW_ID='$workflow_id'" C-m
    tmux send-keys -t "$session_name:frontend" "$wait_cmd && ${db_prefix}pnpm dev:frontend" C-m
  fi

  tmux switch-client -t "$session_name:1"
}

# _prod_db_for_worktree <name> — reads stored workflow metadata; echoes true/false.
_prod_db_for_worktree() {
  local name="$1"
  [[ -f "$WORKFLOW_LOG" && -s "$WORKFLOW_LOG" ]] || { echo "false"; return; }
  local out
  out=$(cd "$DODO_DIR" && "$GW" workflow-list 2>/dev/null | while IFS= read -r json_line; do
    local t; t=$(jq -r '.ticket // ""' <<<"$json_line" 2>/dev/null)
    if [[ "$t" == "$name" ]]; then jq -r '.prod_db // false' <<<"$json_line"; break; fi
  done) || true
  [[ -z "$out" ]] && out="false"
  echo "$out"
}

# open_worktree_session <name> <path>
# If a session is live -> attach. Else ask dev-server questions, resolve prod_db
# from metadata, create the session. Mirrors the palette's Open Worktree flow.
open_worktree_session() {
  local name="$1" path="$2"
  if tmux has-session -t "$name" 2>/dev/null; then
    _mark_opened "$name"
    tmux switch-client -t "$name"
    return 0
  fi
  local prod_db workflow_id servers start_backend start_frontend
  prod_db="$(_prod_db_for_worktree "$name")"
  workflow_id="wf-$(date +%s)-$$"
  servers="$(ask_dev_servers " 📂 Open Worktree — Dev Servers ")" || return 1
  start_backend="${servers%% *}"; start_frontend="${servers##* }"
  _create_session "$name" "$path" "$workflow_id" "$prod_db" "$start_backend" "$start_frontend"
}

# _render_row <name> <claude_working> <claude_live> <state> <ci> <threads>
# One visible line: "<claude> <state> <name>  <ci> [💬N]".
_render_row() {
  local name="$1" cw="$2" cl="$3" state="$4" ci="$5" threads="${6:-0}"
  local badges
  badges="$(_ci_glyph "$ci")"
  if [[ -n "$threads" && "$threads" -gt 0 ]] 2>/dev/null; then
    badges="$badges 💬$threads"
  fi
  printf '%s %s %s  %s' "$(_claude_glyph "$cw" "$cl")" "$(_state_glyph "$state")" "$name" "$badges"
}

# _name_from_row <row> — worktree name is the 3rd whitespace token.
_name_from_row() { awk '{print $3}' <<<"$1"; }
