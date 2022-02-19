#!/bin/bash

# Start SESSION
SESSION="baduk-front"
IS_RUNNING=` ! tmux has-session -t ${SESSION} > /dev/null 2>&1 && echo "false"`
DIR="$HOME/Documents/work/baduk/frontend"
WIN1="Front"
WIN2="Controller"
WIN3="App"
cd $DIR && clear
if [ "${IS_RUNNING}" == "false" ]; then
  tmux new-session -d -s $SESSION

  #Window 1
  tmux rename-window -t $SESSION:1 $WIN1
  tmux send-keys -t $WIN1 "vim ./src " C-m
  #Window 2
  tmux new-window -t $SESSION:2 -n $WIN2
  tmux split-window -h -t $WIN2
  tmux send-keys -t $WIN2 "ranger" C-m
  tmux split-window -v -t $WIN2
  tmux send-keys -t $WIN2 "yarn start" C-m
   #Window 3
  tmux new-window -t $SESSION:3 -n $WIN3
  tmux send-keys -t $WIN3 "vim ./src/modules/app/index.tsx" C-m
fi
tmux attach-session -t $SESSION:1
