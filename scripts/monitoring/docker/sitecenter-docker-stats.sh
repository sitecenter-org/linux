#!/bin/bash

# sitecenter-container-stats.sh
# Collects container statistics and sends them to SiteCenter API
# Compatible with host stats flat JSON format

# Usage:
# ./sitecenter-container-stats.sh ACCOUNT_CODE MONITOR_CODE SECRET_CODE

set -e

ACCOUNT_CODE="$1"
MONITOR_CODE="$2"
SECRET_CODE="$3"

if [[ -z "$ACCOUNT_CODE" || -z "$MONITOR_CODE" || -z "$SECRET_CODE" ]]; then
  echo "Usage: $0 ACCOUNT_CODE MONITOR_CODE SECRET_CODE"
  exit 1
fi

# Container uptime (seconds) - actual container uptime, not host uptime
container_uptime_seconds=$(awk '{print int($1)}' /proc/uptime)
if [ -f /proc/1/stat ]; then
    # Get process start time in clock ticks since boot (field 22 in /proc/1/stat)
    process_start_ticks=$(awk '{print $22}' /proc/1/stat 2>/dev/null || echo "0")
    # Get clock ticks per second
    clock_ticks_per_sec=$(getconf CLK_TCK 2>/dev/null || echo "100")
    # Get system uptime
    system_uptime=$(awk '{print $1}' /proc/uptime)
    # Calculate container uptime
    if [ "$process_start_ticks" -gt 0 ] && [ "$clock_ticks_per_sec" -gt 0 ]; then
        process_start_seconds=$(awk "BEGIN {printf \"%.0f\", $process_start_ticks / $clock_ticks_per_sec}")
        container_uptime_seconds=$(awk "BEGIN {printf \"%.0f\", $system_uptime - $process_start_seconds}")
        # Ensure uptime is not negative (edge case protection)
        if [ "$container_uptime_seconds" -lt 0 ]; then
            container_uptime_seconds=0
        fi
    fi
fi

# Load averages and process info
read load1 load5 load15 running_processes total_processes _ < /proc/loadavg

# Memory info (container memory limits and usage)
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

# Calculate memory usage percentage
mem_used_kb=$((mem_total_kb - mem_available_kb))
mem_usage_percent=$(awk "BEGIN {printf \"%.2f\", ($mem_used_kb / $mem_total_kb) * 100}")

# CPU ticks (container CPU usage)
read cpu user nice system idle iowait _ < /proc/stat
cpu_user_ticks=$((user + nice))
cpu_system_ticks=$system
cpu_idle_ticks=$idle
cpu_iowait_ticks=$iowait
total_cpu_ticks=$((cpu_user_ticks + cpu_system_ticks + cpu_idle_ticks + cpu_iowait_ticks))

# CPU core count (available to container)
cpu_cores=$(nproc 2>/dev/null || grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo "1")

# Container filesystem usage (root filesystem)
rootfs_info=$(df -BK / | awk 'NR==2 {print $2, $3, $4, $5}')
read rootfs_total_kb rootfs_used_kb rootfs_available_kb rootfs_used_percent_raw <<< "$rootfs_info"
rootfs_total_kb=${rootfs_total_kb%K}
rootfs_used_kb=${rootfs_used_kb%K}
rootfs_available_kb=${rootfs_available_kb%K}
rootfs_used_percent=${rootfs_used_percent_raw%\%}

# Network bytes (container's network interfaces)
net_rx_bytes=$(awk 'NR>2 && !/lo:/ {sum += $2} END {print sum+0}' /proc/net/dev)
net_tx_bytes=$(awk 'NR>2 && !/lo:/ {sum += $10} END {print sum+0}' /proc/net/dev)

# Container information
container_hostname=$(hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || echo "unknown")
kernel_version=$(uname -r 2>/dev/null || echo "unknown")

# Container OS information
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

# Process count (in container)
process_count=$(echo "$running_processes" | cut -d'/' -f2)

# Open file descriptors (container)
open_files=$(awk '{print $1}' /proc/sys/fs/file-nr 2>/dev/null || echo "0")

# TCP connections count (container)
tcp_connections=$(ss -t 2>/dev/null | wc -l 2>/dev/null || netstat -t 2>/dev/null | wc -l 2>/dev/null || echo "0")
# Subtract header line if command succeeded
if [ "$tcp_connections" -gt 0 ]; then
    tcp_connections=$((tcp_connections - 1))
fi

# System load per core
load_per_core=$(awk "BEGIN {printf \"%.2f\", $load1 / $cpu_cores}")

# Container IP Information
# Get container IP addresses (excluding loopback)
container_ips=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.' | grep -v '^127\.' | tr '\n' ',' | sed 's/,$//' || echo "")

# Get primary container IP address (first non-loopback)
primary_ip=$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i!~"^127\\.") {print $i; exit}}' || echo "")

# Container interface information
interface_info=""
if command -v ip >/dev/null 2>&1; then
    # Use ip command if available
    interface_info=$(ip addr show 2>/dev/null | awk '
    /^[0-9]+:/ { iface = $2; gsub(/:/, "", iface) }
    /inet / && !/127\.0\.0\.1/ && iface != "lo" {
        ip = $2; gsub(/\/.*/, "", ip)
        if (interface_info) interface_info = interface_info ","
        interface_info = interface_info iface ":" ip
    }
    END { print interface_info }' || echo "")
elif command -v ifconfig >/dev/null 2>&1; then
    # Fallback to ifconfig
    interface_info=$(ifconfig 2>/dev/null | awk '
    /^[a-zA-Z0-9]+/ && $1 != "lo" { iface = $1 }
    /inet / && !/127\.0\.0\.1/ && iface != "lo" {
        for(i=1;i<=NF;i++) if($i~/addr:/ || (i==2 && $i~/^[0-9]/)) {
            ip = $i; gsub(/addr:/, "", ip)
            if (interface_info) interface_info = interface_info ","
            interface_info = interface_info iface ":" ip
            break
        }
    }
    END { print interface_info }' || echo "")
fi

# Container-specific metadata
container_name="${CONTAINER_NAME:-$container_hostname}"
container_id="${CONTAINER_ID:-unknown}"

# Java application specific metrics (if running Java)
java_heap_used="0"
java_heap_max="0"
java_threads="0"
if command -v jps >/dev/null 2>&1; then
    java_pids=$(jps -q 2>/dev/null | head -5)  # Limit to prevent hanging
    if [ -n "$java_pids" ]; then
        for pid in $java_pids; do
            if [ -f "/proc/$pid/status" ]; then
                # Get Java process memory from status
                vm_size=$(awk '/VmSize:/ {print $2}' /proc/$pid/status 2>/dev/null || echo "0")
                if [ "$vm_size" -gt "$java_heap_used" ]; then
                    java_heap_used=$vm_size
                fi
                # Count threads
                threads=$(awk '/Threads:/ {print $2}' /proc/$pid/status 2>/dev/null || echo "0")
                java_threads=$((java_threads + threads))
            fi
        done
    fi
fi

# Escape strings for JSON
escape_json() {
    echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\r/\\r/g; s/\n/\\n/g'
}

container_ips_escaped=$(escape_json "$container_ips")
primary_ip_escaped=$(escape_json "$primary_ip")
interface_info_escaped=$(escape_json "$interface_info")
container_name_escaped=$(escape_json "$container_name")
container_id_escaped=$(escape_json "$container_id")
os_name_escaped=$(escape_json "$os_name")
os_version_escaped=$(escape_json "$os_version")

# Get additional Kubernetes/application metadata
app_name="${APP_NAME:-unknown}"
app_version="${APP_VERSION:-unknown}"
pod_name="${POD_NAME:-$container_name}"
pod_namespace="${POD_NAMESPACE:-unknown}"
pod_ip="${POD_IP:-$primary_ip}"
node_name="${NODE_NAME:-unknown}"
deployment_name="${DEPLOYMENT_NAME:-unknown}"
replica_set_name="${REPLICA_SET_NAME:-unknown}"

# Generate unique instance identifier for this container/pod
instance_id="${pod_name}-${container_hostname}"
if [ "$container_id" != "unknown" ]; then
    instance_id="${pod_name}-${container_id:0:12}"  # Use first 12 chars of container ID
fi

# Escape additional metadata
app_name_escaped=$(escape_json "$app_name")
app_version_escaped=$(escape_json "$app_version")
pod_name_escaped=$(escape_json "$pod_name")
pod_namespace_escaped=$(escape_json "$pod_namespace")
pod_ip_escaped=$(escape_json "$pod_ip")
node_name_escaped=$(escape_json "$node_name")
deployment_name_escaped=$(escape_json "$deployment_name")
replica_set_name_escaped=$(escape_json "$replica_set_name")
instance_id_escaped=$(escape_json "$instance_id")

# Prepare flat JSON payload (compatible with host stats format)
json_payload=$(cat <<EOF
{
  "type": "container",
  "timestamp": $(date +%s),
  "instance_id": "$instance_id_escaped",
  "container_name": "$container_name_escaped",
  "container_id": "$container_id_escaped",
  "hostname": "$container_hostname",
  "pod_name": "$pod_name_escaped",
  "pod_namespace": "$pod_namespace_escaped",
  "pod_ip": "$pod_ip_escaped",
  "node_name": "$node_name_escaped",
  "app_name": "$app_name_escaped",
  "app_version": "$app_version_escaped",
  "deployment_name": "$deployment_name_escaped",
  "replica_set_name": "$replica_set_name_escaped",
  "uptime_seconds": $container_uptime_seconds,
  "loadavg_1": $load1,
  "loadavg_5": $load5,
  "loadavg_15": $load15,
  "load_per_core": $load_per_core,
  "mem_total_kb": $mem_total_kb,
  "mem_free_kb": $mem_free_kb,
  "mem_available_kb": $mem_available_kb,
  "mem_used_kb": $mem_used_kb,
  "mem_usage_percent": $mem_usage_percent,
  "mem_buffers_kb": $mem_buffers_kb,
  "mem_cached_kb": $mem_cached_kb,
  "swap_total_kb": $swap_total_kb,
  "swap_free_kb": $swap_free_kb,
  "cpu_user_ticks": $cpu_user_ticks,
  "cpu_system_ticks": $cpu_system_ticks,
  "cpu_idle_ticks": $cpu_idle_ticks,
  "cpu_iowait_ticks": $cpu_iowait_ticks,
  "cpu_total_ticks": $total_cpu_ticks,
  "cpu_cores": $cpu_cores,
  "rootfs_total_kb": $rootfs_total_kb,
  "rootfs_used_kb": $rootfs_used_kb,
  "rootfs_available_kb": $rootfs_available_kb,
  "rootfs_used_percent": $rootfs_used_percent,
  "net_rx_bytes": $net_rx_bytes,
  "net_tx_bytes": $net_tx_bytes,
  "container_ips": "$container_ips_escaped",
  "primary_ip": "$primary_ip_escaped",
  "interface_info": "$interface_info_escaped",
  "process_count": $process_count,
  "open_files": $open_files,
  "tcp_connections": $tcp_connections,
  "java_heap_used_kb": $java_heap_used,
  "java_heap_max_kb": $java_heap_max,
  "java_threads": $java_threads,
  "kernel_version": "$kernel_version",
  "os_name": "$os_name_escaped",
  "os_version": "$os_version_escaped"
}
EOF
)

# Send metrics via curl
curl -s -X POST \
  "https://sitecenter.app/api/pub/v1/a/${ACCOUNT_CODE}/monitor/${MONITOR_CODE}/app-stats" \
  -H "Content-Type: application/json" \
  -H "X-Monitor-Secret: ${SECRET_CODE}" \
  -d "$json_payload" \
  > /dev/null