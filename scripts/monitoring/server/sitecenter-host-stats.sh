#!/bin/bash
# Usage:
# ./sitecenter-host-stats.sh ACCOUNT_CODE MONITOR_CODE SECRET_CODE
# Version: 2025-08-21-NETWORK-FIXED-STOP-ON-ERROR

set -e

# Environment file path
ENV_FILE="/usr/local/bin/sitecenter-host-env.sh"

# Source environment variables
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE" 2>/dev/null || true
fi

# Check if monitoring is stopped
if [ "${SITECENTER_STOPPED:-false}" = "true" ]; then
    echo "Monitoring is stopped. Exiting..." >&2
    exit 0
fi

ACCOUNT_CODE="${1:-$SITECENTER_ACCOUNT}"
MONITOR_CODE="${2:-$SITECENTER_MONITOR}"
SECRET_CODE="${3:-$SITECENTER_SECRET}"

if [[ -z "$ACCOUNT_CODE" || -z "$MONITOR_CODE" || -z "$SECRET_CODE" ]]; then
  echo "Usage: $0 ACCOUNT_CODE MONITOR_CODE SECRET_CODE" >&2
  exit 1
fi

# Temporary file to store previous network stats for rate calculation
NET_STATS_FILE="/tmp/sitecenter-net-stats-${MONITOR_CODE}.tmp"

# Current timestamp
current_time=$(date +%s)

# Capture the exact collection timestamp in UTC (ISO 8601 format for Java)
collection_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")

# Uptime (seconds) - with error handling
uptime_seconds=0
if [ -r /proc/uptime ]; then
    uptime_seconds=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo "0")
fi

# Load averages and process info - with validation
load1=0 load5=0 load15=0 running_processes="0/0" total_processes=0
if [ -r /proc/loadavg ]; then
    {
        read load1 load5 load15 running_processes total_processes _
    } < /proc/loadavg 2>/dev/null || {
        load1=0 load5=0 load15=0 running_processes="0/0" total_processes=0
    }
fi

# Memory info
declare -A meminfo
if [ -r /proc/meminfo ]; then
    while IFS=': ' read -r key value unit; do
        if [[ -n "$key" && "$value" =~ ^[0-9]+$ ]]; then
            meminfo["$key"]="$value"
        fi
    done < /proc/meminfo 2>/dev/null
fi

# Set defaults for memory values
mem_total_kb=${meminfo[MemTotal]:-0}
mem_free_kb=${meminfo[MemFree]:-0}
mem_available_kb=${meminfo[MemAvailable]:-$mem_free_kb}
mem_buffers_kb=${meminfo[Buffers]:-0}
mem_cached_kb=${meminfo[Cached]:-0}
swap_total_kb=${meminfo[SwapTotal]:-0}
swap_free_kb=${meminfo[SwapFree]:-0}

# Calculate used memory safely
mem_used_kb=0
if [ "$mem_total_kb" -gt 0 ] && [ "$mem_available_kb" -ge 0 ]; then
mem_used_kb=$((mem_total_kb - mem_available_kb))
if [ "$mem_used_kb" -lt 0 ]; then
    mem_used_kb=0
fi
fi

# Calculate memory percentage safely
mem_usage_percent="0.00"
if [ "$mem_total_kb" -gt 0 ] && [ "$mem_used_kb" -ge 0 ]; then
    mem_usage_percent=$(awk -v used="$mem_used_kb" -v total="$mem_total_kb" 'BEGIN {
        if (total > 0) {
            result = (used / total) * 100
            if (result >= 0 && result <= 100) {
                printf "%.2f", result
        } else {
                print "0.00"
            }
        } else {
            print "0.00"
        }
    }' 2>/dev/null || echo "0.00")
fi

# CPU ticks - safer parsing
cpu_user_ticks=0 cpu_system_ticks=0 cpu_idle_ticks=0 cpu_iowait_ticks=0
if [ -r /proc/stat ]; then
    {
        read cpu user nice system idle iowait _
        if [[ "$user" =~ ^[0-9]+$ ]] && [[ "$nice" =~ ^[0-9]+$ ]]; then
cpu_user_ticks=$((user + nice))
        fi
        if [[ "$system" =~ ^[0-9]+$ ]]; then
cpu_system_ticks=$system
        fi
        if [[ "$idle" =~ ^[0-9]+$ ]]; then
cpu_idle_ticks=$idle
        fi
        if [[ "$iowait" =~ ^[0-9]+$ ]]; then
cpu_iowait_ticks=$iowait
        fi
    } < /proc/stat 2>/dev/null
fi

# CPU core count
cpu_cores=1
if [ -r /proc/cpuinfo ]; then
cpu_cores=$(grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo "1")
fi

# Filesystem usage (root) - safer parsing
rootfs_total_kb=0 rootfs_used_kb=0 rootfs_available_kb=0 rootfs_used_percent=0
if command -v df >/dev/null 2>&1; then
    df_output=$(df -BK / 2>/dev/null | awk 'NR==2 {print $2, $3, $4, $5}' || echo "0K 0K 0K 0%")
    read rootfs_total_raw rootfs_used_raw rootfs_available_raw rootfs_used_percent_raw <<< "$df_output"

    # Remove 'K' suffix and validate
    rootfs_total_kb=${rootfs_total_raw%K}
    rootfs_used_kb=${rootfs_used_raw%K}
    rootfs_available_kb=${rootfs_available_raw%K}
rootfs_used_percent=${rootfs_used_percent_raw%\%}

    # Validate numbers
    [[ "$rootfs_total_kb" =~ ^[0-9]+$ ]] || rootfs_total_kb=0
    [[ "$rootfs_used_kb" =~ ^[0-9]+$ ]] || rootfs_used_kb=0
    [[ "$rootfs_available_kb" =~ ^[0-9]+$ ]] || rootfs_available_kb=0
    [[ "$rootfs_used_percent" =~ ^[0-9]+$ ]] || rootfs_used_percent=0
fi

# Enhanced Network Statistics Collection
collect_network_stats() {
    # Initialize all variables with safe defaults
    local current_rx_bytes=0 current_tx_bytes=0
    local current_rx_packets=0 current_tx_packets=0
    local current_rx_errors=0 current_tx_errors=0
    local current_rx_dropped=0 current_tx_dropped=0

    # Safely parse /proc/net/dev
    if [ -r /proc/net/dev ]; then
        while IFS= read -r line; do
            # Skip header lines and validate line format
            if [[ "$line" =~ ^[[:space:]]*([a-zA-Z0-9]+):[[:space:]]*(.+)$ ]]; then
                local iface="${BASH_REMATCH[1]}"
                local stats_line="${BASH_REMATCH[2]}"

                # Skip loopback interface
                [[ "$iface" == "lo" ]] && continue

                # Parse stats with safer method - use array
                local stats_array=($stats_line)

                # Validate we have enough fields (at least 16)
                if [ ${#stats_array[@]} -ge 16 ]; then
                    # RX: bytes, packets, errs, drop (positions 0, 1, 2, 3)
                    local rx_bytes="${stats_array[0]:-0}"
                    local rx_packets="${stats_array[1]:-0}"
                    local rx_errs="${stats_array[2]:-0}"
                    local rx_drop="${stats_array[3]:-0}"

                    # TX: bytes, packets, errs, drop (positions 8, 9, 10, 11)
                    local tx_bytes="${stats_array[8]:-0}"
                    local tx_packets="${stats_array[9]:-0}"
                    local tx_errs="${stats_array[10]:-0}"
                    local tx_drop="${stats_array[11]:-0}"

                    # Validate all values are numeric before adding
                    if [[ "$rx_bytes" =~ ^[0-9]+$ ]]; then
            current_rx_bytes=$((current_rx_bytes + rx_bytes))
                    fi
                    if [[ "$rx_packets" =~ ^[0-9]+$ ]]; then
            current_rx_packets=$((current_rx_packets + rx_packets))
                    fi
                    if [[ "$rx_errs" =~ ^[0-9]+$ ]]; then
            current_rx_errors=$((current_rx_errors + rx_errs))
                    fi
                    if [[ "$rx_drop" =~ ^[0-9]+$ ]]; then
                        current_rx_dropped=$((current_rx_dropped + rx_drop))
                    fi
                    if [[ "$tx_bytes" =~ ^[0-9]+$ ]]; then
                        current_tx_bytes=$((current_tx_bytes + tx_bytes))
                    fi
                    if [[ "$tx_packets" =~ ^[0-9]+$ ]]; then
                        current_tx_packets=$((current_tx_packets + tx_packets))
                    fi
                    if [[ "$tx_errs" =~ ^[0-9]+$ ]]; then
            current_tx_errors=$((current_tx_errors + tx_errs))
                    fi
                    if [[ "$tx_drop" =~ ^[0-9]+$ ]]; then
            current_tx_dropped=$((current_tx_dropped + tx_drop))
        fi
                fi
            fi
        done < /proc/net/dev 2>/dev/null
    fi

    # Initialize rate variables
    net_rx_bytes_per_sec=0
    net_tx_bytes_per_sec=0
    net_rx_packets_per_sec=0
    net_tx_packets_per_sec=0
    time_interval=0

    # Try to read previous stats for rate calculation
    if [ -f "$NET_STATS_FILE" ] && [ -r "$NET_STATS_FILE" ]; then
        local prev_data
        prev_data=$(cat "$NET_STATS_FILE" 2>/dev/null) || prev_data=""

        if [ -n "$prev_data" ]; then
            # Parse previous data safely
            local prev_values=($prev_data)

            # Validate we have enough values
            if [ ${#prev_values[@]} -ge 5 ]; then
                local prev_time="${prev_values[0]:-0}"
                local prev_rx_bytes="${prev_values[1]:-0}"
                local prev_tx_bytes="${prev_values[2]:-0}"
                local prev_rx_packets="${prev_values[3]:-0}"
                local prev_tx_packets="${prev_values[4]:-0}"

                # Validate all are numeric
                if [[ "$prev_time" =~ ^[0-9]+$ ]] && \
                   [[ "$prev_rx_bytes" =~ ^[0-9]+$ ]] && \
                   [[ "$prev_tx_bytes" =~ ^[0-9]+$ ]] && \
                   [[ "$prev_rx_packets" =~ ^[0-9]+$ ]] && \
                   [[ "$prev_tx_packets" =~ ^[0-9]+$ ]]; then

                    # Calculate time interval
                    if [ "$current_time" -gt "$prev_time" ]; then
            time_interval=$((current_time - prev_time))

                        # Reasonable time interval check (10 seconds to 20 minutes)
                if [ "$time_interval" -ge 10 ] && [ "$time_interval" -le 1200 ]; then
                            # Calculate differences safely
                    local rx_byte_diff=$((current_rx_bytes - prev_rx_bytes))
                    local tx_byte_diff=$((current_tx_bytes - prev_tx_bytes))
                    local rx_packet_diff=$((current_rx_packets - prev_rx_packets))
                    local tx_packet_diff=$((current_tx_packets - prev_tx_packets))

                    # Handle counter resets (negative differences)
                            [ "$rx_byte_diff" -lt 0 ] && rx_byte_diff=0
                            [ "$tx_byte_diff" -lt 0 ] && tx_byte_diff=0
                            [ "$rx_packet_diff" -lt 0 ] && rx_packet_diff=0
                            [ "$tx_packet_diff" -lt 0 ] && tx_packet_diff=0

                            # Calculate per-second rates
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

    # Store current stats for next run - with error handling
    echo "$current_time $current_rx_bytes $current_tx_bytes $current_rx_packets $current_tx_packets" > "$NET_STATS_FILE" 2>/dev/null || true

    # Set global variables
    net_rx_bytes=$current_rx_bytes
    net_tx_bytes=$current_tx_bytes
    net_rx_packets=$current_rx_packets
    net_tx_packets=$current_tx_packets
    net_rx_errors=$current_rx_errors
    net_tx_errors=$current_tx_errors
    net_rx_dropped=$current_rx_dropped
    net_tx_dropped=$current_tx_dropped
}

# Call network collection function
collect_network_stats

# Network interface detection and speed calculation - PHYSICAL INTERFACES ONLY
    total_interface_speed=0
    active_interfaces=0
interface_details=""

    if [ -d /sys/class/net ]; then
    for iface_path in /sys/class/net/*; do
        [ -d "$iface_path" ] || continue
        iface=$(basename "$iface_path")

        # Skip loopback, virtual, and bridge interfaces
        [[ "$iface" =~ ^(lo|docker|veth|br-|tap|fwbr|fwln|fwpr|vmb) ]] && continue

        # Only process physical ethernet interfaces (enp, eth, eno, ens, etc.)
        [[ "$iface" =~ ^(enp|eth|eno|ens|em|p[0-9]+p) ]] || continue

        # Check if interface is up
                operstate=$(cat "$iface_path/operstate" 2>/dev/null || echo "down")
        if [ "$operstate" = "up" ]; then
            # Get interface speed
            speed_raw=$(cat "$iface_path/speed" 2>/dev/null || echo "0")
                    if [[ "$speed_raw" =~ ^[0-9]+$ ]] && [ "$speed_raw" -gt 0 ]; then
                # Valid physical interface speed detected
                total_interface_speed=$((total_interface_speed + speed_raw))
                        active_interfaces=$((active_interfaces + 1))
                [ -n "$interface_details" ] && interface_details="${interface_details},"
                interface_details="${interface_details}${iface}:${speed_raw}Mbps"
            fi
        fi
    done
    fi

# Calculate network utilization
    net_rx_utilization="0.00"
    net_tx_utilization="0.00"
    net_total_utilization="0.00"

    if [ "$total_interface_speed" -gt 0 ] &&
       [[ "$net_rx_bytes_per_sec" =~ ^[0-9]+$ ]] &&
       [[ "$net_tx_bytes_per_sec" =~ ^[0-9]+$ ]]; then

        if [ "$net_rx_bytes_per_sec" -gt 0 ] || [ "$net_tx_bytes_per_sec" -gt 0 ]; then
        # Convert bytes/sec to Mbps (bytes * 8 / 1,000,000)
        rx_mbps=$(awk -v bytes="$net_rx_bytes_per_sec" 'BEGIN {printf "%.6f", (bytes * 8) / 1000000}' 2>/dev/null || echo "0.000000")
        tx_mbps=$(awk -v bytes="$net_tx_bytes_per_sec" 'BEGIN {printf "%.6f", (bytes * 8) / 1000000}' 2>/dev/null || echo "0.000000")

        # Calculate utilization percentages
            net_rx_utilization=$(awk -v rx="$rx_mbps" -v speed="$total_interface_speed" 'BEGIN {
                if (speed > 0) printf "%.2f", (rx / speed) * 100; else print "0.00"
            }' 2>/dev/null || echo "0.00")

            net_tx_utilization=$(awk -v tx="$tx_mbps" -v speed="$total_interface_speed" 'BEGIN {
                if (speed > 0) printf "%.2f", (tx / speed) * 100; else print "0.00"
            }' 2>/dev/null || echo "0.00")

            # Total utilization is the higher of RX or TX
            net_total_utilization=$(awk -v rx="$net_rx_utilization" -v tx="$net_tx_utilization" 'BEGIN {
                printf "%.2f", (rx > tx) ? rx : tx
            }' 2>/dev/null || echo "0.00")
    fi
    fi

# Ensure all network variables have valid defaults
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
net_rx_utilization=${net_rx_utilization:-0.00}
net_tx_utilization=${net_tx_utilization:-0.00}
net_total_utilization=${net_total_utilization:-0.00}
total_interface_speed=${total_interface_speed:-0}
active_interfaces=${active_interfaces:-0}
time_interval=${time_interval:-0}
interface_details=${interface_details:-""}

# System information - with error handling
hostname=$(hostname 2>/dev/null || echo "unknown")
kernel_version=$(uname -r 2>/dev/null || echo "unknown")

# OS information - safer parsing
os_name="unknown"
os_version="unknown"
if [ -f /etc/os-release ] && [ -r /etc/os-release ]; then
    # Source safely
    {
        NAME=""
        VERSION_ID=""
        source /etc/os-release 2>/dev/null
        [ -n "$NAME" ] && os_name="$NAME"
        [ -n "$VERSION_ID" ] && os_version="$VERSION_ID"
    }
elif [ -f /etc/redhat-release ] && [ -r /etc/redhat-release ]; then
    os_name=$(cat /etc/redhat-release 2>/dev/null || echo "unknown")
elif [ -f /etc/debian_version ] && [ -r /etc/debian_version ]; then
    os_name="Debian"
    os_version=$(cat /etc/debian_version 2>/dev/null || echo "unknown")
fi

# Process count - safer parsing
process_count=0
if [[ "$running_processes" =~ ^[0-9]+/([0-9]+)$ ]]; then
    process_count="${BASH_REMATCH[1]}"
elif [[ "$total_processes" =~ ^[0-9]+$ ]]; then
    process_count="$total_processes"
fi

# Open file descriptors
open_files=0
if [ -r /proc/sys/fs/file-nr ]; then
    open_files=$(awk '{print int($1)}' /proc/sys/fs/file-nr 2>/dev/null || echo "0")
fi

# TCP connections count - safer version
tcp_connections=0
if [ -r /proc/net/tcp ]; then
    tcp4_count=$(awk 'NR>1 {count++} END {print count+0}' /proc/net/tcp 2>/dev/null || echo "0")
    tcp6_count=0
    if [ -r /proc/net/tcp6 ]; then
        tcp6_count=$(awk 'NR>1 {count++} END {print count+0}' /proc/net/tcp6 2>/dev/null || echo "0")
    fi
    tcp_connections=$((tcp4_count + tcp6_count))
fi

# System load per core - safer calculation
load_per_core="0.00"
if [ "$cpu_cores" -gt 0 ] && [[ "$load1" =~ ^[0-9]+\.?[0-9]*$ ]]; then
    load_per_core=$(awk -v load="$load1" -v cores="$cpu_cores" 'BEGIN {printf "%.2f", load / cores}' 2>/dev/null || echo "0.00")
fi

# IP Address Information - with timeouts and error handling
local_ips=""
primary_ip=""
external_ip="unknown"

# Get local IPs safely
if command -v hostname >/dev/null 2>&1; then
    local_ips=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.' | grep -v '^127\.' | tr '\n' ',' | sed 's/,$//' 2>/dev/null || echo "")
    primary_ip=$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i!~"^127\\.") {print $i; exit}}' 2>/dev/null || echo "")
fi

# Get external IP with strict timeout and error handling
if command -v curl >/dev/null 2>&1; then
    for service in "https://ipv4.icanhazip.com" "https://api.ipify.org"; do
        external_ip=$(timeout 5 curl -s --connect-timeout 3 --max-time 5 "$service" 2>/dev/null | tr -d '\n\r' || echo "")
        if [[ "$external_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            break
        fi
    external_ip="unknown"
done
fi

# Escape strings for JSON - safer version
escape_json() {
    local input="$1"
    # Replace problematic characters
    input="${input//\\/\\\\}"  # backslash
    input="${input//\"/\\\"}"  # quote
    input="${input//$'\t'/\\t}" # tab
    input="${input//$'\r'/\\r}" # carriage return
    input="${input//$'\n'/\\n}" # newline
    echo "$input"
}

# Escape variables safely
local_ips_escaped=$(escape_json "$local_ips")
primary_ip_escaped=$(escape_json "$primary_ip")
external_ip_escaped=$(escape_json "$external_ip")
interface_details_escaped=$(escape_json "$interface_details")
hostname_escaped=$(escape_json "$hostname")
kernel_version_escaped=$(escape_json "$kernel_version")
os_name_escaped=$(escape_json "$os_name")
os_version_escaped=$(escape_json "$os_version")

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
  "hostname": "$hostname_escaped",
  "kernel_version": "$kernel_version_escaped",
  "os_name": "$os_name_escaped",
  "os_version": "$os_version_escaped",
  "process_count": $process_count,
  "open_files": $open_files,
  "tcp_connections": $tcp_connections,
  "local_ips": "$local_ips_escaped",
  "primary_ip": "$primary_ip_escaped",
  "external_ip": "$external_ip_escaped",
  "interface_info": "$interface_details_escaped",
  "timestamp": "$collection_timestamp"
}
EOF
)

# Random sending delay to prevent API load spikes
sending_delay=$((RANDOM % 41))  # 0-40 seconds
sleep $sending_delay

# Function to mark monitoring as stopped
mark_as_stopped() {
    local reason="$1"
    echo "CRITICAL: $reason - Stopping monitoring" >&2

    # Create environment file if it doesn't exist
    if [ ! -f "$ENV_FILE" ]; then
        touch "$ENV_FILE" 2>/dev/null || {
            echo "ERROR: Cannot create $ENV_FILE - monitoring will continue but won't persist stopped state" >&2
            return 1
        }
            fi

    # Check if SITECENTER_STOPPED variable exists in the file
    if grep -q "^SITECENTER_STOPPED=" "$ENV_FILE" 2>/dev/null; then
        # Variable exists - update it to true
        sed -i 's/^SITECENTER_STOPPED=.*/SITECENTER_STOPPED=true/' "$ENV_FILE" 2>/dev/null || {
            echo "ERROR: Cannot update $ENV_FILE" >&2
            return 1
        }
    else
        # Variable doesn't exist - append it
        echo "SITECENTER_STOPPED=true" >> "$ENV_FILE" 2>/dev/null || {
            echo "ERROR: Cannot write to $ENV_FILE" >&2
            return 1
        }
    fi

    echo "Monitoring has been disabled. To re-enable, edit $ENV_FILE and set SITECENTER_STOPPED=false" >&2
}

# Send metrics via curl and capture response
if command -v curl >/dev/null 2>&1; then
    response=$(timeout 30 curl -s -w "\nHTTP_CODE:%{http_code}" -X POST \
  "https://mon.sitecenter.app/api/pub/v1/a/${ACCOUNT_CODE}/monitor/${MONITOR_CODE}/host-stats" \
  -H "Content-Type: application/json" \
  -H "X-Monitor-Secret: ${SECRET_CODE}" \
        -d "$json_payload" 2>&1) || true

    # Extract HTTP code and response body
    http_code=$(echo "$response" | grep "HTTP_CODE:" | cut -d: -f2)
    response_body=$(echo "$response" | sed '/HTTP_CODE:/d')

    # Check for critical errors in the response
    if echo "$response_body" | grep -q "Invalid secret!"; then
        mark_as_stopped "Invalid secret"
        exit 1
    fi

    if echo "$response_body" | grep -q "Monitor is not active!"; then
        mark_as_stopped "Monitor is not active"
        exit 1
fi

    # Log successful submission (optional)
    if [ "$http_code" = "200" ]; then
        # Success - no action needed
        :
    else
        # Non-critical error - log but continue
        echo "Warning: Received HTTP code $http_code" >&2
    fi
fi

exit 0