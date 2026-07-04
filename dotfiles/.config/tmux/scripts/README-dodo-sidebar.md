# Dodo Agent Sidebar

Conductor-style tmux sidebar for managing Claude agents across `~/dodo/master` worktrees.

## Use
- `prefix + a` — open / return to the `dodo` dashboard sidebar (persistent session).
- In the sidebar:
  - `↵` open/attach the agent (asks dev-server questions if it isn't open yet)
  - `^n` new worktree · `^x` remove · `^r` refresh GitHub status for the row
  - `/` browse all worktrees · `esc` back to active+recent
  - type to filter

## Legend
- Claude: 🔔 needs input · ⚙ working · 💤 no session
- Branch: ◽ untracked · ⬆ tracked · 👀 in review · 🟢 merged · `·` unknown (browse-all)
- CI: ✅ pass · ❌ fail · 🟡 running · ─ none · 💬N unresolved review threads

Row format: `<claude> <state> <name>  <ci> [💬N]`. The default view lists ACTIVE
(live tmux sessions) first, then RECENT (last ~15 opened). `/` lists all worktrees
(local git state only — GitHub badges are omitted there for speed).

## Pieces
- `dodo-lib.sh` — shared constants + helpers (glyphs, classification, cache reads,
  `_create_session`, `ask_dev_servers`, `open_worktree_session`). Also sourced by
  `dodo-palette.sh`.
- `dodo-sidebar.sh` — the fzf TUI (`--list`, `--list-all`, `--preview`, keybind
  handlers, and the persistent `_ui` loop).
- `dodo-gh-daemon.sh` — polls `gh` every 10 min → `~/.local/share/tmux-workflows/gh-cache.json`.
- `dodo-dashboard.sh` — `prefix+a` bootstrap: launches the daemon (single instance
  via flock) and creates/attaches the `dodo` session.

## How it stays fast
- The sidebar render path makes **zero** `gh` calls — it reads `gh-cache.json` and
  local git only, so it's always instant.
- The GitHub daemon queries only active+recent branches (never all ~180 worktrees),
  keeping it well under API rate limits.
- Claude/local status auto-refreshes every ~3s (via `fzf --listen` + `--track`, so
  the cursor never jumps); GitHub status refreshes on the 10-min daemon cycle or
  instantly with `^r`.

## Notes
- Force a manual GitHub poll of all active+recent: `dodo-gh-daemon.sh --once`.
- Refresh one branch: `dodo-gh-daemon.sh --refresh <branch-or-worktree-name>`.
- Tests for the pure helpers: `bash tests/dodo/test_helpers.sh`.
