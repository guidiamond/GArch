# Custom fzf history widget with global/session toggle (Ctrl+R)
#
# Ctrl+R once:  opens fzf with GLOBAL history (all sessions)
# Ctrl+R again: toggles to SESSION history (current terminal only)
# Ctrl+O:       show saved output for the selected command
# Header shows which mode is active with color

# === Session History Tracking ===
typeset -ga _FZF_SESSION_HISTORY=()

_fzf_session_history_preexec() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M')
  _FZF_SESSION_HISTORY+=("${timestamp}  ${1}")
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec _fzf_session_history_preexec

# === Output Capture ===
# Requires the script(1) wrapper in ~/.zshrc to be active (_ZSH_SESSION_LOG set)
# Saves per-command output snippets to $_ZSH_OUTPUT_DIR

typeset -gi _OUTPUT_CMD_COUNT=0
_ZSH_OUTPUT_MAX_FILES=100
_ZSH_OUTPUT_MAX_MB=50

_output_capture_preexec() {
  [[ -z "$_ZSH_SESSION_LOG" || ! -f "$_ZSH_SESSION_LOG" ]] && return
  _output_start_byte=$(stat -c%s "$_ZSH_SESSION_LOG" 2>/dev/null || echo 0)
  _output_current_cmd="$1"
}

_output_capture_precmd() {
  [[ -z "$_output_current_cmd" || -z "$_ZSH_SESSION_LOG" ]] && return

  local end_byte=$(stat -c%s "$_ZSH_SESSION_LOG" 2>/dev/null || echo 0)
  local size=$((end_byte - _output_start_byte))

  if (( size > 0 )); then
    local hash=$(printf '%s' "$_output_current_cmd" | md5sum | cut -c1-8)
    local ts=$(date +%s)
    local outfile="$_ZSH_OUTPUT_DIR/cmd-${ts}-${hash}.out"

    tail -c +"$((_output_start_byte + 1))" "$_ZSH_SESSION_LOG" 2>/dev/null \
      | head -c "$size" > "$outfile"
  fi

  _output_current_cmd=""

  # Periodic cleanup (every 20 commands, in background)
  if (( ++_OUTPUT_CMD_COUNT % 20 == 0 )); then
    _output_cleanup &!
  fi
}

_output_cleanup() {
  local dir="${_ZSH_OUTPUT_DIR:-$HOME/.local/share/zsh/outputs}"
  [[ -d "$dir" ]] || return

  # Delete stale session logs (PIDs that no longer exist)
  local f pid
  for f in "$dir"/.session-*.log(N); do
    pid="${${f##*session-}%.log}"
    kill -0 "$pid" 2>/dev/null || rm -f "$f"
  done

  # Prune command outputs beyond max file count (keep newest)
  local -a outfiles=("$dir"/cmd-*.out(N))
  if (( ${#outfiles} > _ZSH_OUTPUT_MAX_FILES )); then
    outfiles=(${(o)outfiles})  # sort ascending (oldest first)
    local num_delete=$(( ${#outfiles} - _ZSH_OUTPUT_MAX_FILES ))
    rm -f "${outfiles[@]:0:$num_delete}"
  fi

  # Enforce total size limit
  local total_kb
  total_kb=$(du -sk "$dir" 2>/dev/null | cut -f1)
  local max_kb=$((_ZSH_OUTPUT_MAX_MB * 1024))
  if (( total_kb > max_kb )); then
    outfiles=(${(o)outfiles})
    for f in "${outfiles[@]}"; do
      rm -f "$f"
      total_kb=$(du -sk "$dir" 2>/dev/null | cut -f1)
      (( total_kb <= max_kb )) && break
    done
  fi
}

add-zsh-hook preexec _output_capture_preexec
add-zsh-hook precmd _output_capture_precmd

# === fzf History Widget ===

fzf-history-widget() {
  setopt localoptions noglobsubst noposixbuiltins pipefail no_aliases extendedglob 2>/dev/null

  # Dump both history sets to temp files so fzf reload() can read them
  local tmp_global="${TMPDIR:-/tmp}/fzf-hist-global.$$"
  local tmp_session="${TMPDIR:-/tmp}/fzf-hist-session.$$"
  local tmp_toggle="${TMPDIR:-/tmp}/fzf-hist-toggle.$$"

  fc -lt '%Y-%m-%d %H:%M  ' -1 0 2>/dev/null | sed 's/^ *//' > "$tmp_global"

  # Write session history in reverse (newest first) with a line number prefix
  local i
  : > "$tmp_session"
  for (( i=${#_FZF_SESSION_HISTORY[@]}; i>=1; i-- )); do
    echo "$i  ${_FZF_SESSION_HISTORY[$i]}" >> "$tmp_session"
  done

  # Helper: extract command text and show saved output (or re-run)
  local tmp_runner="${TMPDIR:-/tmp}/fzf-hist-runner.$$"
  local output_dir="${_ZSH_OUTPUT_DIR:-$HOME/.local/share/zsh/outputs}"
  cat > "$tmp_runner" <<RUNNER_EOF
#!/bin/sh
cmd=\$(echo "\$1" | sed 's/^[0-9]*  [0-9-]* [0-9:]*  *//')
hash=\$(printf '%s' "\$cmd" | md5sum | cut -c1-8)
outfile=\$(ls -1t "${output_dir}"/cmd-*-"\${hash}".out 2>/dev/null | head -1)
if [ -n "\$outfile" ] && [ -f "\$outfile" ]; then
  printf '\033[1;34m▶ %s\033[0m\n' "\$cmd"
  printf '\033[90m─── saved output ───\033[0m\n\n'
  cat "\$outfile"
else
  printf '\033[1;33m▶ %s\033[0m\n' "\$cmd"
  printf '\033[90m─── no saved output, re-running ───\033[0m\n\n'
  eval "\$cmd" 2>&1
fi
RUNNER_EOF
  chmod +x "$tmp_runner"

  # Self-toggling script for ctrl-r
  cat > "$tmp_toggle" <<TOGGLE_EOF
#!/bin/sh
MODE_FILE="${tmp_toggle}.state"
if [ ! -f "\$MODE_FILE" ] || [ "\$(cat "\$MODE_FILE")" = "global" ]; then
  echo "session" > "\$MODE_FILE"
  printf 'reload(cat %s)+change-header(  \033[1;32m● SESSION\033[0;90m  This terminal  │  ctrl-r: toggle  │  ctrl-o: output\033[0m)' '$tmp_session'
else
  echo "global" > "\$MODE_FILE"
  printf 'reload(cat %s)+change-header(  \033[1;34m● GLOBAL\033[0;90m  All sessions  │  ctrl-r: toggle  │  ctrl-o: output\033[0m)' '$tmp_global'
fi
TOGGLE_EOF
  chmod +x "$tmp_toggle"
  echo "global" > "${tmp_toggle}.state"

  local selected
  selected="$(
    cat "$tmp_global" |
    FZF_DEFAULT_OPTS_FILE='' \
    fzf \
      --ansi \
      --scheme=history \
      --header $'  \x1b[1;34m● GLOBAL\x1b[0;90m  All sessions  │  ctrl-r: toggle  │  ctrl-o: output\x1b[0m' \
      --header-first \
      --prompt '  ' \
      --no-sort \
      --nth='3..' \
      --with-nth='2..' \
      --wrap-sign '  ↳ ' \
      --highlight-line \
      --height '40%' \
      --min-height 20 \
      --bind "ctrl-z:ignore" \
      --bind "ctrl-r:transform:$tmp_toggle" \
      --bind "ctrl-o:execute($tmp_runner {} | less -R)" \
      --bind "alt-r:toggle-raw" \
      --query "${LBUFFER}" \
      --no-multi \
      ${FZF_CTRL_R_OPTS-}
  )"

  local ret=$?
  command rm -f "$tmp_global" "$tmp_session" "$tmp_toggle" "${tmp_toggle}.state" "$tmp_runner"

  if [[ -n "$selected" ]]; then
    local cmd
    if [[ "$selected" =~ '^[0-9]+[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}[[:space:]]+(.+)$' ]]; then
      cmd="${match[1]}"
    else
      cmd="$selected"
    fi
    BUFFER="$cmd"
    CURSOR=${#BUFFER}
  fi
  zle reset-prompt
  return $ret
}

zle -N fzf-history-widget
bindkey -M emacs '^R' fzf-history-widget
bindkey -M vicmd '^R' fzf-history-widget
bindkey -M viins '^R' fzf-history-widget
