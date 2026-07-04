#!/usr/bin/env bash
# dodo-gh-daemon.sh — refresh gh-cache.json for active+recent branches.
# Modes:
#   (no args)          run forever, poll every POLL_SECONDS (default 600)
#   --once             single pass then exit
#   --refresh <branch> refresh a single branch then exit
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/dodo-lib.sh"

POLL_SECONDS="${DODO_POLL_SECONDS:-600}"
LOCKFILE="$WORKFLOW_DIR/.gh-daemon.lock"
WRITELOCK="$WORKFLOW_DIR/.gh-cache.writelock"
mkdir -p "$WORKFLOW_DIR"

# --- worktree path -> branch map (single git call) ---
declare -A WT_BRANCH
_load_branch_map() {
  WT_BRANCH=()
  local cur=""
  while IFS= read -r ln; do
    if [[ "$ln" == worktree\ * ]]; then cur="${ln#worktree }"
    elif [[ "$ln" == branch\ refs/heads/* ]]; then WT_BRANCH["$cur"]="${ln#branch refs/heads/}"; fi
  done < <(git -C "$DODO_DIR" worktree list --porcelain 2>/dev/null || true)
}

# names of active (tmux session) + recent (last-opened, newest 15) worktrees
_active_recent_names() {
  {
    tmux list-sessions -F '#{session_name}' 2>/dev/null || true
    if [[ -d "$LAST_OPENED_DIR" ]]; then
      find "$LAST_OPENED_DIR" -maxdepth 1 -type f -printf '%T@ %f\n' 2>/dev/null \
        | sort -rn | head -15 | cut -d' ' -f2-
    fi
  } | sort -u
}

# branch for a worktree folder name
_branch_of() {
  local name="$1" path="$WORKTREES_DIR/$1"
  echo "${WT_BRANCH[$path]:-}"
}

# refresh one branch into the cache
_refresh_branch() {
  local branch="$1"
  [[ -z "$branch" || "$branch" == "master" || "$branch" == "main" ]] && return 0

  local has_remote="no"
  if git -C "$DODO_DIR" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
    has_remote="yes"
  fi

  local pr_state="none" pr_number=0 pr_url="" ci="none" ci_detail='[]' threads=0
  local pr_json
  pr_json=$(gh -R "$DODO_OWNER/$DODO_REPO" pr view "$branch" \
      --json state,number,url,statusCheckRollup 2>/dev/null || true)

  if [[ -n "$pr_json" ]]; then
    pr_state=$(jq -r '.state // "none"' <<<"$pr_json")
    pr_number=$(jq -r '.number // 0' <<<"$pr_json")
    pr_url=$(jq -r '.url // ""' <<<"$pr_json")
    local rollup
    rollup=$(jq -c '.statusCheckRollup // []' <<<"$pr_json")
    ci=$(_ci_from_rollup "$rollup")
    ci_detail=$(jq -c '[(.statusCheckRollup // [])[]
        | select((.conclusion? // "" | test("FAILURE|TIMED_OUT|CANCELLED|ACTION_REQUIRED"))
                 or (.state? // "" | test("FAILURE|ERROR")))
        | (.name // .context // "check")]' <<<"$pr_json")
    if [[ "$pr_state" == "OPEN" && "$pr_number" -gt 0 ]]; then
      threads=$(gh api graphql \
        -f query='query($owner:String!,$repo:String!,$pr:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$pr){reviewThreads(first:100){nodes{isResolved}}}}}' \
        -F owner="$DODO_OWNER" -F repo="$DODO_REPO" -F pr="$pr_number" \
        --jq '[.data.repository.pullRequest.reviewThreads.nodes[]|select(.isResolved==false)]|length' \
        2>/dev/null || echo 0)
    fi
  fi

  # Merge this entry into the cache. The temp file is created NEXT TO the target
  # (same filesystem) so `mv` is a truly atomic rename; a write lock serializes
  # concurrent writers (the loop daemon and an on-demand --refresh).
  local now tmp
  now=$(date -Iseconds)
  exec 8>"$WRITELOCK"
  flock 8
  tmp=$(mktemp "$(dirname "$GH_CACHE")/.gh-cache.XXXXXX")
  [[ -f "$GH_CACHE" ]] || echo '{}' > "$GH_CACHE"
  jq --arg b "$branch" --arg now "$now" --arg prs "$pr_state" \
     --argjson prn "${pr_number:-0}" --arg url "$pr_url" \
     --arg ci "$ci" --argjson cid "$ci_detail" \
     --argjson th "${threads:-0}" --arg hr "$has_remote" \
     '.[$b] = {updated_at:$now, pr_state:$prs, pr_number:$prn, pr_url:$url,
               ci:$ci, ci_detail:$cid, unresolved_threads:$th, has_remote:$hr}' \
     "$GH_CACHE" > "$tmp" 2>/dev/null && mv "$tmp" "$GH_CACHE" || rm -f "$tmp"
  flock -u 8
}

_pass() {
  _load_branch_map
  local name branch
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    branch="$(_branch_of "$name")"
    [[ -z "$branch" ]] && continue
    _refresh_branch "$branch"
  done < <(_active_recent_names)
}

case "${1:-}" in
  --once)
    _pass ;;
  --refresh)
    arg="${2:-}"
    [[ -z "$arg" ]] && { echo "usage: --refresh <branch-or-worktree-name>" >&2; exit 0; }
    _load_branch_map
    # arg may be a branch or a worktree name
    b="$arg"
    [[ -n "${WT_BRANCH[$WORKTREES_DIR/$arg]:-}" ]] && b="${WT_BRANCH[$WORKTREES_DIR/$arg]}"
    _refresh_branch "$b" ;;
  *)
    # Long-running loop, single instance via flock.
    exec 9>"$LOCKFILE"
    if ! flock -n 9; then
      echo "daemon already running" >&2; exit 0
    fi
    while true; do
      _pass
      sleep "$POLL_SECONDS"
    done ;;
esac
