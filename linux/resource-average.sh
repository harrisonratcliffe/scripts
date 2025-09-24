#!/bin/bash

set -euo pipefail

if [ -z "${1:-}" ]; then
  echo "Usage: $0 <seconds>"
  exit 1
fi

SECONDS_WINDOW="$1"

# --- Helper: human-friendly float printing ---
pf() { printf "%.2f" "$1"; }

# --- Network bytes (aggregate all non-lo interfaces) ---
net_bytes() {
  awk -F'[: ]+' '
    NR>2 && $1 != "lo" {
      rx+=$3; tx+=$11
    }
    END { printf "%s %s\n", rx+0, tx+0 }
  ' /proc/net/dev
}

# --- Capture starting network counters ---
read RX0 TX0 < <(net_bytes)

# --- Sample vmstat for the whole window (once) ---
VMOUT="$(vmstat 1 "$SECONDS_WINDOW")"

# --- CPU average over window ---
CPU_AVG="$(printf "%s\n" "$VMOUT" | awk 'NR>2 {sum+=100-$15; n++} END { if(n>0) printf("%.2f", sum/n); else print "0.00"}')"

# --- Optional: run/blocked queue averages (lightweight system pressure signal) ---
RQ_AVG="$(printf "%s\n" "$VMOUT" | awk 'NR>2 {sum+=$1; n++} END { if(n>0) printf("%.2f", sum/n); else print "0.00"}')"
BQ_AVG="$(printf "%s\n" "$VMOUT" | awk 'NR>2 {sum+=$2; n++} END { if(n>0) printf("%.2f", sum/n); else print "0.00"}')"

# --- RAM snapshot (used/total/percent) using MemAvailable for accuracy ---
MEM_TOTAL_KB=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)
MEM_AVAIL_KB=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)
MEM_USED_KB=$(( MEM_TOTAL_KB - MEM_AVAIL_KB ))

gb() { awk -v k="$1" 'BEGIN { printf "%.2f", k/1024/1024 }'; }
MEM_USED_GB="$(gb "$MEM_USED_KB")"
MEM_TOTAL_GB="$(gb "$MEM_TOTAL_KB")"
MEM_PCT=$(awk -v u="$MEM_USED_KB" -v t="$MEM_TOTAL_KB" 'BEGIN { if(t>0) printf "%.2f", (u/t)*100; else print "0.00" }')

# --- Load average (1/5/15) ---
read LOAD1 LOAD5 LOAD15 _ < /proc/loadavg

# --- Uptime (pretty + since) ---
UP_PRETTY="$(uptime -p 2>/dev/null || true)"
UP_SINCE="$(uptime -s 2>/dev/null || who -b | awk '{print $3" "$4}')"

# --- Disk usage (root filesystem) ---
read FS SZ USED AVAIL USEP MNT < <(df -hP / | awk 'NR==2 {print $1, $2, $3, $4, $5, $6}')

# --- Finish network measurement and compute averages ---
sleep 0  # noop; vmstat already consumed the window
read RX1 TX1 < <(net_bytes)
RX_BPS=$(( (RX1 - RX0) / SECONDS_WINDOW ))
TX_BPS=$(( (TX1 - TX0) / SECONDS_WINDOW ))
# Convert to Mbps (decimal)
RX_Mbps=$(awk -v b="$RX_BPS" 'BEGIN { printf "%.2f", (b*8)/1000000 }')
TX_Mbps=$(awk -v b="$TX_BPS" 'BEGIN { printf "%.2f", (b*8)/1000000 }')

# --- CPU cores (context for load averages) ---
CORES="$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo "?")"

echo "=== Resource Usage Average Over ${SECONDS_WINDOW} Seconds ==="
echo ""
echo "CPU Usage: ${CPU_AVG}%"
echo "RAM Usage: ${MEM_USED_GB}GB (${MEM_PCT}% of ${MEM_TOTAL_GB}GB)"
echo ""
echo "Load Average (1m/5m/15m): ${LOAD1} ${LOAD5} ${LOAD15}  (CPU cores: ${CORES})"
echo "Run Queue Avg (r): ${RQ_AVG}   Blocked Avg (b): ${BQ_AVG}"
echo ""
echo "Uptime: ${UP_PRETTY:-N/A}  (since: ${UP_SINCE:-N/A})"
echo ""
echo "Disk (/): ${USEP} used  (${USED}/${SZ}, free ${AVAIL})  device: ${FS}"
echo ""
echo "Network (avg over window): RX ${RX_Mbps} Mbps   TX ${TX_Mbps} Mbps"
