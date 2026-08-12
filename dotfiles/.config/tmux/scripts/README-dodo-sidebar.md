# Dodo Agent Sidebar

Conductor-style tmux sidebar for managing Claude agents across `~/dodo/master` worktrees.

## Model
The sidebar is a **persistent left pane pinned to each agent's `claude` window**
(added automatically when the agent's session is created). So while you work in
an agent, the live list of all agents is always on the left. Selecting another
agent switches to it — and its `claude` window carries the same sidebar.

`prefix + a` opens the sidebar as a **popup launcher** from anywhere (including
editor/server windows that have no embedded sidebar), to jump to or create an
agent. It also ensures the GitHub status daemon is running.

## Use
- `prefix + a` — summon the launcher popup from any window.
- In the sidebar (embedded pane or popup):
  - `↵` go to / open the agent (asks dev-server questions if it isn't open yet)
  - `^n` new worktree · `^x` remove · `^r` refresh GitHub status for the row
  - `/` browse all worktrees · `esc` back to active+recent
  - `^p` full detail popup (embedded pane) · type to filter
- Width of the embedded pane: `DODO_SIDEBAR_WIDTH` (default `25%`; accepts a percentage like `25%` or a fixed column count like `46`).

## Legend

Glyphs are monochrome Nerd Font icons (Octicons/Codicons/FontAwesome), tinted via
ANSI so the two status dimensions never read as "which colored circle is which":
lifecycle uses **git shapes**, CI uses **check/cross/spinner**. Requires a Nerd Font.

- Claude activity: bell `` needs input (magenta) · bolt `` working (yellow) · moon `` no session (dim)
- Branch lifecycle (git shapes): laptop `` untracked/local (dim) · repo-push `` tracked (blue) · pull-request `` in review (magenta) · git-merge `` merged (green) · dot `` unknown
- CI: check `` pass (green) · times `` fail (red) · sync `` running (yellow) · `─` none · comment ``N unresolved review threads (cyan)

Row format: `<claude> <state> <name>  <ci> [N]`. The default view lists ACTIVE
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
