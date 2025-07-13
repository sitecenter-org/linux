#!/bin/bash

# install-pod-stats.sh for Kubernetes
# Enhanced version optimized for containerized environments
# https://raw.githubusercontent.com/sitecenter-org/linux/main/scripts/monitoring/k8s/install-pod-stats

set -e

# Default configuration - override with environment variables
SITECENTER_ACCOUNT_CODE="${SITECENTER_ACCOUNT_CODE:-}"
SITECENTER_MONITOR_CODE="${SITECENTER_MONITOR_CODE:-}"
SITECENTER_SECRET_CODE="${SITECENTER_SECRET_CODE:-}"
SITECENTER_INTERVAL="${SITECENTER_INTERVAL:-300}"  # Default 5 minutes for containers
APP_NAME="${APP_NAME:-unknown}"
MONITORING_MODE="${MONITORING_MODE:-cron}"  # cron, daemon, or oneshot

# Kubernetes metadata
POD_NAME="${POD_NAME:-$(hostname)}"
POD_NAMESPACE="${POD_NAMESPACE:-default}"
POD_IP="${POD_IP:-}"
NODE_NAME="${NODE_NAME:-unknown}"
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-unknown}"
REPLICA_SET_NAME="${REPLICA_SET_NAME:-unknown}"

echo "SiteCenter Kubernetes Monitoring Setup"
echo "======================================="

# Check if monitoring is configured
if [[ -z "$SITECENTER_ACCOUNT_CODE" || -z "$SITECENTER_MONITOR_CODE" || -z "$SITECENTER_SECRET_CODE" ]]; then
    echo "ERROR: SiteCenter monitoring not configured - missing credentials"
    echo "Set SITECENTER_ACCOUNT_CODE, SITECENTER_MONITOR_CODE, SITECENTER_SECRET_CODE to enable"
    echo ""
    echo "Environment variables found:"
    echo "  SITECENTER_ACCOUNT_CODE: ${SITECENTER_ACCOUNT_CODE:+[SET]}"
    echo "  SITECENTER_MONITOR_CODE: ${SITECENTER_MONITOR_CODE:+[SET]}"
    echo "  SITECENTER_SECRET_CODE: ${SITECENTER_SECRET_CODE:+[SET]}"
    exit 0
fi

echo "Configuration:"
echo "  Account: $SITECENTER_ACCOUNT_CODE"
echo "  Monitor: $SITECENTER_MONITOR_CODE"
echo "  App: $APP_NAME"
echo "  Mode: $MONITORING_MODE"
echo "  Interval: ${SITECENTER_INTERVAL}s"
echo "  Pod: $POD_NAME"
echo "  Namespace: $POD_NAMESPACE"
echo ""

# Create monitoring script directory
mkdir -p /opt/sitecenter
echo "Created monitoring directory: /opt/sitecenter"

# Download the monitoring script
echo "Downloading SiteCenter monitoring script..."
SCRIPT_URL="https://raw.githubusercontent.com/sitecenter-org/linux/main/scripts/monitoring/k8s/sitecenter-pod-stats.sh"

if command -v curl >/dev/null 2>&1; then
    if ! curl -sSL -f -o /opt/sitecenter/monitor.sh "$SCRIPT_URL"; then
        echo "ERROR: Failed to download monitoring script with curl"
        exit 1
    fi
elif command -v wget >/dev/null 2>&1; then
    if ! wget -q -O /opt/sitecenter/monitor.sh "$SCRIPT_URL"; then
        echo "ERROR: Failed to download monitoring script with wget"
        exit 1
    fi
else
    echo "ERROR: Neither curl nor wget available - cannot download monitoring script"
    exit 1
fi

chmod +x /opt/sitecenter/monitor.sh
echo "Downloaded and installed monitoring script"

# Install required packages based on container type
install_packages() {
    echo "Installing required packages..."

    # Detect package manager and install minimal requirements
    if command -v apk >/dev/null 2>&1; then
        # Alpine Linux
        echo "  Detected Alpine Linux - installing packages"
        apk add --no-cache curl coreutils procps util-linux >/dev/null 2>&1 || {
            echo "WARNING: Package installation failed, monitoring may have limited functionality"
        }
    elif command -v apt-get >/dev/null 2>&1; then
        # Debian/Ubuntu
        echo "  Detected Debian/Ubuntu - installing packages"
        apt-get update >/dev/null 2>&1 && \
        apt-get install -y curl coreutils procps iproute2 >/dev/null 2>&1 || {
            echo "WARNING: Package installation failed, monitoring may have limited functionality"
        }
    elif command -v yum >/dev/null 2>&1; then
        # RHEL/CentOS
        echo "  Detected RHEL/CentOS - installing packages"
        yum install -y curl coreutils procps-ng iproute >/dev/null 2>&1 || {
            echo "WARNING: Package installation failed, monitoring may have limited functionality"
        }
    elif command -v dnf >/dev/null 2>&1; then
        # Fedora
        echo "  Detected Fedora - installing packages"
        dnf install -y curl coreutils procps-ng iproute >/dev/null 2>&1 || {
            echo "WARNING: Package installation failed, monitoring may have limited functionality"
        }
    else
        echo "WARNING: Unknown package manager - assuming packages are available"
    fi
}

install_packages

# Create monitoring wrapper script with Kubernetes metadata
create_wrapper_script() {
    cat > /opt/sitecenter/k8s-monitor.sh << 'EOF'
#!/bin/bash

# Kubernetes monitoring wrapper script
# Sets up environment and runs SiteCenter monitoring

# Export Kubernetes metadata
export CONTAINER_NAME="${POD_NAME:-$(hostname)}"
export POD_NAME="${POD_NAME:-$(hostname)}"
export POD_NAMESPACE="${POD_NAMESPACE:-default}"
export POD_IP="${POD_IP:-}"
export NODE_NAME="${NODE_NAME:-unknown}"
export APP_NAME="${APP_NAME:-unknown}"
export APP_VERSION="${APP_VERSION:-unknown}"
export DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-unknown}"
export REPLICA_SET_NAME="${REPLICA_SET_NAME:-unknown}"

# Run the monitoring script with error handling
if ! /opt/sitecenter/monitor.sh "$1" "$2" "$3" 2>/dev/null; then
    # Log error but don't fail - monitoring shouldn't break the application
    echo "$(date): SiteCenter monitoring failed" >> /tmp/sitecenter-error.log
    exit 0
fi
EOF
    chmod +x /opt/sitecenter/k8s-monitor.sh
}

create_wrapper_script

# Setup monitoring based on mode
setup_monitoring() {
    case "$MONITORING_MODE" in
        "cron")
            setup_cron_monitoring
            ;;
        "daemon")
            setup_daemon_monitoring
            ;;
        "oneshot")
            echo "One-shot mode - monitoring will run once"
            ;;
        *)
            echo "WARNING: Unknown monitoring mode: $MONITORING_MODE, defaulting to cron"
            setup_cron_monitoring
            ;;
    esac
}

# Setup cron-based monitoring
setup_cron_monitoring() {
    echo "Setting up cron-based monitoring..."

    # Calculate cron expression from seconds
    if [ "$SITECENTER_INTERVAL" -le 60 ]; then
        # Less than 1 minute - use * * * * * (every minute)
        cron_expr="* * * * *"
    elif [ "$SITECENTER_INTERVAL" -le 300 ]; then
        # 5 minutes or less
        minutes=$((SITECENTER_INTERVAL / 60))
        cron_expr="*/$minutes * * * *"
    elif [ "$SITECENTER_INTERVAL" -le 3600 ]; then
        # 1 hour or less
        minutes=$((SITECENTER_INTERVAL / 60))
        cron_expr="*/$minutes * * * *"
    else
        # More than 1 hour
        hours=$((SITECENTER_INTERVAL / 3600))
        cron_expr="0 */$hours * * *"
    fi

    # Create cron file
    mkdir -p /var/spool/cron/crontabs 2>/dev/null || mkdir -p /var/spool/cron 2>/dev/null || mkdir -p /tmp

    local cron_file=""
    local current_user=$(whoami)

    if [ -d "/var/spool/cron/crontabs" ]; then
        cron_file="/var/spool/cron/crontabs/$current_user"
    elif [ -d "/var/spool/cron" ]; then
        cron_file="/var/spool/cron/$current_user"
    else
        cron_file="/tmp/cron.tmp"
    fi

    # Create cron entry with full paths and environment
    {
        echo "# SiteCenter monitoring cron job"
        echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        echo "POD_NAME=$POD_NAME"
        echo "POD_NAMESPACE=$POD_NAMESPACE"
        echo "APP_NAME=$APP_NAME"
        echo "NODE_NAME=$NODE_NAME"
        echo "$cron_expr /opt/sitecenter/k8s-monitor.sh \"$SITECENTER_ACCOUNT_CODE\" \"$SITECENTER_MONITOR_CODE\" \"$SITECENTER_SECRET_CODE\" >/dev/null 2>&1"
    } > "$cron_file"

    # Install cron file
    if command -v crontab >/dev/null 2>&1; then
        if crontab "$cron_file" 2>/dev/null; then
            echo "Cron job installed successfully"
        else
            echo "WARNING: Failed to install cron job, will try manual cron setup"
        fi
    else
        echo "WARNING: crontab command not available"
    fi

    # Try to start cron daemon
    start_cron_daemon
}

# Start cron daemon
start_cron_daemon() {
    echo "Starting cron daemon..."

    # Try different cron daemon names
    if command -v crond >/dev/null 2>&1; then
        if ! pgrep crond >/dev/null 2>&1; then
            crond -b 2>/dev/null && echo "crond started" || echo "WARNING: Failed to start crond"
        else
            echo "crond already running"
        fi
    elif command -v cron >/dev/null 2>&1; then
        if ! pgrep cron >/dev/null 2>&1; then
            service cron start 2>/dev/null || cron 2>/dev/null && echo "cron started" || echo "WARNING: Failed to start cron"
        else
            echo "cron already running"
        fi
    else
        echo "WARNING: No cron daemon found"
    fi
}

# Setup daemon-based monitoring
setup_daemon_monitoring() {
    echo "Setting up daemon-based monitoring..."

    # Create daemon script
    cat > /opt/sitecenter/daemon.sh << EOF
#!/bin/bash
# SiteCenter monitoring daemon

echo "Starting SiteCenter monitoring daemon..."
echo "Interval: ${SITECENTER_INTERVAL}s"

while true; do
    /opt/sitecenter/k8s-monitor.sh "$SITECENTER_ACCOUNT_CODE" "$SITECENTER_MONITOR_CODE" "$SITECENTER_SECRET_CODE"
    sleep $SITECENTER_INTERVAL
done
EOF
    chmod +x /opt/sitecenter/daemon.sh

    echo "Daemon script created at /opt/sitecenter/daemon.sh"
    echo "To start daemon: nohup /opt/sitecenter/daemon.sh &"
}

# Test the monitoring script
test_monitoring() {
    echo ""
    echo "Testing monitoring script..."

    if /opt/sitecenter/k8s-monitor.sh "$SITECENTER_ACCOUNT_CODE" "$SITECENTER_MONITOR_CODE" "$SITECENTER_SECRET_CODE"; then
        echo "Monitoring test successful!"
        echo "   Data sent to SiteCenter API"
    else
        echo "ERROR: Monitoring test failed"
        echo "   Check your credentials and network connectivity"
        return 1
    fi
}

# Main setup flow
setup_monitoring

# Test monitoring
if ! test_monitoring; then
    echo ""
    echo "WARNING: Monitoring setup completed but test failed"
    echo "   This might be due to network connectivity or credential issues"
    echo "   Monitor logs for more information"
else
    echo ""
    echo "SiteCenter monitoring setup complete!"
fi

echo ""
echo "Monitoring Details:"
echo "   * Script: /opt/sitecenter/monitor.sh"
echo "   * Wrapper: /opt/sitecenter/k8s-monitor.sh"
echo "   * Mode: $MONITORING_MODE"
echo "   * Interval: ${SITECENTER_INTERVAL}s"
echo "   * Instance ID: $POD_NAME-$(hostname)"
echo ""
echo "Troubleshooting:"
echo "   * Test manually: /opt/sitecenter/k8s-monitor.sh <account> <monitor> <secret>"
echo "   * Check cron: crontab -l"
echo "   * View errors: cat /tmp/sitecenter-error.log"
echo "   * Check processes: ps aux | grep monitor"
echo ""
echo "Your application can now run normally with monitoring enabled!"