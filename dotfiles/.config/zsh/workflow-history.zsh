# Workflow History Tracker
# Logs commands to per-workflow directories when DODO_WORKFLOW_ID is set.
# Used by the dodo command palette (Ctrl+s o) to show command history
# in the "Open Existing Workflow" preview.

_workflow_history_preexec() {
  [[ -z "$DODO_WORKFLOW_ID" ]] && return

  local wf_dir="$HOME/.local/share/tmux-workflows/$DODO_WORKFLOW_ID"
  [[ -d "$wf_dir" ]] || mkdir -p "$wf_dir"

  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  printf '[%s] %s\n' "$ts" "$1" >> "$wf_dir/commands.log"
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec _workflow_history_preexec
