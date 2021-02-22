[ -f $HOME/.zinit/bin/zinit.zsh ] && source "$HOME/.zinit/bin/zinit.zsh" && autoload -Uz _zinit
zinit light-mode wait lucid for \
    zinit-zsh/z-a-patch-dl \
    zinit-zsh/z-a-as-monitor \
    zinit-zsh/z-a-bin-gem-node \
    zdharma/fast-syntax-highlighting \
    zsh-users/zsh-autosuggestions \

zinit wait lucid light-mode for \
  atinit"zicompinit; zicdreplay" \
      zdharma/fast-syntax-highlighting \
  atload"_zsh_autosuggest_start" \
      zsh-users/zsh-autosuggestions \
  blockf atpull'zinit creinstall -q .' \
      zsh-users/zsh-completions

zinit ice atclone"dircolors -b LS_COLORS > clrs.zsh" \
    atpull'%atclone' pick"clrs.zsh" nocompile'!' \
    atload'zstyle ":completion:*" list-colors “${(s.:.)LS_COLORS}”'
zinit light trapd00r/LS_COLORS

zinit ice depth=1; zinit light romkatv/powerlevel10k
zinit snippet OMZ::plugins/colored-man-pages/colored-man-pages.plugin.zsh
zinit snippet OMZ::plugins/aws/aws.plugin.zsh
zinit snippet OMZ::lib/clipboard.zsh
zinit snippet 'https://github.com/softmoth/zsh-vim-mode/blob/master/zsh-vim-mode.plugin.zsh'
zinit snippet 'https://github.com/junegunn/fzf/blob/master/shell/completion.zsh'

zinit ice svn 
zinit snippet OMZ::plugins/z

zmodload zsh/complist

# Double tab using vim keys
#bindkey -M menuselect 'h' vi-backward-char
#bindkey -M menuselect 'k' vi-up-line-or-history
#bindkey -M menuselect 'l' vi-forward-char
#bindkey -M menuselect 'j' vi-down-line-or-history
