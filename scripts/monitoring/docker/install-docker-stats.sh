#!/bin/bash

# install-docker-stats.sh
# https://raw.githubusercontent.com/sitecenter-org/linux/main/scripts/monitoring/docker/install-docker-stats.sh
# Simple script to add SiteCenter monitoring to any existing container
# Just copy this script and run it - no other changes needed!

# Usage:
# 1. Copy this script to your existing container
# 2. Set environment variables
# 3. Run: ./install-docker-stats.sh
# 4. Your app runs normally, monitoring happens in background

set -e

# Default configuration - override with environment variables
SITECENTER_ACCOUNT_CODE="${SITECENTER_ACCOUNT_CODE:-}"
SITECENTER_MONITOR_CODE="${SITECENTER_MONITOR_CODE:-}"
SITECENTER_SECRET_CODE="${SITECENTER_SECRET_CODE:-}"
SITECENTER_INTERVAL="${SITECENTER_INTERVAL:-*/5 * * * *}"
APP_NAME="${APP_NAME:-unknown}"

# Check if monitoring is configured
if [[ -z "$SITECENTER_ACCOUNT_CODE" || -z "$SITECENTER_MONITOR_CODE" || -z "$SITECENTER_SECRET_CODE" ]]; then
    echo "SiteCenter monitoring not configured - skipping"
    echo "Set SITECENTER_ACCOUNT_CODE, SITECENTER_MONITOR_CODE, SITECENTER_SECRET_CODE to enable"
    exit 0
fi

echo "Setting up SiteCenter monitoring for $APP_NAME..."

# Create monitoring script directory
mkdir -p /opt/sitecenter

# Download the monitoring script from GitHub
echo "Downloading SiteCenter monitoring script..."
if ! curl -sSL -o /opt/sitecenter/monitor.sh \
    "https://raw.githubusercontent.com/sitecenter-org/linux/main/scripts/monitoring/docker/sitecenter-docker-stats.sh"; then
    echo "ERROR: Failed to download monitoring script from GitHub"
    exit 1
fi

chmod +x /opt/sitecenter/monitor.sh

# Install required packages if not present
install_packages() {
    if command -v apk >/dev/null 2>&1; then
        # Alpine
        apk add --no-cache curl coreutils >/dev/null 2>&1 || true
    elif command -v apt-get >/dev/null 2>&1; then
        # Debian/Ubuntu
        apt-get update >/dev/null 2>&1 && apt-get install -y curl coreutils >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
        # RHEL/CentOS
        yum install -y curl coreutils >/dev/null 2>&1 || true
    fi
}

install_packages

# Create cron job
setup_cron() {
    # Create cron file
    mkdir -p /var/spool/cron/crontabs 2>/dev/null || mkdir -p /var/spool/cron 2>/dev/null || true

    # Try different cron locations
    local cron_file=""
    if [ -d "/var/spool/cron/crontabs" ]; then
        cron_file="/var/spool/cron/crontabs/$(whoami)"
    elif [ -d "/var/spool/cron" ]; then
        cron_file="/var/spool/cron/$(whoami)"
    else
        cron_file="/tmp/cron.tmp"
    fi

    # Add cron entry
    echo "$SITECENTER_INTERVAL /opt/sitecenter/monitor.sh \"$SITECENTER_ACCOUNT_CODE\" \"$SITECENTER_MONITOR_CODE\" \"$SITECENTER_SECRET_CODE\" >/dev/null 2>&1" > "$cron_file"

    # Try to install cron file
    if command -v crontab >/dev/null 2>&1; then
        crontab "$cron_file" 2>/dev/null || true
    fi

    # Start cron daemon if possible
    if command -v crond >/dev/null 2>&1; then
        crond 2>/dev/null || true
    elif command -v cron >/dev/null 2>&1; then
        cron 2>/dev/null || true
    fi
}

setup_cron

echo "SiteCenter monitoring configured!"
echo "- Account: $SITECENTER_ACCOUNT_CODE"
echo "- Monitor: $SITECENTER_MONITOR_CODE"
echo "- Interval: $SITECENTER_INTERVAL"
echo "- App: $APP_NAME"

# Test the monitoring script once
echo "Testing monitoring script..."
if /opt/sitecenter/monitor.sh "$SITECENTER_ACCOUNT_CODE" "$SITECENTER_MONITOR_CODE" "$SITECENTER_SECRET_CODE"; then
    echo "Monitoring test successful!"
else
    echo "Monitoring test failed - check your credentials"
fi

echo "Monitoring setup complete - your application can run normally now"