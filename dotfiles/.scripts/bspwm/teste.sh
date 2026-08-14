#!/bin/bash

# Run the xrandr command and save the output to a variable
monitors=($(xrandr --listactivemonitors | awk '{print $4}'))

# Print the first element of the array
echo "First monitor: ${monitors[0]}"

# Loop through each monitor name in the array
for monitor in "${monitors[@]}"
do
  # Check if the monitor name is "HDMI-1"
  if [ "$monitor" == "HDMI-1" ]
  then
    # If the monitor is "HDMI-1", do something with it
    echo "Found HDMI-1 monitor"
    # Do something else here...
  fi
done

