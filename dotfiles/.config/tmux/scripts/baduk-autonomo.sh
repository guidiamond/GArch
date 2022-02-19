#!/bin/bash

# start session
SESSION="baduk-back"
IS_RUNNING=` ! tmux has-session -t ${SESSION} > /dev/null 2>&1 && echo "false"`
DIR="$HOME/Documents/work/baduk-backend/userAPI"
WIN1="dev"
WIN2="app"
WIN3="db_controller"
WIN4="p_controller"
cd $DIR && clear
is_postman="pgrep -c electron"
if [ $is_postman -eq 0]; then
  postman & disown
fi
! systemctl is-active --quiet mongodb.service && systemctl start mongodb.service && 
sleep 1
if [ "${IS_RUNNING}" == "false" ]; then
  tmux new-session -d -s $SESSION
  #window 1
  tmux rename-window -t $SESSION:1 $WIN1
  tmux send-keys -t $WIN1 "echo ei" C-m
  tmux send-keys -t $WIN1 "vim ./src " C-m

  #window 2
  tmux new-window -t $SESSION:2 -n $WIN2
  tmux send-keys -t $WIN2 "vim ./src/app.ts" C-m
  tmux split-window -h -t $WIN2
  tmux send-keys -t $WIN2 "vim ./src/routes.ts" C-m

  #window 3
  tmux new-window -t $SESSION:3 -n $WIN3
  tmux split-window -h -t $WIN3
  tmux send-keys -t $WIN3 "ranger" C-m
  tmux split-window -v -t $WIN3
  tmux send-keys -t $WIN3 "yarn dev" C-m

  #window 4
  tmux new-window -t $SESSION:4 -n $WIN4
  tmux send-keys -t $WIN4 "mongo" C-m

fi
tmux attach-session -t $SESSION:1
