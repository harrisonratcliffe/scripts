#!/bin/bash

# usage: ./resource-average.sh <seconds>
# example: ./resource-average.sh 30

if [ -z "$1" ]; then
  echo "Usage: $0 <seconds>"
  exit 1
fi

SECONDS=$1

echo "=== Resource Usage Average Over ${SECONDS} Seconds ==="
echo ""

CPU=$(vmstat 1 "$SECONDS" | awk 'NR>2 {sum+=100-$15} END {print sum/(NR-2)}')
RAM=$(free -g | awk '/Mem:/ {print $3}')

echo "CPU Usage: ${CPU}%"
echo "RAM Usage: ${RAM}GB"
