echo "Digite o nome do arquivo (ext: PDF)"
read filename
login="guilhermetb1"
pass="249010"
echo "Cole as URLS (press ENTER para baixar)"
read URL

filename_array=(${filename})
url_array=(${URL})
count=0
while [ ! -z "$URL" ];do
    echo "Digite o nome do arquivo (ext: PDF)"
    read filename
    echo "Cole as URLS (press ENTER para baixar)"
    read URL
    url_array+=("${URL}")
    filename_array+=(${filename})
    count=$((count + 1))
done
count=$((count - 1))
for i in $(seq 0 1 ${count});
do
    curl -u "${login}:${pass}" -o "${HOME}/Documents/cdd/${filename_array[${i}]}.pdf" "${url_array[${i}]}"
done
