css_file=$1
if [ ${1: -5} == ".scss" ] || [ ${1: -4} == ".css" ]; then
  if [[ $css_file == *"src"* ]]; then
    package_path=$(echo "${css_file}" | sed 's/src.*//')
    cd ${package_path} && yarn stylelint ${css_file} --fix
  fi

fi
