baseDIR="$HOME/Documents/work/baduk/backend"
cd $baseDIR
DIRS=( "userAuthAPI" "gatewayAPI" "autonomoAPI" )
SESSION_SIZE=${#DIRS[@]}
MONGOIDX=$(($SESSION_SIZE+1))
echo ${MONGOIDX}
echo $SESSION_SIZE

#for i in "${!DIRS[@]}"
#do
  #echo $(($i+1))
#done
