#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════╗
# ║  Herdr worktree jump — prefix+o                      ║
# ║  Pick an existing worktree to open, or type a branch  ║
# ║  name to create it with gw and land in it.            ║
# ╚══════════════════════════════════════════════════════╝
set -euo pipefail

GW="${GW_BIN:-$HOME/.scripts/bash/gw}"
FALLBACK_REPO="${HERDR_WORKTREE_REPO:-$HOME/Repos/master}"

die() {
  printf '\033[31m%s\033[0m\n' "$*" >&2
  read -rsn1 -p 'press any key to close…' _
  exit 1
}

# The popup inherits the focused pane's cwd. If that is not a repo (e.g. $HOME),
# fall back to the main repo rather than failing.
repo_root() {
  if git rev-parse --git-dir >/dev/null 2>&1; then
    git worktree list --porcelain | sed -n '1s/^worktree //p'
  elif git -C "$FALLBACK_REPO" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$FALLBACK_REPO" worktree list --porcelain | sed -n '1s/^worktree //p'
  fi
}

ROOT=$(repo_root)
[[ -n "$ROOT" ]] || die "Not inside a git repository, and $FALLBACK_REPO is not one either."
WORKTREES_DIR="$ROOT/.worktrees"

# Shared with the tmux dodo palette, so both setups sort by one open history.
LAST_OPENED_DIR="$HOME/.local/share/tmux-workflows/last-opened"

# Most recently opened first. Worktrees never opened fall back to their folder
# mtime so they still land in a sensible order below the opened ones.
mapfile -t existing < <(
  git -C "$ROOT" worktree list --porcelain \
    | sed -n 's|^worktree '"$WORKTREES_DIR"'/||p' \
    | while read -r name; do
        printf '%s\t%s\t%s\n' \
          "$(stat -c %Y "$LAST_OPENED_DIR/$name" 2>/dev/null || echo 0)" \
          "$(stat -c %Y "$WORKTREES_DIR/$name" 2>/dev/null || echo 0)" \
          "$name"
      done \
    | sort -t$'\t' -k1,1nr -k2,2nr | cut -f3
)

# fzf --print-query gives us line 1 = what was typed, line 2 = what was selected.
# No selection means the query is a new branch name.
set +e
picked=$(
  printf '%s\n' "${existing[@]}" | fzf \
    --print-query --height=100% --reverse --border=none \
    --prompt='🌱 worktree ❯ ' \
    --header='enter on a match opens it · type a new branch name to create it'
)
rc=$?
set -e
[[ $rc -eq 130 ]] && exit 0   # aborted

query=$(sed -n 1p <<<"$picked")
choice=$(sed -n 2p <<<"$picked")

if [[ -n "$choice" ]]; then
  folder="$choice"
  branch=""
else
  [[ -n "$query" ]] || exit 0
  branch="$query"
  folder="${query##*/}"        # gw derives the folder from the branch basename
fi

target="$WORKTREES_DIR/$folder"

if [[ ! -d "$target" ]]; then
  [[ -n "$branch" ]] || die "Worktree '$folder' is gone from disk."
  printf '\033[36mCreating worktree for %s…\033[0m\n' "$branch"
  (cd "$ROOT" && "$GW" create "$branch") || die "gw create failed."
  [[ -d "$target" ]] || die "gw reported success but $target does not exist."
fi

# Idempotent: herdr focuses the space if this worktree is already open.
herdr worktree open --cwd "$ROOT" --path "$target" --label "$folder" --focus >/dev/null \
  || die "herdr worktree open failed for $target"

mkdir -p "$LAST_OPENED_DIR"
touch "$LAST_OPENED_DIR/$folder"
