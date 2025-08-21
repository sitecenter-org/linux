#!/bin/bash
# Usage:
# ./sitecenter-host-stats.sh ACCOUNT_CODE MONITOR_CODE SECRET_CODE
# Version: 2025-08-21-FIXED-RESOURCE-SAFE

set -e

# Set strict resource limits to prevent system overload
ulimit -n 256        # Limit file descriptors
ulimit -v 204800     # Limit virtual memory to 200MB
ulimit -t 30         # CPU time limit to 30 seconds
ulimit -u 50         # Limit number of processes

# Exit immediately if system is under memory pressure
check_system_resources() {
    local available_mem
    if [ -r /proc/meminfo ]; then
        available_mem=$(awk '/MemAvailable/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo "0")
        if [ "$available_mem" -lt 51200 ]; then  # Less than 50MB available
            echo "System under memory pressure (${available_mem}KB available), skipping collection" >&2
            exit 1
        fi
    fi

    # Check if another instance is running
    local script_name=$(basename "$0")
    local running_instances=$(pgrep -f "$script_name" | wc -l)
    if [ "$running_instances" -gt 2 ]; then  # Current + one other
        echo "Another instance already running, exiting" >&2
        exit 1
    fi
}

check_system_resources

# Source environment variables safely
if [ -f /usr/local/bin/sitecenter-host-env.sh ]; then
    set +e
    source /usr/local/bin/sitecenter-host-env.sh 2>/dev/null
    set -e
fi

ACCOUNT_CODE="${1:-$SITECENTER_ACCOUNT}"
MONITOR_CODE="${2:-$SITECENTER_MONITOR}"
SECRET_CODE="${3:-$SITECENTER_SECRET}"

if [[ -z "$ACCOUNT_CODE" || -z "$MONITOR_CODE" || -z "$SECRET_CODE" ]]; then
  echo "Usage: $0 ACCOUNT_CODE MONITOR_CODE SECRET_CODE" >&2
  exit 1
fi

# Temporary file with proper cleanup
NET_STATS_FILE="/tmp/sitecenter-net-stats-${MONITOR_CODE}.tmp"
TEMP_FILES=("$NET_STATS_FILE")

# Cleanup function
cleanup() {
    local exit_code=$?
    for file in "${TEMP_FILES[@]}"; do
        [ -f "$file" ] && rm -f "$file" 2>/dev/null || true
    done
    exit $exit_code
}
trap cleanup EXIT INT TERM

# Get current timestamp once
current_time=$(date +%s)
collection_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")

# Initialize all variables with safe defaults
uptime_seconds=0
load1=0 load5=0 load15=0 load_per_core="0.00"
running_processes="0/0" total_processes=0 process_count=0
mem_total_kb=0 mem_free_kb=0 mem_available_kb=0 mem_used_kb=0 mem_usage_percent="0.00"
mem_buffers_kb=0 mem_cached_kb=0 swap_total_kb=0 swap_free_kb=0
cpu_user_ticks=0 cpu_system_ticks=0 cpu_idle_ticks=0 cpu_iowait_ticks=0 cpu_cores=1
rootfs_total_kb=0 rootfs_used_kb=0 rootfs_available_kb=0 rootfs_used_percent=0
net_rx_bytes=0 net_tx_bytes=0 net_rx_packets=0 net_tx_packets=0
net_rx_bytes_per_sec=0 net_tx_bytes_per_sec=0 net_rx_packets_per_sec=0 net_tx_packets_per_sec=0
net_rx_errors=0 net_tx_errors=0 net_rx_dropped=0 net_tx_dropped=0
net_rx_utilization="0.00" net_tx_utilization="0.00" net_total_utilization="0.00"
total_interface_speed=0 active_interfaces=0 time_interval=0
open_files=0 tcp_connections=0
hostname="unknown" kernel_version="unknown" os_name="unknown" os_version="unknown"
local_ips="" primary_ip="" external_ip="unknown" interface_details=""

# Safe numeric validation function
is_numeric() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

is_float() {
    [[ "$1" =~ ^[0-9]+\.?[0-9]*$ ]]
}

# Collect system information in batches to reduce syscalls
collect_basic_stats() {
    # Uptime
if [ -r /proc/uptime ]; then
    uptime_seconds=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo "0")
fi

    # Load averages and process info in one read
if [ -r /proc/loadavg ]; then
        local loadavg_line
        loadavg_line=$(cat /proc/loadavg 2>/dev/null || echo "0 0 0 0/0 0")
        local loadavg_array=($loadavg_line)
        if [ ${#loadavg_array[@]} -ge 5 ]; then
            is_float "${loadavg_array[0]}" && load1="${loadavg_array[0]}"
            is_float "${loadavg_array[1]}" && load5="${loadavg_array[1]}"
            is_float "${loadavg_array[2]}" && load15="${loadavg_array[2]}"
            running_processes="${loadavg_array[3]:-0/0}"
            is_numeric "${loadavg_array[4]}" && total_processes="${loadavg_array[4]}"
        fi
    fi

    # CPU cores
    if [ -r /proc/cpuinfo ]; then
        cpu_cores=$(grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo "1")
        [ "$cpu_cores" -eq 0 ] && cpu_cores=1
fi

    # Calculate load per core
    if [ "$cpu_cores" -gt 0 ] && is_float "$load1"; then
        load_per_core=$(awk -v load="$load1" -v cores="$cpu_cores" 'BEGIN {printf "%.2f", load / cores}' 2>/dev/null || echo "0.00")
    fi
}

# Memory information - single read
collect_memory_stats() {
if [ -r /proc/meminfo ]; then
        local meminfo_content
        meminfo_content=$(cat /proc/meminfo 2>/dev/null || echo "")

        mem_total_kb=$(echo "$meminfo_content" | awk '/^MemTotal:/ {print int($2)}' || echo "0")
        mem_free_kb=$(echo "$meminfo_content" | awk '/^MemFree:/ {print int($2)}' || echo "0")
        mem_available_kb=$(echo "$meminfo_content" | awk '/^MemAvailable:/ {print int($2)}' || echo "$mem_free_kb")
        mem_buffers_kb=$(echo "$meminfo_content" | awk '/^Buffers:/ {print int($2)}' || echo "0")
        mem_cached_kb=$(echo "$meminfo_content" | awk '/^Cached:/ {print int($2)}' || echo "0")
        swap_total_kb=$(echo "$meminfo_content" | awk '/^SwapTotal:/ {print int($2)}' || echo "0")
        swap_free_kb=$(echo "$meminfo_content" | awk '/^SwapFree:/ {print int($2)}' || echo "0")

# Calculate used memory safely
if [ "$mem_total_kb" -gt 0 ] && [ "$mem_available_kb" -ge 0 ]; then
mem_used_kb=$((mem_total_kb - mem_available_kb))
            [ "$mem_used_kb" -lt 0 ] && mem_used_kb=0

            # Calculate percentage
            if [ "$mem_used_kb" -ge 0 ]; then
    mem_usage_percent=$(awk -v used="$mem_used_kb" -v total="$mem_total_kb" 'BEGIN {
        if (total > 0) {
            result = (used / total) * 100
                        printf "%.2f", (result >= 0 && result <= 100) ? result : 0.00
        } else {
            print "0.00"
        }
    }' 2>/dev/null || echo "0.00")
fi
        fi
    fi
}

# CPU statistics - single read
collect_cpu_stats() {
if [ -r /proc/stat ]; then
        local cpu_line
        cpu_line=$(head -n1 /proc/stat 2>/dev/null || echo "cpu 0 0 0 0 0")
        local cpu_array=($cpu_line)

        if [ ${#cpu_array[@]} -ge 6 ]; then
            local user="${cpu_array[1]:-0}"
            local nice="${cpu_array[2]:-0}"
            local system="${cpu_array[3]:-0}"
            local idle="${cpu_array[4]:-0}"
            local iowait="${cpu_array[5]:-0}"

            is_numeric "$user" && is_numeric "$nice" && cpu_user_ticks=$((user + nice))
            is_numeric "$system" && cpu_system_ticks="$system"
            is_numeric "$idle" && cpu_idle_ticks="$idle"
            is_numeric "$iowait" && cpu_iowait_ticks="$iowait"
fi
    fi
}

# Filesystem usage - single call
collect_filesystem_stats() {
if command -v df >/dev/null 2>&1; then
        local df_output
    df_output=$(df -BK / 2>/dev/null | awk 'NR==2 {print $2, $3, $4, $5}' || echo "0K 0K 0K 0%")
        local df_array=($df_output)

        if [ ${#df_array[@]} -eq 4 ]; then
            rootfs_total_kb=${df_array[0]%K}
            rootfs_used_kb=${df_array[1]%K}
            rootfs_available_kb=${df_array[2]%K}
            rootfs_used_percent=${df_array[3]%\%}

            is_numeric "$rootfs_total_kb" || rootfs_total_kb=0
            is_numeric "$rootfs_used_kb" || rootfs_used_kb=0
            is_numeric "$rootfs_available_kb" || rootfs_available_kb=0
            is_numeric "$rootfs_used_percent" || rootfs_used_percent=0
fi
    fi
}

# Network statistics - optimized version
collect_network_stats() {
    local current_rx_bytes=0 current_tx_bytes=0
    local current_rx_packets=0 current_tx_packets=0
    local current_rx_errors=0 current_tx_errors=0
    local current_rx_dropped=0 current_tx_dropped=0

    # Read network stats in one operation
    if [ -r /proc/net/dev ]; then
        local net_content
        net_content=$(cat /proc/net/dev 2>/dev/null || echo "")

        # Process all interfaces at once using awk
        local net_totals
        net_totals=$(echo "$net_content" | awk '
        NR > 2 && /^[[:space:]]*[a-zA-Z0-9]+:/ {
            gsub(/^[[:space:]]*/, "")
            if ($0 ~ /^lo:/) next  # Skip loopback

            split($0, parts, ":")
            if (length(parts) < 2) next

            n = split(parts[2], fields)
            if (n >= 16) {
                rx_bytes += int(fields[1])
                rx_packets += int(fields[2])
                rx_errors += int(fields[3])
                rx_dropped += int(fields[4])
                tx_bytes += int(fields[9])
                tx_packets += int(fields[10])
                tx_errors += int(fields[11])
                tx_dropped += int(fields[12])
            }
        }
        END {
            printf "%d %d %d %d %d %d %d %d",
                   rx_bytes, rx_packets, rx_errors, rx_dropped,
                   tx_bytes, tx_packets, tx_errors, tx_dropped
        }' 2>/dev/null || echo "0 0 0 0 0 0 0 0")

        local totals_array=($net_totals)
        if [ ${#totals_array[@]} -eq 8 ]; then
            current_rx_bytes="${totals_array[0]}"
            current_rx_packets="${totals_array[1]}"
            current_rx_errors="${totals_array[2]}"
            current_rx_dropped="${totals_array[3]}"
            current_tx_bytes="${totals_array[4]}"
            current_tx_packets="${totals_array[5]}"
            current_tx_errors="${totals_array[6]}"
            current_tx_dropped="${totals_array[7]}"
                    fi
    fi

    # Calculate rates from previous data
    net_rx_bytes_per_sec=0
    net_tx_bytes_per_sec=0
    net_rx_packets_per_sec=0
    net_tx_packets_per_sec=0
    time_interval=0

    if [ -f "$NET_STATS_FILE" ] && [ -r "$NET_STATS_FILE" ]; then
        local prev_data
        prev_data=$(cat "$NET_STATS_FILE" 2>/dev/null || echo "")

        if [ -n "$prev_data" ]; then
            local prev_array=($prev_data)
            if [ ${#prev_array[@]} -eq 5 ]; then
                local prev_time="${prev_array[0]}"
                local prev_rx_bytes="${prev_array[1]}"
                local prev_tx_bytes="${prev_array[2]}"
                local prev_rx_packets="${prev_array[3]}"
                local prev_tx_packets="${prev_array[4]}"

                if is_numeric "$prev_time" && is_numeric "$prev_rx_bytes" &&
                   is_numeric "$prev_tx_bytes" && is_numeric "$prev_rx_packets" &&
                   is_numeric "$prev_tx_packets"; then

                    if [ "$current_time" -gt "$prev_time" ]; then
            time_interval=$((current_time - prev_time))

                        # Reasonable time interval (10 seconds to 10 minutes)
                        if [ "$time_interval" -ge 10 ] && [ "$time_interval" -le 600 ]; then
                    local rx_byte_diff=$((current_rx_bytes - prev_rx_bytes))
                    local tx_byte_diff=$((current_tx_bytes - prev_tx_bytes))
                    local rx_packet_diff=$((current_rx_packets - prev_rx_packets))
                    local tx_packet_diff=$((current_tx_packets - prev_tx_packets))

                            # Handle counter resets
                            [ "$rx_byte_diff" -lt 0 ] && rx_byte_diff=0
                            [ "$tx_byte_diff" -lt 0 ] && tx_byte_diff=0
                            [ "$rx_packet_diff" -lt 0 ] && rx_packet_diff=0
                            [ "$tx_packet_diff" -lt 0 ] && tx_packet_diff=0

                            # Calculate rates
                    net_rx_bytes_per_sec=$((rx_byte_diff / time_interval))
                    net_tx_bytes_per_sec=$((tx_byte_diff / time_interval))
                    net_rx_packets_per_sec=$((rx_packet_diff / time_interval))
                    net_tx_packets_per_sec=$((tx_packet_diff / time_interval))
                        fi
                    fi
            fi
        fi
    fi
    fi

    # Store current stats for next run
    echo "$current_time $current_rx_bytes $current_tx_bytes $current_rx_packets $current_tx_packets" > "$NET_STATS_FILE" 2>/dev/null || true

    # Set global variables
    net_rx_bytes="$current_rx_bytes"
    net_tx_bytes="$current_tx_bytes"
    net_rx_packets="$current_rx_packets"
    net_tx_packets="$current_tx_packets"
    net_rx_errors="$current_rx_errors"
    net_tx_errors="$current_tx_errors"
    net_rx_dropped="$current_rx_dropped"
    net_tx_dropped="$current_tx_dropped"
}

# Get interface details - simplified
collect_interface_info() {
    interface_details=""
    total_interface_speed=0
    active_interfaces=0

    if [ -d /sys/class/net ]; then
        for iface_dir in /sys/class/net/*; do
            [ -d "$iface_dir" ] || continue
            local iface=$(basename "$iface_dir")

            # Skip virtual interfaces
        [[ "$iface" =~ ^(lo|docker|veth|br-) ]] && continue

        # Check if interface is up
            local operstate="down"
            if [ -f "$iface_dir/operstate" ] && [ -r "$iface_dir/operstate" ]; then
                operstate=$(cat "$iface_dir/operstate" 2>/dev/null || echo "down")
            fi

        if [ "$operstate" = "up" ]; then
                local speed=1000  # Default to 1Gbps
                local speed_display="1000Mbps"

                if [ -f "$iface_dir/speed" ] && [ -r "$iface_dir/speed" ]; then
                    local speed_raw=$(cat "$iface_dir/speed" 2>/dev/null || echo "1000")
                    if is_numeric "$speed_raw" && [ "$speed_raw" -gt 0 ]; then
                        speed="$speed_raw"
                        speed_display="${speed}Mbps"
                    elif [ "$speed_raw" = "-1" ]; then
                    speed_display="virtual"
                    fi
                fi

                total_interface_speed=$((total_interface_speed + speed))
                active_interfaces=$((active_interfaces + 1))

            if [ -n "$interface_details" ]; then
                    interface_details="${interface_details},${iface}:${speed_display}"
                else
                    interface_details="${iface}:${speed_display}"
            fi
        fi
    done
    fi

    # Calculate network utilization
    net_rx_utilization="0.00"
    net_tx_utilization="0.00"
    net_total_utilization="0.00"

    if [ "$total_interface_speed" -gt 0 ] &&
       ([ "$net_rx_bytes_per_sec" -gt 0 ] || [ "$net_tx_bytes_per_sec" -gt 0 ]); then

            local rx_mbps=$(awk -v bytes="$net_rx_bytes_per_sec" 'BEGIN {printf "%.2f", (bytes * 8) / 1000000}' 2>/dev/null || echo "0.00")
            local tx_mbps=$(awk -v bytes="$net_tx_bytes_per_sec" 'BEGIN {printf "%.2f", (bytes * 8) / 1000000}' 2>/dev/null || echo "0.00")

            net_rx_utilization=$(awk -v rx="$rx_mbps" -v speed="$total_interface_speed" 'BEGIN {
                if (speed > 0) printf "%.2f", (rx / speed) * 100; else print "0.00"
            }' 2>/dev/null || echo "0.00")

            net_tx_utilization=$(awk -v tx="$tx_mbps" -v speed="$total_interface_speed" 'BEGIN {
                if (speed > 0) printf "%.2f", (tx / speed) * 100; else print "0.00"
            }' 2>/dev/null || echo "0.00")

            net_total_utilization=$(awk -v rx="$net_rx_utilization" -v tx="$net_tx_utilization" 'BEGIN {
                printf "%.2f", (rx > tx) ? rx : tx
            }' 2>/dev/null || echo "0.00")
    fi
}

# System information
collect_system_info() {
hostname=$(hostname 2>/dev/null || echo "unknown")
kernel_version=$(uname -r 2>/dev/null || echo "unknown")

    # OS information
if [ -f /etc/os-release ] && [ -r /etc/os-release ]; then
        local name_line version_line
        name_line=$(grep "^NAME=" /etc/os-release 2>/dev/null || echo "")
        version_line=$(grep "^VERSION_ID=" /etc/os-release 2>/dev/null || echo "")

        if [ -n "$name_line" ]; then
            os_name=$(echo "$name_line" | cut -d= -f2 | tr -d '"' 2>/dev/null || echo "unknown")
        fi
        if [ -n "$version_line" ]; then
            os_version=$(echo "$version_line" | cut -d= -f2 | tr -d '"' 2>/dev/null || echo "unknown")
        fi
fi

    # Process count
if [[ "$running_processes" =~ ^[0-9]+/([0-9]+)$ ]]; then
    process_count="${BASH_REMATCH[1]}"
    elif is_numeric "$total_processes"; then
    process_count="$total_processes"
fi

    # Open files
if [ -r /proc/sys/fs/file-nr ]; then
    open_files=$(awk '{print int($1)}' /proc/sys/fs/file-nr 2>/dev/null || echo "0")
fi

    # TCP connections - simplified
if [ -r /proc/net/tcp ]; then
        tcp_connections=$(awk 'NR>1 {count++} END {print count+0}' /proc/net/tcp 2>/dev/null || echo "0")
    if [ -r /proc/net/tcp6 ]; then
            local tcp6_count=$(awk 'NR>1 {count++} END {print count+0}' /proc/net/tcp6 2>/dev/null || echo "0")
            tcp_connections=$((tcp_connections + tcp6_count))
fi
fi
}

# IP address information - with strict timeouts
collect_ip_info() {
    # Local IPs
if command -v hostname >/dev/null 2>&1; then
        local_ips=$(timeout 3 hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.' | grep -v '^127\.' | tr '\n' ',' | sed 's/,$//' 2>/dev/null || echo "")
        primary_ip=$(echo "$local_ips" | cut -d, -f1 2>/dev/null || echo "")
fi

    # External IP with very strict timeout
if command -v curl >/dev/null 2>&1; then
        external_ip=$(timeout 3 curl -s --connect-timeout 2 --max-time 3 "https://ipv4.icanhazip.com" 2>/dev/null | tr -d '\n\r' | head -c 15 || echo "unknown")
        # Validate IP format
        if ! [[ "$external_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    external_ip="unknown"
fi
    fi
}

# JSON escaping function
escape_json() {
    local input="$1"
    input="${input//\\/\\\\}"
    input="${input//\"/\\\"}"
    input="${input//$'\t'/\\t}"
    input="${input//$'\r'/\\r}"
    input="${input//$'\n'/\\n}"
    echo "$input"
}

# Main collection process
main() {
    collect_basic_stats
    collect_memory_stats
    collect_cpu_stats
    collect_filesystem_stats
    collect_network_stats
    collect_interface_info
    collect_system_info
    collect_ip_info

    # Escape variables
    local hostname_escaped=$(escape_json "$hostname")
    local kernel_version_escaped=$(escape_json "$kernel_version")
    local os_name_escaped=$(escape_json "$os_name")
    local os_version_escaped=$(escape_json "$os_version")
    local local_ips_escaped=$(escape_json "$local_ips")
    local primary_ip_escaped=$(escape_json "$primary_ip")
    local external_ip_escaped=$(escape_json "$external_ip")
    local interface_details_escaped=$(escape_json "$interface_details")

    # Build JSON payload using printf for better memory efficiency
    local json_payload
    json_payload=$(printf '{"uptime_seconds":%d,"loadavg_1":%s,"loadavg_5":%s,"loadavg_15":%s,"load_per_core":%s,"mem_total_kb":%d,"mem_free_kb":%d,"mem_available_kb":%d,"mem_used_kb":%d,"mem_usage_percent":%s,"mem_buffers_kb":%d,"mem_cached_kb":%d,"swap_total_kb":%d,"swap_free_kb":%d,"cpu_user_ticks":%d,"cpu_system_ticks":%d,"cpu_idle_ticks":%d,"cpu_iowait_ticks":%d,"cpu_cores":%d,"rootfs_total_kb":%d,"rootfs_used_kb":%d,"rootfs_available_kb":%d,"rootfs_used_percent":%d,"net_rx_bytes":%d,"net_tx_bytes":%d,"net_rx_bytes_per_sec":%d,"net_tx_bytes_per_sec":%d,"net_rx_packets":%d,"net_tx_packets":%d,"net_rx_packets_per_sec":%d,"net_tx_packets_per_sec":%d,"net_rx_errors":%d,"net_tx_errors":%d,"net_rx_dropped":%d,"net_tx_dropped":%d,"net_rx_utilization":%s,"net_tx_utilization":%s,"net_total_utilization":%s,"net_interface_speed_mbps":%d,"net_active_interfaces":%d,"net_interval_seconds":%d,"hostname":"%s","kernel_version":"%s","os_name":"%s","os_version":"%s","process_count":%d,"open_files":%d,"tcp_connections":%d,"local_ips":"%s","primary_ip":"%s","external_ip":"%s","interface_info":"%s","timestamp":"%s"}' \
        "$uptime_seconds" "$load1" "$load5" "$load15" "$load_per_core" \
        "$mem_total_kb" "$mem_free_kb" "$mem_available_kb" "$mem_used_kb" "$mem_usage_percent" \
        "$mem_buffers_kb" "$mem_cached_kb" "$swap_total_kb" "$swap_free_kb" \
        "$cpu_user_ticks" "$cpu_system_ticks" "$cpu_idle_ticks" "$cpu_iowait_ticks" "$cpu_cores" \
        "$rootfs_total_kb" "$rootfs_used_kb" "$rootfs_available_kb" "$rootfs_used_percent" \
        "$net_rx_bytes" "$net_tx_bytes" "$net_rx_bytes_per_sec" "$net_tx_bytes_per_sec" \
        "$net_rx_packets" "$net_tx_packets" "$net_rx_packets_per_sec" "$net_tx_packets_per_sec" \
        "$net_rx_errors" "$net_tx_errors" "$net_rx_dropped" "$net_tx_dropped" \
        "$net_rx_utilization" "$net_tx_utilization" "$net_total_utilization" \
        "$total_interface_speed" "$active_interfaces" "$time_interval" \
        "$hostname_escaped" "$kernel_version_escaped" "$os_name_escaped" "$os_version_escaped" \
        "$process_count" "$open_files" "$tcp_connections" \
        "$local_ips_escaped" "$primary_ip_escaped" "$external_ip_escaped" "$interface_details_escaped" \
        "$collection_timestamp")

    # Random delay to prevent API load spikes (reduced from 40 to 20 seconds)
    local sending_delay=$((RANDOM % 21))
    sleep "$sending_delay"

    # Send metrics with strict timeout
if command -v curl >/dev/null 2>&1; then
        timeout 15 curl -s -X POST \
  "https://sitecenter.app/api/pub/v1/a/${ACCOUNT_CODE}/monitor/${MONITOR_CODE}/host-stats" \
  -H "Content-Type: application/json" \
  -H "X-Monitor-Secret: ${SECRET_CODE}" \
  -d "$json_payload" \
      >/dev/null 2>&1 || true
fi
}

# Run main function
main