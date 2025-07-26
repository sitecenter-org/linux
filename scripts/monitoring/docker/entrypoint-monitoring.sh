#!/bin/bash

set -e

# SiteCenter monitoring setup
if [ -n "$SITECENTER_ACCOUNT" ] && [ -n "$SITECENTER_MONITOR" ] && [ -n "$SITECENTER_SECRET" ]; then
    echo "Setting up SiteCenter monitoring..."

    # Start cron daemon
    service cron start 2>/dev/null || crond -b 2>/dev/null || true

# Create environment file for cron with current Docker environment variables
    cat > /usr/local/bin/sitecenter-env.sh << EOF
#!/bin/bash
export NODE_NAME="${NODE_NAME:-unknown}"
export APP_NAME="${APP_NAME:-unknown}"
export APP_VERSION="${APP_VERSION:-unknown}"
export POD_NAME="${POD_NAME:-unknown}"
export POD_NAMESPACE="${POD_NAMESPACE:-unknown}"
export POD_IP="${POD_IP:-unknown}"
export DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-unknown}"
export REPLICA_SET_NAME="${REPLICA_SET_NAME:-unknown}"
export CONTAINER_NAME="${CONTAINER_NAME:-unknown}"
export CONTAINER_ID="${CONTAINER_ID:-unknown}"
export MEMORY_LIMIT="${MEMORY_LIMIT:-}"
export SITECENTER_ACCOUNT="${SITECENTER_ACCOUNT:-}"
export SITECENTER_MONITOR="${SITECENTER_MONITOR:-}"
export SITECENTER_SECRET="${SITECENTER_SECRET:-}"
export DOCKER_HOST_NAME="${DOCKER_HOST_NAME:-unknown}"
EOF
    chmod +x /usr/local/bin/sitecenter-env.sh

    # Setup monitoring job (preserves existing cron jobs)
    MONITORING_JOB="* * * * * /usr/local/bin/sitecenter-docker-stats.sh"
    {
        crontab -l 2>/dev/null | grep -v "sitecenter-docker-stats.sh" || true
        echo "$MONITORING_JOB"
    } | crontab -

    echo "Monitoring active (every minute)"
    echo "NODE_NAME:$NODE_NAME"
    echo "POD_NAME:$POD_NAME"
    echo "SITECENTER_ACCOUNT:$SITECENTER_ACCOUNT"
    echo "SITECENTER_MONITOR:$SITECENTER_MONITOR"
else
    echo "SiteCenter monitoring disabled (missing env vars)"
fi

# ============================================================================
# REPLACE THIS LINE WITH YOUR APPLICATION STARTUP COMMAND
# ============================================================================
exec /entrypoint.sh
