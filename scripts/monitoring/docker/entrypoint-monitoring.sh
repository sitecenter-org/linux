#!/bin/bash

set -e

# SiteCenter monitoring setup
if [ -n "$SITECENTER_ACCOUNT" ] && [ -n "$SITECENTER_MONITOR" ] && [ -n "$SITECENTER_SECRET" ]; then
    echo "Setting up SiteCenter monitoring..."

    # Start cron daemon
    service cron start 2>/dev/null || crond -b 2>/dev/null || true

    # Setup monitoring job (preserves existing cron jobs)
    MONITORING_JOB="* * * * * /usr/local/bin/sitecenter-docker-stats.sh $SITECENTER_ACCOUNT $SITECENTER_MONITOR $SITECENTER_SECRET"
    {
        crontab -l 2>/dev/null | grep -v "sitecenter-docker-stats.sh" || true
        echo "$MONITORING_JOB"
    } | crontab -

    echo "Monitoring active (every minute)"
else
    echo "SiteCenter monitoring disabled (missing env vars)"
fi

# ============================================================================
# REPLACE THIS LINE WITH YOUR APPLICATION STARTUP COMMAND
# ============================================================================
exec /entrypoint.sh
