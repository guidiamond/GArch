# DEFAULT SOURCE FOR PYTHON
if [ -f $HOME/.scripts/default_enviroment.txt ]; then
    condaorenv=`head -1 $HOME/.scripts/default_enviroment.txt`
    env=`head -2 $HOME/.scripts/default_enviroment.txt | tail -1`
    env=${env}
    if [ "${condaorenv}" == "conda" ]; then
        conda
        conda activate ${env}
    else
        source $HOME/.virtualenv/${env}/bin/activate

    
    fi
else
    touch default_enviroment.txt
fi

alias changenv="vim $HOME/.scripts/default_enviroment.txt"
# condaorenv='awk \'\$0=NR==1 \? replace : \$0' replace=\"${1}\" default_enviroment.txt'
# whichenvi='awk '$0=NR==2 ? replace : $0' replace="${1}" default_enviroment.txt'
# echo ${condaorenv}
# a=${condaorenv}
# b=${whichenvi}
# alias a="echo condaorenv.txt >> default_enviroment"
# alias bi="echo condaorenv.txt >> default_enviroment"