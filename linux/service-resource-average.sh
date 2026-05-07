#!/bin/bash

# Usage: bash <(curl -s https://scripts.hcloud.uk/linux/service-resource-average.sh) <service-name> <seconds>

SERVICE=$1
DURATION=${2:-60}

# Validate args
if [ -z "$SERVICE" ]; then
  echo "Usage: bash <(curl -s ...) <service-name> <seconds>"
  echo "Example: bash <(curl -s ...) nginx 60"
  exit 1
fi

# Get PID
PID=$(systemctl show -p MainPID --value "$SERVICE" 2>/dev/null)

if [ -z "$PID" ] || [ "$PID" -eq 0 ]; then
  echo "Error: Could not find PID for service '$SERVICE'"
  echo "Is the service running? Try: systemctl status $SERVICE"
  exit 1
fi

echo "Monitoring '$SERVICE' (PID: $PID) for ${DURATION}s..."
echo "-------------------------------------------------------------------"

CPU_TOTAL=0
RAM_TOTAL=0
COUNT=0

for i in $(seq 1 "$DURATION"); do
  # Check process still exists
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "Error: Process $PID no longer exists."
    exit 1
  fi

  read CPU RAM < <(ps -p "$PID" -o pcpu,rss --no-headers 2>/dev/null)

  if [ -n "$CPU" ] && [ -n "$RAM" ]; then
    CPU_TOTAL=$(echo "$CPU_TOTAL + $CPU" | bc)
    RAM_TOTAL=$(( RAM_TOTAL + RAM ))
    COUNT=$(( COUNT + 1 ))
  fi

  # Progress bar
  PROGRESS=$(( i * 100 / DURATION ))
  printf "\rProgress: [%-50s] %d%%" "$(printf '#%.0s' $(seq 1 $(( PROGRESS / 2 ))))" "$PROGRESS"

  sleep 1
done

echo ""
echo "-------------------------------------------------------------------"

if [ "$COUNT" -eq 0 ]; then
  echo "Error: No samples collected."
  exit 1
fi

AVG_CPU=$(echo "scale=2; $CPU_TOTAL / $COUNT" | bc)
AVG_RAM=$(echo "scale=2; $RAM_TOTAL / $COUNT / 1024" | bc)

echo "Service : $SERVICE"
echo "Samples : $COUNT"
echo "Avg CPU : ${AVG_CPU}%"
echo "Avg RAM : ${AVG_RAM} MB"
echo "-------------------------------------------------------------------"
