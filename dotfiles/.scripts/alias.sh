SCRIPTS_DIR="$HOME/.config/scripts"
alias grepi="grep -i "

# deletes commited files in gitignore
alias gitignore__clean_commited='git rm --cached $(git ls-files -i --exclude-from=.gitignore)'
alias gclean='git reset --hard && git clean -df'

# DEFAULT ALIASES
alias ls="lsd"
alias vim="nvim"
alias l='ls -l'
alias la='ls -a'
alias lla='ls -la'
alias lt='ls --tree'
alias ldot='ls -ld .*'

# Devour windows
#alias viewnior="devour viewnior"
#alias vlc="devour vlc"
#alias okular="devour okular"
#alias pcmanfm="devour pcmanfm"
 
# Config files
alias czsh="${EDITOR} ~/.config/zsh/zshrc"
alias cvim="cd ~/.config/nvim && ${EDITOR} ~/.config/nvim/init.vim"
alias calias="${EDITOR} ~/.scripts/alias.sh"
alias cscripts="${EDITOR} ~/.scripts/"
alias ci3="${EDITOR} ~/.config/i3/config"
alias cpoly="${EDITOR} ~/.config/polybar/"
alias cbsp="${EDITOR} ~/.config/bspwm/bspwmrc"
alias ckb="${EDITOR} ~/.config/sxhkd/sxhkdrc"

alias -s zip="unzip -l"
alias -s rar="unrar l"
alias -s tar="tar tf"
alias -s tar.gz="echo "
alias -s ace="unace l"

#alias fd='fd . -type d -name'
alias ff='fd . -type f -name'

function copydir {
  pwd | xclip -selection clipboard
}

# Custom aliases
alias copydir='copydir'

# USER ALIASES
alias weather="curl http://wttr.in/"
alias pdfer="bash $HOME/.scripts/pdfdownload.sh"
#alias diropen="xdg-open . & &>/dev/null"
#alias diropen="xdg-open . &> /dev/null"

function tvim() {
  devour alacritty --option "window.padding.x=0" --option 'window.padding.y=0' --command nvim $@
}

function ttmux() {
  devour alacritty --option "window.padding.x=0" --option 'window.padding.y=0' --command tmux $@
}


alias diropen="devour mimeopen ."
alias pcmanfm="devour mimeopen"
alias vlc="devour mimeopen"
alias okular="devour mimeopen"
alias viewnior="devour mimeopen"
#alias vlc="devour vlc"
#alias okular="devour okular"
#alias viewnior="devour viewnior"
#alias viewnior="devour viewnior"
#alias vlc="devour vlc"
#alias okular="devour okular"
#alias pcmanfm="devour pcmanfm"
# alias cdcondaenv="cd $HOME/anaconda3/envs/"
alias cdcondaenv="cd $HOME/.conda/envs/"
alias cdenv="cd $HOME/.virtualenv/"
alias resolution="xrandr | grep '*'"
alias xdg-open="mimeopen"

# VIRTUAL ENV
changedirectory="cd $HOME/.virtualenv"
#createenv="virtualenv -p ${@} ${@}"
createenv="virtualenv ${@}"
alias makenv="${changedirectory} && ${createenv}"
alias dotfiles="/usr/bin/git --git-dir=$HOME/.dotfiles/ --work-tree=$HOME"

alias lg="lazygit"

