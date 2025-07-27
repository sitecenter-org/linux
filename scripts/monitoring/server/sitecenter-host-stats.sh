#!/bin/bash
# Usage:
# ./sitecenter-host-stats.sh ACCOUNT_CODE MONITOR_CODE SECRET_CODE
# Version: 2025-07-26-16-20

set -e
# Source environment variables
if [ -f /usr/local/bin/sitecenter-host-env.sh ]; then
    . /usr/local/bin/sitecenter-host-env.sh
fi

ACCOUNT_CODE="${1:-$SITECENTER_ACCOUNT}"
MONITOR_CODE="${2:-$SITECENTER_MONITOR}"
SECRET_CODE="${3:-$SITECENTER_SECRET}"

if [[ -z "$ACCOUNT_CODE" || -z "$MONITOR_CODE" || -z "$SECRET_CODE" ]]; then
  echo "Usage: $0 ACCOUNT_CODE MONITOR_CODE SECRET_CODE"
  exit 1
fi

# Temporary file to store previous network stats for rate calculation
NET_STATS_FILE="/tmp/sitecenter-net-stats-${MONITOR_CODE}.tmp"

# Current timestamp
current_time=$(date +%s)

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

# Calculate used memory
mem_used_kb=$((mem_total_kb - mem_available_kb))
# Ensure mem_used_kb is not negative (edge case protection)
if [ "$mem_used_kb" -lt 0 ]; then
    mem_used_kb=0
fi

# Calculate percentage with robust division-by-zero protection
if [ "$mem_total_kb" -gt 0 ]; then
    mem_usage_percent=$(awk "BEGIN {
        if ($mem_total_kb > 0) {
            printf \"%.2f\", ($mem_used_kb / $mem_total_kb) * 100
        } else {
            print \"0.00\"
        }
    }")
else
    mem_usage_percent="0.00"
fi

# Validate the result is not inf or nan
if [[ "$mem_usage_percent" == "inf" ]] || [[ "$mem_usage_percent" == "nan" ]] || [[ "$mem_usage_percent" == "-nan" ]]; then
    mem_usage_percent="0.00"
fi


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

# Enhanced Network Statistics Collection
collect_network_stats() {
    # Read current network stats
    local current_rx_bytes=0
    local current_tx_bytes=0
    local current_rx_packets=0
    local current_tx_packets=0
    local current_rx_errors=0
    local current_tx_errors=0
    local current_rx_dropped=0
    local current_tx_dropped=0

    # Parse /proc/net/dev for all interfaces (excluding loopback)
    while read -r line; do
        # Skip header lines and loopback
        if [[ "$line" =~ ^[[:space:]]*[a-zA-Z0-9]+: ]] && [[ ! "$line" =~ lo: ]]; then
            # Extract interface name and stats
            iface=$(echo "$line" | awk -F: '{print $1}' | tr -d ' ')
            stats=$(echo "$line" | awk -F: '{print $2}')

            # Parse RX stats (bytes, packets, errors, dropped) with validation
            read rx_bytes rx_packets rx_errs rx_drop _ _ _ _ tx_bytes tx_packets tx_errs tx_drop _ <<< "$stats"

            # Validate and default empty values to 0
            rx_bytes=${rx_bytes:-0}; tx_bytes=${tx_bytes:-0}
            rx_packets=${rx_packets:-0}; tx_packets=${tx_packets:-0}
            rx_errs=${rx_errs:-0}; tx_errs=${tx_errs:-0}
            rx_drop=${rx_drop:-0}; tx_drop=${tx_drop:-0}

            current_rx_bytes=$((current_rx_bytes + rx_bytes))
            current_tx_bytes=$((current_tx_bytes + tx_bytes))
            current_rx_packets=$((current_rx_packets + rx_packets))
            current_tx_packets=$((current_tx_packets + tx_packets))
            current_rx_errors=$((current_rx_errors + rx_errs))
            current_tx_errors=$((current_tx_errors + tx_errs))
            current_rx_dropped=$((current_rx_dropped + rx_drop))
            current_tx_dropped=$((current_tx_dropped + tx_drop))
        fi
    done < /proc/net/dev

    # Initialize rate variables
    local net_rx_bytes_per_sec=0
    local net_tx_bytes_per_sec=0
    local net_rx_packets_per_sec=0
    local net_tx_packets_per_sec=0
    local time_interval=0

    # Try to read previous stats for rate calculation
    if [ -f "$NET_STATS_FILE" ]; then
        # Read previous stats
        local prev_data
        if prev_data=$(cat "$NET_STATS_FILE" 2>/dev/null) && [ -n "$prev_data" ]; then
            local prev_time prev_rx_bytes prev_tx_bytes prev_rx_packets prev_tx_packets
            read prev_time prev_rx_bytes prev_tx_bytes prev_rx_packets prev_tx_packets <<< "$prev_data"

            # Validate previous values
            prev_time=${prev_time:-0}
            prev_rx_bytes=${prev_rx_bytes:-0}
            prev_tx_bytes=${prev_tx_bytes:-0}
            prev_rx_packets=${prev_rx_packets:-0}
            prev_tx_packets=${prev_tx_packets:-0}

            # Calculate time interval if previous time is valid
            if [ "$prev_time" -gt 0 ] && [ "$current_time" -gt "$prev_time" ]; then
            time_interval=$((current_time - prev_time))

            # Calculate rates (only if time interval is reasonable: 30 seconds to 10 minutes)
            if [ "$time_interval" -gt 30 ] && [ "$time_interval" -lt 600 ]; then
                net_rx_bytes_per_sec=$(( (current_rx_bytes - prev_rx_bytes) / time_interval ))
                net_tx_bytes_per_sec=$(( (current_tx_bytes - prev_tx_bytes) / time_interval ))
                net_rx_packets_per_sec=$(( (current_rx_packets - prev_rx_packets) / time_interval ))
                net_tx_packets_per_sec=$(( (current_tx_packets - prev_tx_packets) / time_interval ))

                # Ensure rates are not negative (counter resets)
                [ "$net_rx_bytes_per_sec" -lt 0 ] && net_rx_bytes_per_sec=0
                [ "$net_tx_bytes_per_sec" -lt 0 ] && net_tx_bytes_per_sec=0
                [ "$net_rx_packets_per_sec" -lt 0 ] && net_rx_packets_per_sec=0
                [ "$net_tx_packets_per_sec" -lt 0 ] && net_tx_packets_per_sec=0
            fi
        fi
    fi
    fi

    # Store current stats for next run
    echo "$current_time $current_rx_bytes $current_tx_bytes $current_rx_packets $current_tx_packets" > "$NET_STATS_FILE"

    # Export variables for JSON
    net_rx_bytes=$current_rx_bytes
    net_tx_bytes=$current_tx_bytes
    net_rx_packets=$current_rx_packets
    net_tx_packets=$current_tx_packets
    net_rx_errors=$current_rx_errors
    net_tx_errors=$current_tx_errors
    net_rx_dropped=$current_rx_dropped
    net_tx_dropped=$current_tx_dropped

    # Export rate variables
    export net_rx_bytes_per_sec net_tx_bytes_per_sec net_rx_packets_per_sec net_tx_packets_per_sec time_interval
}

# Get detailed interface information with speeds
get_interface_details() {
    local interface_details=""
    local total_interface_speed=0
    local active_interfaces=0

    # Check each network interface
    for iface_path in /sys/class/net/*; do
        [ -d "$iface_path" ] || continue
        local iface=$(basename "$iface_path")

        # Skip loopback and virtual interfaces
        [[ "$iface" =~ ^(lo|docker|veth|br-) ]] && continue

        # Check if interface is up
        local operstate=""
        [ -f "$iface_path/operstate" ] && operstate=$(cat "$iface_path/operstate" 2>/dev/null)

        if [ "$operstate" = "up" ]; then
            # Get interface speed (in Mbps)
            local speed=0
            if [ -f "$iface_path/speed" ]; then
                local speed_raw=$(cat "$iface_path/speed" 2>/dev/null || echo "0")
                # Validate speed is numeric and handle negative speeds (unknown)
                if [[ "$speed_raw" =~ ^-?[0-9]+$ ]]; then
                    if [ "$speed_raw" -gt 0 ]; then
                        speed=$speed_raw
                    fi
                fi
            fi

            # Get interface statistics
            local rx_bytes=0 tx_bytes=0
            if [ -f "$iface_path/statistics/rx_bytes" ]; then
                local rx_raw=$(cat "$iface_path/statistics/rx_bytes" 2>/dev/null || echo "0")
                if [[ "$rx_raw" =~ ^[0-9]+$ ]]; then
                    rx_bytes=$rx_raw
                fi
            fi
            if [ -f "$iface_path/statistics/tx_bytes" ]; then
                local tx_raw=$(cat "$iface_path/statistics/tx_bytes" 2>/dev/null || echo "0")
                if [[ "$tx_raw" =~ ^[0-9]+$ ]]; then
                    tx_bytes=$tx_raw
                fi
            fi

            # Only count interfaces with valid speed
            if [ "$speed" -gt 0 ]; then
                total_interface_speed=$((total_interface_speed + speed))
                active_interfaces=$((active_interfaces + 1))
            fi

            # Add to interface details
            if [ -n "$interface_details" ]; then
                interface_details="${interface_details},"
            fi
            interface_details="${interface_details}${iface}:${speed}Mbps"
        fi
    done

    # Export variables
    export interface_details total_interface_speed active_interfaces
}

# Calculate network utilization percentage
calculate_network_utilization() {
    local rx_utilization=0
    local tx_utilization=0
    local total_utilization=0

    # Validate inputs are numeric and greater than 0
    local speed_valid=0
    local rx_valid=0
    local tx_valid=0

    # Check if total_interface_speed is valid
    if [[ "$total_interface_speed" =~ ^[0-9]+$ ]] && [ "$total_interface_speed" -gt 0 ]; then
        speed_valid=1
    fi

    # Check if rate values are valid numbers
    if [[ "$net_rx_bytes_per_sec" =~ ^[0-9]+$ ]]; then
        rx_valid=1
    fi

    if [[ "$net_tx_bytes_per_sec" =~ ^[0-9]+$ ]]; then
        tx_valid=1
    fi

    # Calculate utilization only if all inputs are valid
    if [ "$speed_valid" -eq 1 ] && [ "$rx_valid" -eq 1 ] && [ "$tx_valid" -eq 1 ]; then
        # Only calculate if we have actual traffic
        if [ "$net_rx_bytes_per_sec" -gt 0 ] || [ "$net_tx_bytes_per_sec" -gt 0 ]; then
        # Convert bytes/sec to Mbps and calculate percentage
        local rx_mbps=$(awk "BEGIN {printf \"%.2f\", ($net_rx_bytes_per_sec * 8) / 1000000}")
        local tx_mbps=$(awk "BEGIN {printf \"%.2f\", ($net_tx_bytes_per_sec * 8) / 1000000}")

        rx_utilization=$(awk "BEGIN {printf \"%.2f\", ($rx_mbps / $total_interface_speed) * 100}")
        tx_utilization=$(awk "BEGIN {printf \"%.2f\", ($tx_mbps / $total_interface_speed) * 100}")

        # Total utilization is the higher of RX or TX (duplex consideration)
        total_utilization=$(awk "BEGIN {printf \"%.2f\", ($rx_utilization > $tx_utilization) ? $rx_utilization : $tx_utilization}")
    fi
    fi

    export net_rx_utilization=$rx_utilization
    export net_tx_utilization=$tx_utilization
    export net_total_utilization=$total_utilization
}

# Call network collection functions
collect_network_stats
get_interface_details
calculate_network_utilization

# Ensure all network variables have valid numeric defaults
net_rx_bytes=${net_rx_bytes:-0}
net_tx_bytes=${net_tx_bytes:-0}
net_rx_packets=${net_rx_packets:-0}
net_tx_packets=${net_tx_packets:-0}
net_rx_bytes_per_sec=${net_rx_bytes_per_sec:-0}
net_tx_bytes_per_sec=${net_tx_bytes_per_sec:-0}
net_rx_packets_per_sec=${net_rx_packets_per_sec:-0}
net_tx_packets_per_sec=${net_tx_packets_per_sec:-0}
net_rx_errors=${net_rx_errors:-0}
net_tx_errors=${net_tx_errors:-0}
net_rx_dropped=${net_rx_dropped:-0}
net_tx_dropped=${net_tx_dropped:-0}
net_rx_utilization=${net_rx_utilization:-0}
net_tx_utilization=${net_tx_utilization:-0}
net_total_utilization=${net_total_utilization:-0}
total_interface_speed=${total_interface_speed:-0}
active_interfaces=${active_interfaces:-0}
time_interval=${time_interval:-0}
interface_details=${interface_details:-""}

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

# TCP connections count (container) - robust version
tcp_connections=0

# Try /proc/net/tcp first (most reliable in containers)
if [ -r /proc/net/tcp ]; then
    tcp4_count=$(awk 'NR>1 {count++} END {print count+0}' /proc/net/tcp 2>/dev/null)
    tcp6_count=$(awk 'NR>1 {count++} END {print count+0}' /proc/net/tcp6 2>/dev/null)
    tcp_connections=$((tcp4_count + tcp6_count))
# Fallback to ss if available
elif command -v ss >/dev/null 2>&1; then
    tcp_connections=$(ss -t state established 2>/dev/null | wc -l 2>/dev/null || echo "0")
# Last resort: netstat
elif command -v netstat >/dev/null 2>&1; then
    tcp_connections=$(netstat -t 2>/dev/null | awk 'NR>2 && /ESTABLISHED/ {count++} END {print count+0}')
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

# Escape strings for JSON
escape_json() {
    echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\r/\\r/g; s/\n/\\n/g'
}

local_ips_escaped=$(escape_json "$local_ips")
primary_ip_escaped=$(escape_json "$primary_ip")
external_ip_escaped=$(escape_json "$external_ip")
interface_details_escaped=$(escape_json "$interface_details")

# Prepare JSON payload with enhanced network statistics
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
  "cpu_cores": $cpu_cores,
  "rootfs_total_kb": $rootfs_total_kb,
  "rootfs_used_kb": $rootfs_used_kb,
  "rootfs_available_kb": $rootfs_available_kb,
  "rootfs_used_percent": $rootfs_used_percent,
  "net_rx_bytes": $net_rx_bytes,
  "net_tx_bytes": $net_tx_bytes,
  "net_rx_bytes_per_sec": $net_rx_bytes_per_sec,
  "net_tx_bytes_per_sec": $net_tx_bytes_per_sec,
  "net_rx_packets": $net_rx_packets,
  "net_tx_packets": $net_tx_packets,
  "net_rx_packets_per_sec": $net_rx_packets_per_sec,
  "net_tx_packets_per_sec": $net_tx_packets_per_sec,
  "net_rx_errors": $net_rx_errors,
  "net_tx_errors": $net_tx_errors,
  "net_rx_dropped": $net_rx_dropped,
  "net_tx_dropped": $net_tx_dropped,
  "net_rx_utilization": $net_rx_utilization,
  "net_tx_utilization": $net_tx_utilization,
  "net_total_utilization": $net_total_utilization,
  "net_interface_speed_mbps": $total_interface_speed,
  "net_active_interfaces": $active_interfaces,
  "net_interval_seconds": $time_interval,
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
  "interface_info": "$interface_details_escaped"
}
EOF
)

# Random sending delay to prevent API load spikes
sending_delay=$((RANDOM % 41))  # 0-40 seconds
#echo "Delaying ${sending_delay} seconds to distribute API calls..." >&2
sleep $sending_delay

# Send metrics via curl
curl -s -X POST \
  "https://sitecenter.app/api/pub/v1/a/${ACCOUNT_CODE}/monitor/${MONITOR_CODE}/host-stats" \
  -H "Content-Type: application/json" \
  -H "X-Monitor-Secret: ${SECRET_CODE}" \
  -d "$json_payload" \
  > /dev/null