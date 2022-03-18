export _JAVA_AWT_WM_NONREPARENTING=1
export ANDROID_SDK_ROOT="$HOME/Android/Sdk"
export LANG=en_US.UTF8 cabal build
export SAM_CLI_TELEMETRY=0
export EDITOR=/usr/bin/nvim
export GTK2_RC_FILES="$HOME/.gtkrc-2.0"
export XDG_CONFIG_HOME="$HOME/.config"
export CONFIG="$HOME/.config/"
export SCRIPTS="$HOME/.scripts/"
#export PATH="$PATH:$HOME/.config/autostart/:$HOME/.config/scripts/bspwm/:$HOME/.config/scripts/tmux/"

SCRIPT_PATH=""
for dir_path in ~/.scripts/*/; do SCRIPT_PATH+="${dir_path}:"; done

#SCRIPT_PATH=${SCRIPT_PATH::-1}

LOCAL_BIN_PATH="$HOME/.local/bin"
export PATH="$PATH:$SCRIPT_PATH:$LOCAL_BIN_PATH"
