#!/bin/bash
for path in  ~/.3T/studio-3t ~/.cache; do
  keys=$(fd  '.*[A-Za-z0-9-]{22}--' $path)
  printf "${keys[@]}"

  for key in $keys; do
    echo "detected key $key"
    echo "removing key..."
    rm -rf "$key"
    echo
  done
done
