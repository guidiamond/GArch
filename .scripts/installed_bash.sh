#!/bin/bash

awk '$3~/^install$/ {print $4;}' /var/log/dpkg.log