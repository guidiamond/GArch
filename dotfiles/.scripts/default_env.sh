if [ -f $HOME/.scripts/default_enviroment.txt ]; then
    env=`cat $HOME/.scripts/default_enviroment.txt`
    env=${env}
    source $HOME/.virtualenv/${env}/bin/activate
else
    touch default_enviroment.txt
fi