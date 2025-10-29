#!/bin/bash
# sitecenter-docker-stats.sh
# Collects docker statistics and sends them to SiteCenter API
# Compatible with host stats flat JSON format

# Usage:
# ./sitecenter-docker-stats.sh ACCOUNT_CODE MONITOR_CODE SECRET_CODE
# Version: 2025-08-21-NETWORK-FIXED-STOP-ON-ERROR

set -e

# Environment file path
ENV_FILE="/usr/local/bin/sitecenter-docker-env.sh"

# Source environment variables
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE" 2>/dev/null || true
fi

# Check if monitoring is stopped permanently
if [ "${SITECENTER_STOPPED:-false}" = "true" ]; then
    echo "Monitoring is stopped permanently. Exiting..." >&2
    exit 0
fi

# Check if monitoring is paused until a specific date
if [ -n "${SITECENTER_PAUSED_TILL:-}" ]; then
    current_date=$(date +%s)
    pause_until=$(date -d "$SITECENTER_PAUSED_TILL" +%s 2>/dev/null || echo "0")

    if [ "$pause_until" -gt 0 ]; then
        if [ "$current_date" -ge "$pause_until" ]; then
            # Pause period has expired - reset the variable and continue
            echo "Pause period expired. Resetting SITECENTER_PAUSED_TILL and resuming monitoring..." >&2

            # Remove SITECENTER_PAUSED_TILL from env file
            if [ -f "$ENV_FILE" ]; then
                sed -i '/^SITECENTER_PAUSED_TILL=/d' "$ENV_FILE" 2>/dev/null || true
            fi
        else
            # Still paused
            pause_remaining=$((pause_until - current_date))
            hours_remaining=$((pause_remaining / 3600))
            minutes_remaining=$(((pause_remaining % 3600) / 60))
            echo "Monitoring is paused until $SITECENTER_PAUSED_TILL (${hours_remaining}h ${minutes_remaining}m remaining). Exiting..." >&2
            exit 0
        fi
    fi
fi

ACCOUNT_CODE="${1:-$SITECENTER_ACCOUNT}"
MONITOR_CODE="${2:-$SITECENTER_MONITOR}"
SECRET_CODE="${3:-$SITECENTER_SECRET}"

if [[ -z "$ACCOUNT_CODE" || -z "$MONITOR_CODE" || -z "$SECRET_CODE" ]]; then
  echo "Usage: $0 ACCOUNT_CODE MONITOR_CODE SECRET_CODE" >&2
  exit 1
fi

# Temporary file to store previous network stats for rate calculation
NET_STATS_FILE="/tmp/sitecenter-docker-net-stats-${MONITOR_CODE}.tmp"

# Current timestamp
current_time=$(date +%s)

# Capture the exact collection timestamp in UTC (ISO 8601 format for Java)
# Alpine Linux doesn't support %3N for nanoseconds, so we calculate milliseconds manually
collection_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S")
# Try to get milliseconds if available, otherwise append .000
if command -v date >/dev/null 2>&1; then
    millisec=$(date -u +"%3N" 2>/dev/null)
    # Check if the output looks like milliseconds (3 digits)
    if [[ "$millisec" =~ ^[0-9]{3}$ ]]; then
        collection_timestamp="${collection_timestamp}.${millisec}Z"
    else
        # Fallback: use .000 if %3N not supported
        collection_timestamp="${collection_timestamp}.000Z"
    fi
else
    collection_timestamp="${collection_timestamp}.000Z"
fi

# Container uptime (seconds) - actual container uptime, not host uptime
container_uptime_seconds=0
if [ -r /proc/uptime ]; then
    container_uptime_seconds=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo "0")
fi

if [ -f /proc/1/stat ]; then
    # Get process start time in clock ticks since boot (field 22 in /proc/1/stat)
    process_start_ticks=$(awk '{print $22}' /proc/1/stat 2>/dev/null || echo "0")
    # Get clock ticks per second
    clock_ticks_per_sec=$(getconf CLK_TCK 2>/dev/null || echo "100")
    # Get system uptime
    system_uptime=$(awk '{print $1}' /proc/uptime 2>/dev/null || echo "0")
    # Calculate container uptime
    if [ "$process_start_ticks" -gt 0 ] && [ "$clock_ticks_per_sec" -gt 0 ]; then
        process_start_seconds=$(awk "BEGIN {printf \"%.0f\", $process_start_ticks / $clock_ticks_per_sec}" 2>/dev/null || echo "0")
        container_uptime_seconds=$(awk "BEGIN {printf \"%.0f\", $system_uptime - $process_start_seconds}" 2>/dev/null || echo "0")
        # Ensure uptime is not negative (edge case protection)
        if [ "$container_uptime_seconds" -lt 0 ]; then
            container_uptime_seconds=0
        fi
    fi
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

# Robust memory calculation - works without cgroups
# Handles the "inf" issue and provides meaningful container stats

# Read /proc/meminfo safely
declare -A meminfo
if [ -r /proc/meminfo ]; then
    while IFS=': ' read -r key value unit; do
        if [[ -n "$key" && "$value" =~ ^[0-9]+$ ]]; then
            meminfo["$key"]="$value"
    fi
    done < /proc/meminfo 2>/dev/null
fi

# Set defaults to avoid division by zero
mem_total_kb=${meminfo[MemTotal]:-0}
mem_free_kb=${meminfo[MemFree]:-0}
mem_available_kb=${meminfo[MemAvailable]:-$mem_free_kb}
mem_buffers_kb=${meminfo[Buffers]:-0}
mem_cached_kb=${meminfo[Cached]:-0}
swap_total_kb=${meminfo[SwapTotal]:-0}
swap_free_kb=${meminfo[SwapFree]:-0}

# Validate we have basic memory info
if [ "$mem_total_kb" -eq 0 ]; then
    echo "ERROR: Cannot read memory information" >&2
    mem_total_kb=1  # Prevent division by zero
    mem_available_kb=1
fi

# Try to get container memory limits from various sources
container_mem_limit_kb=0

# Method 1: Try cgroups v2
if [ -f /sys/fs/cgroup/memory.max ]; then
    mem_limit_raw=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo "max")
    if [ "$mem_limit_raw" != "max" ] && [[ "$mem_limit_raw" =~ ^[0-9]+$ ]] && [ "$mem_limit_raw" -gt 0 ]; then
        container_mem_limit_kb=$((mem_limit_raw / 1024))
        if [ -f /sys/fs/cgroup/memory.current ]; then
            mem_usage_bytes=$(cat /sys/fs/cgroup/memory.current 2>/dev/null || echo "0")
            if [[ "$mem_usage_bytes" =~ ^[0-9]+$ ]]; then
                mem_used_kb=$((mem_usage_bytes / 1024))
            fi
        fi
    fi
fi

# Method 2: Try cgroups v1 if v2 didn't work
if [ "$container_mem_limit_kb" -eq 0 ] && [ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
    mem_limit_bytes=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || echo "0")
    # Check if it's a reasonable limit (not the default huge number)
    # Set a more realistic upper bound: 1TB = 1099511627776 bytes
    # This catches Docker for Windows "unlimited" values
    if [[ "$mem_limit_bytes" =~ ^[0-9]+$ ]] && [ "$mem_limit_bytes" -gt 0 ] && [ "$mem_limit_bytes" -lt 1099511627776 ]; then
        container_mem_limit_kb=$((mem_limit_bytes / 1024))
        echo "Found cgroups v1 memory limit: ${container_mem_limit_kb}KB" >&2
        if [ -f /sys/fs/cgroup/memory/memory.usage_in_bytes ]; then
            mem_usage_bytes=$(cat /sys/fs/cgroup/memory/memory.usage_in_bytes 2>/dev/null || echo "0")
            if [[ "$mem_usage_bytes" =~ ^[0-9]+$ ]]; then
                mem_used_kb=$((mem_usage_bytes / 1024))
            fi
        fi
    else
        echo "Ignoring unrealistic cgroups memory limit: ${mem_limit_bytes} bytes (likely Docker for Windows unlimited)" >&2
    fi
fi

# Method 3: Try environment variables (sometimes set by Kubernetes)
if [ "$container_mem_limit_kb" -eq 0 ] && [ -n "$MEMORY_LIMIT" ]; then
    # Parse memory limit from env var (could be like "512Mi", "1Gi", "1073741824")
    if [[ "$MEMORY_LIMIT" =~ ^([0-9]+)(Mi|Gi|Ki|M|G|K)?$ ]]; then
        num="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2]}"
        case "$unit" in
            "Gi"|"G") container_mem_limit_kb=$((num * 1024 * 1024)) ;;
            "Mi"|"M") container_mem_limit_kb=$((num * 1024)) ;;
            "Ki"|"K") container_mem_limit_kb=$num ;;
            "") container_mem_limit_kb=$((num / 1024)) ;;  # Assume bytes
        esac
    fi
fi

# Use container limit if found, otherwise use host memory
if [ "$container_mem_limit_kb" -gt 0 ]; then
    mem_total_kb=$container_mem_limit_kb
    echo "Using container memory limit: ${container_mem_limit_kb}KB" >&2
else
    echo "No container memory limit found, using host memory: ${mem_total_kb}KB" >&2
    # Calculate used memory from available
    mem_used_kb=$((mem_total_kb - mem_available_kb))
fi

# Ensure mem_used_kb is not negative (edge case protection)
if [ "$mem_used_kb" -lt 0 ]; then
    mem_used_kb=0
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

# Validate the result is not inf or nan
if [[ "$mem_usage_percent" == "inf" ]] || [[ "$mem_usage_percent" == "nan" ]] || [[ "$mem_usage_percent" == "-nan" ]]; then
    mem_usage_percent="0.00"
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

total_cpu_ticks=$((cpu_user_ticks + cpu_system_ticks + cpu_idle_ticks + cpu_iowait_ticks))

# CPU core count (available to container)
cpu_cores=1
if command -v nproc >/dev/null 2>&1; then
    cpu_cores=$(nproc 2>/dev/null || echo "1")
elif [ -r /proc/cpuinfo ]; then
    cpu_cores=$(grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo "1")
fi

# Container filesystem usage (root filesystem) - safer parsing
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

    # Set defaults for rate calculations
    net_rx_bytes_per_sec=0
    net_tx_bytes_per_sec=0
    net_rx_packets_per_sec=0
    net_tx_packets_per_sec=0
    time_interval=0

    # Read previous stats if file exists
    if [ -f "$NET_STATS_FILE" ]; then
        {
            read prev_time prev_rx_bytes prev_tx_bytes prev_rx_packets prev_tx_packets
        } < "$NET_STATS_FILE" 2>/dev/null || {
            prev_time=0 prev_rx_bytes=0 prev_tx_bytes=0 prev_rx_packets=0 prev_tx_packets=0
        }

        # Validate previous values
        if [[ "$prev_time" =~ ^[0-9]+$ ]] && [[ "$prev_rx_bytes" =~ ^[0-9]+$ ]] && [[ "$prev_tx_bytes" =~ ^[0-9]+$ ]]; then
            # Calculate time interval
            time_interval=$((current_time - prev_time))

            # Only calculate rates if interval is reasonable (1-3600 seconds)
            if [ "$time_interval" -gt 0 ] && [ "$time_interval" -le 3600 ]; then
                # Calculate byte rates safely
                local rx_bytes_diff=$((current_rx_bytes - prev_rx_bytes))
                local tx_bytes_diff=$((current_tx_bytes - prev_tx_bytes))

                # Handle counter wrap-around (unlikely but possible)
                if [ "$rx_bytes_diff" -ge 0 ]; then
                    net_rx_bytes_per_sec=$((rx_bytes_diff / time_interval))
                fi
                if [ "$tx_bytes_diff" -ge 0 ]; then
                    net_tx_bytes_per_sec=$((tx_bytes_diff / time_interval))
                fi

                # Calculate packet rates safely
                local rx_packets_diff=$((current_rx_packets - prev_rx_packets))
                local tx_packets_diff=$((current_tx_packets - prev_tx_packets))

                if [ "$rx_packets_diff" -ge 0 ]; then
                    net_rx_packets_per_sec=$((rx_packets_diff / time_interval))
                fi
                if [ "$tx_packets_diff" -ge 0 ]; then
                    net_tx_packets_per_sec=$((tx_packets_diff / time_interval))
                fi
            fi
        fi
    fi

    # Save current stats for next run
    echo "$current_time $current_rx_bytes $current_tx_bytes $current_rx_packets $current_tx_packets" > "$NET_STATS_FILE" 2>/dev/null || true

    # Get interface speeds and utilization
    total_interface_speed=0
    active_interfaces=0
    interface_details=""

    if [ -r /sys/class/net ]; then
        for iface_path in /sys/class/net/*; do
            local iface=$(basename "$iface_path")

            # Skip loopback
            [[ "$iface" == "lo" ]] && continue

            # Check if interface is up
            if [ -f "$iface_path/operstate" ]; then
                local operstate=$(cat "$iface_path/operstate" 2>/dev/null || echo "down")
                if [ "$operstate" = "up" ]; then
                    active_interfaces=$((active_interfaces + 1))

                    # Get interface speed if available
                    if [ -f "$iface_path/speed" ]; then
                        local speed=$(cat "$iface_path/speed" 2>/dev/null || echo "0")
                        # Validate speed (some interfaces report -1 or negative values)
                        if [[ "$speed" =~ ^[0-9]+$ ]] && [ "$speed" -gt 0 ]; then
                            total_interface_speed=$((total_interface_speed + speed))
                            if [ -n "$interface_details" ]; then
                                interface_details="${interface_details},"
                            fi
                            interface_details="${interface_details}${iface}:${speed}Mbps"
                        fi
                    fi
                fi
            fi
        done
    fi

    # Calculate network utilization percentage (if we have interface speed and rates)
    net_rx_utilization=0
    net_tx_utilization=0
    net_total_utilization=0

    if [ "$total_interface_speed" -gt 0 ] && [ "$time_interval" -gt 0 ]; then
        # Convert interface speed from Mbps to bytes per second
        local total_speed_bytes_per_sec=$((total_interface_speed * 1000000 / 8))

        if [ "$total_speed_bytes_per_sec" -gt 0 ]; then
            # Calculate utilization percentages
            net_rx_utilization=$(awk -v rate="$net_rx_bytes_per_sec" -v speed="$total_speed_bytes_per_sec" 'BEGIN {
                if (speed > 0) {
                    result = (rate / speed) * 100
                    if (result >= 0 && result <= 100) {
                        printf "%.2f", result
                    } else {
                        print "0.00"
                    }
                } else {
                    print "0.00"
                }
            }' 2>/dev/null || echo "0.00")

            net_tx_utilization=$(awk -v rate="$net_tx_bytes_per_sec" -v speed="$total_speed_bytes_per_sec" 'BEGIN {
                if (speed > 0) {
                    result = (rate / speed) * 100
                    if (result >= 0 && result <= 100) {
                        printf "%.2f", result
                    } else {
                        print "0.00"
                    }
                } else {
                    print "0.00"
                }
            }' 2>/dev/null || echo "0.00")

            # Total utilization is the higher of RX or TX (since network can be asymmetric)
            net_total_utilization=$(awk -v rx="$net_rx_utilization" -v tx="$net_tx_utilization" 'BEGIN {
                result = (rx > tx) ? rx : tx
                printf "%.2f", result
            }' 2>/dev/null || echo "0.00")
        fi
    fi

    # Export all variables
    net_rx_bytes=$current_rx_bytes
    net_tx_bytes=$current_tx_bytes
    net_rx_packets=$current_rx_packets
    net_tx_packets=$current_tx_packets
    net_rx_errors=$current_rx_errors
    net_tx_errors=$current_tx_errors
    net_rx_dropped=$current_rx_dropped
    net_tx_dropped=$current_tx_dropped
}

# Call network stats collection
collect_network_stats

# Container information
container_hostname=$(hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || echo "unknown")
kernel_version=$(uname -r 2>/dev/null || echo "unknown")

# Container OS information
os_name="unknown"
os_version="unknown"
if [ -f /etc/os-release ]; then
    source /etc/os-release 2>/dev/null || true
    os_name="${NAME:-unknown}"
    os_version="${VERSION_ID:-unknown}"
elif [ -f /etc/redhat-release ]; then
    os_name=$(cat /etc/redhat-release 2>/dev/null || echo "unknown")
elif [ -f /etc/debian_version ]; then
    os_name="Debian"
    os_version=$(cat /etc/debian_version 2>/dev/null || echo "unknown")
fi

# Process count - safer method
process_count=0
if [ -r /proc ]; then
    process_count=$(find /proc -maxdepth 1 -type d -name '[0-9]*' 2>/dev/null | wc -l)
fi

# Open files count - Docker-compatible using /proc filesystem
open_files=0
if [ -r /proc ]; then
    # Count file descriptors from /proc/[pid]/fd/ for all processes
    # This works reliably in containers without needing lsof
    for pid_dir in /proc/[0-9]*; do
        if [ -d "$pid_dir/fd" ]; then
            fd_count=$(find "$pid_dir/fd" -type l 2>/dev/null | wc -l)
            open_files=$((open_files + fd_count))
        fi
    done
fi

# Fallback: if the above didn't work, try system-wide file-nr
if [ "$open_files" -eq 0 ] && [ -r /proc/sys/fs/file-nr ]; then
    # file-nr format: allocated_handles free_handles maximum
    # First field is the number of allocated file handles
    open_files=$(awk '{print $1}' /proc/sys/fs/file-nr 2>/dev/null || echo "0")
fi

# TCP connections count (container) - robust version
tcp_connections=0
if [ -r /proc/net/tcp ]; then
    tcp4_count=$(awk 'NR>1 {count++} END {print count+0}' /proc/net/tcp 2>/dev/null || echo "0")
    tcp6_count=$(awk 'NR>1 {count++} END {print count+0}' /proc/net/tcp6 2>/dev/null || echo "0")
    tcp_connections=$((tcp4_count + tcp6_count))
elif command -v ss >/dev/null 2>&1; then
    tcp_connections=$(ss -t state established 2>/dev/null | wc -l 2>/dev/null || echo "0")
elif command -v netstat >/dev/null 2>&1; then
    tcp_connections=$(netstat -t 2>/dev/null | awk 'NR>2 && /ESTABLISHED/ {count++} END {print count+0}')
fi

# System load per core - safer calculation
load_per_core="0.00"
if [ "$cpu_cores" -gt 0 ] && [[ "$load1" =~ ^[0-9]+\.?[0-9]*$ ]]; then
    load_per_core=$(awk -v load="$load1" -v cores="$cpu_cores" 'BEGIN {printf "%.2f", load / cores}' 2>/dev/null || echo "0.00")
fi

# Container IP Information
# Get container IP addresses (excluding loopback)
container_ips=""
primary_ip=""

if command -v hostname >/dev/null 2>&1; then
    container_ips=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.' | grep -v '^127\.' | tr '\n' ',' | sed 's/,$//' 2>/dev/null || echo "")
    primary_ip=$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i!~"^127\\.") {print $i; exit}}' 2>/dev/null || echo "")
fi

# Get external/public IP address with strict timeout and error handling
external_ip="unknown"
if command -v curl >/dev/null 2>&1; then
    for service in "https://ipv4.icanhazip.com" "https://api.ipify.org"; do
        external_ip=$(timeout 5 curl -s --connect-timeout 3 --max-time 5 "$service" 2>/dev/null | tr -d '\n\r' || echo "")
        if [[ "$external_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            break
        fi
    external_ip="unknown"
done
fi

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

# Escape all string variables
container_ips_escaped=$(escape_json "$container_ips")
primary_ip_escaped=$(escape_json "$primary_ip")
external_ip_escaped=$(escape_json "$external_ip")
interface_info_escaped=$(escape_json "$interface_info")
interface_details_escaped=$(escape_json "$interface_details")
container_name_escaped=$(escape_json "$container_name")
container_id_escaped=$(escape_json "$container_id")
container_hostname_escaped=$(escape_json "$container_hostname")
kernel_version_escaped=$(escape_json "$kernel_version")
os_name_escaped=$(escape_json "$os_name")
os_version_escaped=$(escape_json "$os_version")
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
  "instance_id": "$instance_id_escaped",
  "container_name": "$container_name_escaped",
  "container_id": "$container_id_escaped",
  "hostname": "$container_hostname_escaped",
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
  "container_ips": "$container_ips_escaped",
  "primary_ip": "$primary_ip_escaped",
  "external_ip": "$external_ip_escaped",
  "interface_info": "$interface_info_escaped",
  "interface_details": "$interface_details_escaped",
  "process_count": $process_count,
  "open_files": $open_files,
  "tcp_connections": $tcp_connections,
  "java_heap_used_kb": $java_heap_used,
  "java_heap_max_kb": $java_heap_max,
  "java_threads": $java_threads,
  "kernel_version": "$kernel_version_escaped",
  "os_name": "$os_name_escaped",
  "os_version": "$os_version_escaped",
  "timestamp": "$collection_timestamp"
}
EOF
)


# Random sending delay to prevent API load spikes
sending_delay=$((RANDOM % 41))  # 0-40 seconds
sleep $sending_delay

# Function to mark monitoring as stopped permanently
mark_as_stopped() {
    local reason="$1"
    echo "CRITICAL: $reason - Stopping monitoring permanently" >&2

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

    echo "Monitoring has been disabled permanently. To re-enable, edit $ENV_FILE and set SITECENTER_STOPPED=false" >&2
}

# Function to pause monitoring temporarily
mark_as_paused() {
    local reason="$1"
    echo "WARNING: $reason - Pausing monitoring for 1 day" >&2

    # Calculate pause until date (current date + 1 day)
    pause_until_date=$(date -d "tomorrow" +"%Y-%m-%d %H:%M:%S" 2>/dev/null || date -v+1d +"%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "")

    if [ -z "$pause_until_date" ]; then
        echo "ERROR: Cannot calculate pause date - continuing without pause" >&2
        return 1
    fi

    # Create environment file if it doesn't exist
    if [ ! -f "$ENV_FILE" ]; then
        touch "$ENV_FILE" 2>/dev/null || {
            echo "ERROR: Cannot create $ENV_FILE - monitoring will continue without pause" >&2
            return 1
        }
    fi

    # Check if SITECENTER_PAUSED_TILL variable exists in the file
    if grep -q "^SITECENTER_PAUSED_TILL=" "$ENV_FILE" 2>/dev/null; then
        # Variable exists - update it
        sed -i "s/^SITECENTER_PAUSED_TILL=.*/SITECENTER_PAUSED_TILL=\"$pause_until_date\"/" "$ENV_FILE" 2>/dev/null || {
            echo "ERROR: Cannot update $ENV_FILE" >&2
            return 1
        }
    else
        # Variable doesn't exist - append it
        echo "SITECENTER_PAUSED_TILL=\"$pause_until_date\"" >> "$ENV_FILE" 2>/dev/null || {
            echo "ERROR: Cannot write to $ENV_FILE" >&2
            return 1
        }
    fi

    echo "Monitoring paused until $pause_until_date. It will automatically resume after this time." >&2
}

# Send metrics via curl and capture response
if command -v curl >/dev/null 2>&1; then
    response=$(timeout 30 curl -s -w "\nHTTP_CODE:%{http_code}" -X POST \
  "https://mon.sitecenter.app/api/pub/v1/a/${ACCOUNT_CODE}/monitor/${MONITOR_CODE}/app-stats" \
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
        mark_as_paused "Monitor is not active"
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