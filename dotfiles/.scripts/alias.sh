SCRIPTS_DIR="$HOME/.config/scripts"
alias grepi="grep -i "


# GIT
# deletes commited files in gitignore
alias gitignore__clean_commited='git rm --cached $(git ls-files -i --exclude-from=.gitignore)'
alias gclean='git reset --hard && git clean -df'
alias gc='git checkout'
alias gcb='git checkout -b'
alias gst='git stash --include-untracked'

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
alias cvim="cd ~/.config/nvim && ${EDITOR} ~/.config/nvim/init.lua"
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

# function tvim() {
#   devour alacritty --option "window.padding.x=0" --option 'window.padding.y=0' --command nvim $@
# }
#
function tvim() {
  devour wezterm --config-file ~/.config/wezterm/wezterm_tvim.lua start nvim "$@"
}

function ttmux() {
  devour wezterm --config-file ~/.config/wezterm/wezterm_tvim.lua start tmux "$@"
  # devour alacritty --option "window.padding.x=0" --option 'window.padding.y=0' --command tmux $@
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

pdfpagecount() {
    find "$1" -type f -name "*.pdf" -exec pdfinfo {} \; | grep "Pages:" | awk '{sum += $2} END {print sum}'
}

alias prp="poetry run python"
alias prl="poetry run jupyter lab"

# VIRTUAL ENV
changedirectory="cd $HOME/.virtualenv"
#createenv="virtualenv -p ${@} ${@}"
createenv="virtualenv ${@}"
alias makenv="${changedirectory} && ${createenv}"
alias dotfiles="/usr/bin/git --git-dir=$HOME/.dotfiles/ --work-tree=$HOME"

# SSH ALIASES
COLETIVAS_PEM="$HOME/.ssh/guidiamond_coletivas_key.pem"
COLETIVAS_PEM_GTB="$HOME/.ssh/gtb_key.pem"

# alias copy_to_coletivas_vm="rsync -avz -e 'ssh -i $COLETIVAS_PEM' $1 guidiamond@172.174.141.33:$2"

# copy_to_coletivas_gtb() {
#   rsync -avz -e "ssh -i $COLETIVAS_PEM_GTB" "$1" gtb@172.174.141.33:"$2"
# }

copy_to_coletivas_gtb() {
  rsync -az --info=progress2 --inplace --partial --compress-level=0 -e "ssh -i $COLETIVAS_PEM_GTB -o Compression=no -T" "$1" gtb@172.174.141.33:"$2"
}


copy_to_coletivas_gd() {
  rsync -avz -e "ssh -i $COLETIVAS_PEM" "$1" guidiamond@172.174.141.33:"$2"
}

copy_from_coletivas_gtb() {
  rsync -avz --progress -e "ssh -i $COLETIVAS_PEM_GTB" gtb@172.174.141.33:"$1" "$2"

}

copy_from_coletivas_gd() {
  rsync -avz -e "ssh -i $COLETIVAS_PEM" guidiamond@172.174.141.33:"$1" "$2"
}


alias lg="lazygit"
alias prlink='gh pr view --json url -q .url'

# Node modules cleanup (n<command>)
alias ndall="find . \( -name "dist" -o -name "node_modules" -o -name ".next" -o -name ".turbo" \) -type d -prune -exec rm -rf '{}' +" 
alias ndbuild="find . \( -name "dist" -o -name ".next" -o -name ".turbo" \) -type d -prune -exec rm -rf '{}' +" 
alias ndnm="find . \( -o -name "node_modules" \) -type d -prune -exec rm -rf '{}' +" 

alias claude="claude --dangerously-skip-permissions"

alias denoise="ffmpeg -i "$1" -af "afftdn=nr=20" -c:v copy output.mp4"
