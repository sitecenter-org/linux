#!/bin/bash

# Usage:
# ./sitecenter-host-stats.sh ACCOUNT_CODE MONITOR_CODE SECRET_CODE

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

# Load averages and process info
read load1 load5 load15 running_processes total_processes _ < /proc/loadavg

# Memory info
declare -A meminfo
while read -r key value _; do
    key=${key%:}
    meminfo[$key]=$value
done < /proc/meminfo

mem_total_kb=${meminfo[MemTotal]}
mem_free_kb=${meminfo[MemFree]}
mem_available_kb=${meminfo[MemAvailable]}
mem_buffers_kb=${meminfo[Buffers]}
mem_cached_kb=${meminfo[Cached]}
swap_total_kb=${meminfo[SwapTotal]}
swap_free_kb=${meminfo[SwapFree]}

# CPU ticks
read cpu user nice system idle iowait _ < /proc/stat
cpu_user_ticks=$((user + nice))
cpu_system_ticks=$system
cpu_idle_ticks=$idle
cpu_iowait_ticks=$iowait

# CPU core count
cpu_cores=$(grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo "1")

# Filesystem usage (root)
rootfs_info=$(df -BK / | awk 'NR==2 {print $2, $3, $4, $5}')
read rootfs_total_kb rootfs_used_kb rootfs_available_kb rootfs_used_percent_raw <<< "$rootfs_info"
rootfs_total_kb=${rootfs_total_kb%K}
rootfs_used_kb=${rootfs_used_kb%K}
rootfs_available_kb=${rootfs_available_kb%K}
rootfs_used_percent=${rootfs_used_percent_raw%\%}

# Network bytes (all interfaces summed)
net_rx_bytes=$(awk 'NR>2 {sum += $2} END {print sum}' /proc/net/dev)
net_tx_bytes=$(awk 'NR>2 {sum += $10} END {print sum}' /proc/net/dev)

# System information
hostname=$(hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || echo "unknown")
kernel_version=$(uname -r 2>/dev/null || echo "unknown")

# OS information (try multiple sources)
os_name="unknown"
os_version="unknown"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    os_name="$NAME"
    os_version="$VERSION_ID"
elif [ -f /etc/redhat-release ]; then
    os_name=$(cat /etc/redhat-release)
elif [ -f /etc/debian_version ]; then
    os_name="Debian"
    os_version=$(cat /etc/debian_version)
fi

# Process count
process_count=$(echo "$running_processes" | cut -d'/' -f2)

# Open file descriptors
open_files=$(awk '{print $1}' /proc/sys/fs/file-nr 2>/dev/null || echo "0")

# TCP connections count
tcp_connections=$(ss -t 2>/dev/null | wc -l 2>/dev/null || netstat -t 2>/dev/null | wc -l 2>/dev/null || echo "0")
# Subtract header line if command succeeded
if [ "$tcp_connections" -gt 0 ]; then
    tcp_connections=$((tcp_connections - 1))
fi

# System load per core
load_per_core=$(awk "BEGIN {printf \"%.2f\", $load1 / $cpu_cores}")

# IP Address Information
# Get all local IP addresses (excluding loopback)
local_ips=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.' | grep -v '^127\.' | tr '\n' ',' | sed 's/,$//' || echo "")

# Get primary IP address (first non-loopback)
primary_ip=$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i!~"^127\\.") {print $i; exit}}' || echo "")

# Get external/public IP address (with timeout and fallback)
external_ip="unknown"
for service in "https://ipv4.icanhazip.com" "https://api.ipify.org" "https://checkip.amazonaws.com"; do
    if external_ip=$(curl -s --connect-timeout 5 --max-time 10 "$service" 2>/dev/null | tr -d '\n'); then
        # Validate it looks like an IP address
        if [[ $external_ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            break
        fi
    fi
    external_ip="unknown"
done

# Get interface information
interface_info=""
if command -v ip >/dev/null 2>&1; then
    # Use ip command if available
    interface_info=$(ip addr show 2>/dev/null | awk '
    /^[0-9]+:/ { iface = $2; gsub(/:/, "", iface) }
    /inet / && !/127\.0\.0\.1/ {
        ip = $2; gsub(/\/.*/, "", ip)
        if (interface_info) interface_info = interface_info ","
        interface_info = interface_info iface ":" ip
    }
    END { print interface_info }' || echo "")
elif command -v ifconfig >/dev/null 2>&1; then
    # Fallback to ifconfig
    interface_info=$(ifconfig 2>/dev/null | awk '
    /^[a-zA-Z0-9]+/ { iface = $1 }
    /inet / && !/127\.0\.0\.1/ {
        for(i=1;i<=NF;i++) if($i~/addr:/ || (i==2 && $i~/^[0-9]/)) {
            ip = $i; gsub(/addr:/, "", ip)
            if (interface_info) interface_info = interface_info ","
            interface_info = interface_info iface ":" ip
            break
        }
    }
    END { print interface_info }' || echo "")
fi

# Escape strings for JSON
escape_json() {
    echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\r/\\r/g; s/\n/\\n/g'
}

local_ips_escaped=$(escape_json "$local_ips")
primary_ip_escaped=$(escape_json "$primary_ip")
external_ip_escaped=$(escape_json "$external_ip")
interface_info_escaped=$(escape_json "$interface_info")

# Prepare JSON payload
json_payload=$(cat <<EOF
{
  "uptime_seconds": $uptime_seconds,
  "loadavg_1": $load1,
  "loadavg_5": $load5,
  "loadavg_15": $load15,
  "load_per_core": $load_per_core,
  "mem_total_kb": $mem_total_kb,
  "mem_free_kb": $mem_free_kb,
  "mem_available_kb": $mem_available_kb,
  "mem_buffers_kb": $mem_buffers_kb,
  "mem_cached_kb": $mem_cached_kb,
  "swap_total_kb": $swap_total_kb,
  "swap_free_kb": $swap_free_kb,
  "cpu_user_ticks": $cpu_user_ticks,
  "cpu_system_ticks": $cpu_system_ticks,
  "cpu_idle_ticks": $cpu_idle_ticks,
  "cpu_iowait_ticks": $cpu_iowait_ticks,
  "cpu_cores": $cpu_cores,
  "rootfs_total_kb": $rootfs_total_kb,
  "rootfs_used_kb": $rootfs_used_kb,
  "rootfs_available_kb": $rootfs_available_kb,
  "rootfs_used_percent": $rootfs_used_percent,
  "net_rx_bytes": $net_rx_bytes,
  "net_tx_bytes": $net_tx_bytes,
  "hostname": "$hostname",
  "kernel_version": "$kernel_version",
  "os_name": "$os_name",
  "os_version": "$os_version",
  "process_count": $process_count,
  "open_files": $open_files,
  "tcp_connections": $tcp_connections,
  "local_ips": "$local_ips_escaped",
  "primary_ip": "$primary_ip_escaped",
  "external_ip": "$external_ip_escaped",
  "interface_info": "$interface_info_escaped"
}
EOF
)

# Send metrics via curl
curl -s -X POST \
  "https://sitecenter.app/api/pub/v1/a/${ACCOUNT_CODE}/monitor/${MONITOR_CODE}/host-stats" \
  -H "Content-Type: application/json" \
  -H "X-Monitor-Secret: ${SECRET_CODE}" \
  -d "$json_payload" \
  > /dev/null