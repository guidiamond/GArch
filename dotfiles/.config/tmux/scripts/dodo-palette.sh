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
DODO_DIR="$HOME/dodo/dodo_app_workspace/master"
GW="$HOME/.scripts/bash/gw"

mkdir -p "$WORKFLOW_DIR"

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
    --border-label " 🚀 New Dodo Worktree — Step 1/2 " \
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
        --border-label " 🚀 New Dodo Worktree — Step 2/2 " \
        --padding 1 \
        --color='header:italic:cyan,border:magenta,label:magenta' \
        --bind 'esc:abort') || { new_dodo_worktree; return; }

  [[ -z "$use_prod" ]] && { new_dodo_worktree; return; }

  local prod_db=false
  [[ "$use_prod" == *"Yes"* ]] && prod_db=true

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

  local session_name="$ticket"

  # ── Create tmux session in the worktree ──
  if tmux has-session -t "$session_name" 2>/dev/null; then
    tmux switch-client -t "$session_name"
    return
  fi

  _create_session "$session_name" "$worktree_path" "$workflow_id" "$prod_db"
}

# ─── Open Existing Worktree ─────────────────────────────────────────────────

open_existing_worktree() {
  local worktrees_dir="$DODO_DIR/.worktrees"

  if [[ ! -d "$worktrees_dir" ]] || [[ -z "$(ls -A "$worktrees_dir" 2>/dev/null)" ]]; then
    printf '%s\n' "  (empty)" | \
      fzf --header $'  📂 No worktrees found in .worktrees/\n  Start one with \"New Dodo Worktree\"' \
          --reverse --border rounded --padding 1 --no-sort \
          --color='header:italic:yellow,border:blue' \
          --bind 'esc:abort,enter:abort' || true
    main_menu
    return
  fi

  # Build display list by scanning .worktrees/ directory
  local choice
  choice=$({
    # First pass: opened sessions (sorted to top)
    for dir in "$worktrees_dir"/*/; do
      [[ ! -d "$dir" ]] && continue
      local name
      name=$(basename "$dir")
      tmux has-session -t "$name" 2>/dev/null && \
        printf "📺 OPENED │ %s\n" "$name"
    done
    # Second pass: closed sessions
    for dir in "$worktrees_dir"/*/; do
      [[ ! -d "$dir" ]] && continue
      local name
      name=$(basename "$dir")
      tmux has-session -t "$name" 2>/dev/null || \
        printf "   closed │ %s\n" "$name"
    done
  } | fzf --ansi \
      --header $'  📂 Existing Worktrees (.worktrees/)\n  ──────────────────────────────────────\n  enter: attach/create session  •  esc: back\n\n  📺 OPENED = tmux session active     closed = no session\n' \
      --header-first \
      --prompt '  🔍 ' \
      --no-sort \
      --no-multi \
      --reverse \
      --border rounded \
      --border-label " 📂 Existing Worktrees " \
      --padding 1 \
      --color='header:italic:green,border:green,label:green' \
      --preview '
        wt_name=$(echo {} | sed "s/^.*│ *//")
        wt_path="'"$worktrees_dir"'/$wt_name"

        echo "╭─── 📋 Worktree Info ───╮"
        echo "  📁 Name:   $wt_name"
        echo "  📁 Path:   $wt_path"

        if [ -f "$wt_path/.git" ] || [ -d "$wt_path/.git" ]; then
          branch=$(git -C "$wt_path" branch --show-current 2>/dev/null || echo "—")
          echo "  🌿 Branch: $branch"

          # Show recent commits
          echo ""
          echo "  📝 Recent commits:"
          git -C "$wt_path" log --oneline -5 2>/dev/null | sed "s/^/    /"
        fi
        echo "╰─────────────────────────╯"
        echo ""

        # Show live pane content if tmux session is active
        if tmux has-session -t "$wt_name" 2>/dev/null; then
          echo "╭─── 📺 Live Session ───╮"
          for pane_info in $(tmux list-panes -t "$wt_name" -a -F "#{window_name}:#{pane_id}" 2>/dev/null); do
            win_name="${pane_info%%:*}"
            pane_id="${pane_info#*:}"
            echo "  ── 🪟 $win_name ──"
            tmux capture-pane -t "$pane_id" -p 2>/dev/null | tail -15
            echo ""
          done
          echo "╰────────────────────────╯"
        fi
      ' \
      --preview-window 'right:50%:wrap' \
      --bind 'esc:abort') || { main_menu; return; }

  [[ -z "$choice" ]] && { main_menu; return; }

  # Extract worktree name from choice (format: "📺 OPENED │ name" or "   closed │ name")
  local wt_name
  wt_name=$(echo "$choice" | sed 's/^.*│ *//')
  local wt_path="$worktrees_dir/$wt_name"

  # If tmux session exists, just switch to it
  if tmux has-session -t "$wt_name" 2>/dev/null; then
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

  _create_session "$wt_name" "$wt_path" "$workflow_id" "$prod_db"
}

# ─── Helper: Create tmux session in a worktree ──────────────────────────────

_create_session() {
  local session_name="$1"
  local worktree_path="$2"
  local workflow_id="$3"
  local prod_db="${4:-false}"

  tmux new-session -d -s "$session_name" -c "$worktree_path"
  tmux set-environment -t "$session_name" DODO_WORKFLOW_ID "$workflow_id"
  tmux set-environment -t "$session_name" DODO_WORKTREE_PATH "$worktree_path"

  # Window 1 — Claude
  tmux rename-window -t "$session_name:1" "claude"
  tmux send-keys -t "$session_name:1" "export DODO_WORKFLOW_ID='$workflow_id'" C-m
  tmux send-keys -t "$session_name:1" "claude --dangerously-skip-permissions" C-m

  # Sentinel file: servers wait for build to finish before starting
  local ready_file="/tmp/dodo-ready-${session_name}"
  rm -f "$ready_file"

  # Window 2 — nvim (editor + build)
  tmux new-window -t "$session_name:2" -n "editor" -c "$worktree_path"
  tmux send-keys -t "$session_name:2" "export DODO_WORKFLOW_ID='$workflow_id'" C-m
  tmux send-keys -t "$session_name:2" "pnpm i && pnpm build:packages && touch '$ready_file' && nvim" C-m

  # Resolve prod DB URL if needed
  local db_prefix=""
  if [[ "$prod_db" == "True" || "$prod_db" == true ]]; then
    local prod_url
    prod_url=$(grep '^DATABASE_URL=' "$DODO_DIR/.env.production" | head -1 | cut -d= -f2-)
    prod_url="${prod_url%\"}"
    prod_url="${prod_url#\"}"
    db_prefix="DATABASE_URL=\"$prod_url\" "
  fi

  local wait_cmd="echo 'Waiting for pnpm build to finish...' && while [ ! -f '$ready_file' ]; do sleep 1; done"

  # Window 3 — Backend server
  tmux new-window -t "$session_name:3" -n "backend" -c "$worktree_path"
  tmux send-keys -t "$session_name:3" "export DODO_WORKFLOW_ID='$workflow_id'" C-m
  tmux send-keys -t "$session_name:3" "$wait_cmd && ${db_prefix}pnpm dev:backend" C-m

  # Window 4 — Frontend server
  tmux new-window -t "$session_name:4" -n "frontend" -c "$worktree_path"
  tmux send-keys -t "$session_name:4" "export DODO_WORKFLOW_ID='$workflow_id'" C-m
  tmux send-keys -t "$session_name:4" "$wait_cmd && ${db_prefix}pnpm dev:frontend" C-m

  tmux switch-client -t "$session_name:1"
}

# ─── Entry Point ─────────────────────────────────────────────────────────────
main_menu
