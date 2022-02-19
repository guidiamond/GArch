#!/bin/bash

#IS_RUNNING=`tmux has-session -t baduk-back`
#IS_RUNNING=`! tmux has-session -t baduk-back && echo "false"`
IS_RUNNING=` ! tmux has-session -t baduk-back > /dev/null 2>&1 && echo "false"`
#echo $IS_RUNNING

if [ "${IS_RUNNING}" == "false" ]; then
  echo "SUCESSO"
fi
