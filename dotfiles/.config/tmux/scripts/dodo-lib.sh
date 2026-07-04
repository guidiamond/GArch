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
    *)         printf ' ' ;;
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
