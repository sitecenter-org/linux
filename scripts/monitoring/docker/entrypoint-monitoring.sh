#!/bin/bash

set -e

# SiteCenter monitoring setup
if [ -n "$SITECENTER_ACCOUNT" ] && [ -n "$SITECENTER_MONITOR" ] && [ -n "$SITECENTER_SECRET" ]; then
    echo "Setting up SiteCenter monitoring..."

    # Disable cron mail to prevent exim4 zombie processes
    export MAILTO=""
    echo "MAILTO=" >> /etc/crontab
    echo "MAILTO=" > /etc/cron.d/disable-mail

    # Start cron daemon
    service cron start 2>/dev/null || crond -b 2>/dev/null || true

# Create environment file for cron with current Docker environment variables
    cat > /usr/local/bin/sitecenter-docker-env.sh << EOF
#!/bin/bash
export NODE_NAME="${NODE_NAME:-}"
export APP_NAME="${APP_NAME:-}"
export APP_VERSION="${APP_VERSION:-}"
export POD_NAME="${POD_NAME:-}"
export POD_NAMESPACE="${POD_NAMESPACE:-}"
export POD_IP="${POD_IP:-}"
export DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-}"
export REPLICA_SET_NAME="${REPLICA_SET_NAME:-}"
export CONTAINER_NAME="${CONTAINER_NAME:-}"
export CONTAINER_ID="${CONTAINER_ID:-}"
export MEMORY_LIMIT="${MEMORY_LIMIT:-}"
export SITECENTER_ACCOUNT="${SITECENTER_ACCOUNT:-}"
export SITECENTER_MONITOR="${SITECENTER_MONITOR:-}"
export SITECENTER_SECRET="${SITECENTER_SECRET:-}"
export DOCKER_HOST_NAME="${DOCKER_HOST_NAME:-}"
EOF
    chmod +x /usr/local/bin/sitecenter-docker-env.sh

    # Setup monitoring job (preserves existing cron jobs)
    # Add MAILTO='' to prevent mail from this specific job
    {
        crontab -l 2>/dev/null | grep -v "sitecenter-docker-stats.sh" || true
        echo "MAILTO="
        echo "* * * * * /usr/local/bin/sitecenter-docker-stats.sh"
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
