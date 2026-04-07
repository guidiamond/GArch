# Wrap session in script(1) to capture command outputs for history recall
if [[ -z "$_ZSH_OUTPUT_CAPTURE" && -o interactive && -t 0 ]] && command -v script &>/dev/null; then
  export _ZSH_OUTPUT_CAPTURE=1
  export _ZSH_OUTPUT_DIR="$HOME/.local/share/zsh/outputs"
  export _ZSH_SESSION_LOG="$_ZSH_OUTPUT_DIR/.session-$$.log"
  mkdir -p "$_ZSH_OUTPUT_DIR"
  exec script -qf "$_ZSH_SESSION_LOG"
fi

export ZINIT_HOME="$HOME/.local/share/zinit"

### Added by Zinit's installer
if [[ ! -f $ZINIT_HOME/zinit.git/zinit.zsh ]]; then
    print -P "%F{33} %F{220}Installing %F{33}ZDHARMA-CONTINUUM%F{220} Initiative Plugin Manager (%F{33}zdharma-continuum/zinit%F{220})…%f"
    command mkdir -p "$ZINIT_HOME" && command chmod g-rwX "$ZINIT_HOME"
    command git clone https://github.com/zdharma-continuum/zinit "$ZINIT_HOME/zinit.git" && \
        print -P "%F{33} %F{34}Installation successful.%f%b" || \
        print -P "%F{160} The clone has failed.%f%b"
fi

source "$ZINIT_HOME/zinit.git/zinit.zsh"
autoload -Uz _zinit
(( ${+_comps} )) && _comps[zinit]=_zinit

source ~/.config/zsh/zshrc
