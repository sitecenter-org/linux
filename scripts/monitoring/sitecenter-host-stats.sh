#!/bin/bash

# Usage:
# ./sitecenter-heartbeat.sh ACCOUNT_CODE MONITOR_CODE SECRET_CODE

set -e

ACCOUNT_CODE="$1"
MONITOR_CODE="$2"
SECRET_CODE="$3"

if [[ -z "$ACCOUNT_CODE" || -z "$MONITOR_CODE" || -z "$SECRET_CODE" ]]; then
  echo "Usage: $0 ACCOUNT_CODE MONITOR_CODE SECRET_CODE"
  exit 1
fi

# Uptime (seconds)
uptime_seconds=$(awk '{print int($1)}' /proc/uptime)

# Load averages
read load1 load5 load15 _ < /proc/loadavg

# Memory info
declare -A meminfo
while read -r key value _; do
    key=${key%:}
    meminfo[$key]=$value
done < /proc/meminfo

mem_total_kb=${meminfo[MemTotal]}
mem_free_kb=${meminfo[MemFree]}
mem_available_kb=${meminfo[MemAvailable]}
swap_total_kb=${meminfo[SwapTotal]}
swap_free_kb=${meminfo[SwapFree]}

# CPU ticks
read cpu user nice system idle iowait _ < /proc/stat
cpu_user_ticks=$((user + nice))
cpu_system_ticks=$system
cpu_idle_ticks=$idle
cpu_iowait_ticks=$iowait

# Root filesystem usage
rootfs_used_percent=$(df -P / | awk 'NR==2 {print $5}' | tr -d '%')

# Network bytes (all interfaces summed)
net_rx_bytes=$(awk 'NR>2 {sum += $2} END {print sum}' /proc/net/dev)
net_tx_bytes=$(awk 'NR>2 {sum += $10} END {print sum}' /proc/net/dev)

# Prepare JSON payload
json_payload=$(cat <<EOF
{
  "uptime_seconds": $uptime_seconds,
  "loadavg_1": $load1,
  "loadavg_5": $load5,
  "loadavg_15": $load15,
  "mem_total_kb": $mem_total_kb,
  "mem_free_kb": $mem_free_kb,
  "mem_available_kb": $mem_available_kb,
  "swap_total_kb": $swap_total_kb,
  "swap_free_kb": $swap_free_kb,
  "cpu_user_ticks": $cpu_user_ticks,
  "cpu_system_ticks": $cpu_system_ticks,
  "cpu_idle_ticks": $cpu_idle_ticks,
  "cpu_iowait_ticks": $cpu_iowait_ticks,
  "rootfs_used_percent": $rootfs_used_percent,
  "net_rx_bytes": $net_rx_bytes,
  "net_tx_bytes": $net_tx_bytes
}
EOF
)

# Send metrics via curl
curl -s -X POST \
  "https://sitecenter.app/api/pub/v1/a/${ACCOUNT_CODE}/monitor/${MONITOR_CODE}/host-stats?secret=${SECRET_CODE}" \
  -H "Content-Type: application/json" \
  -d "$json_payload" \
  > /dev/null
