#!/bin/bash

set -e

# SiteCenter monitoring setup
if [ -n "$SITECENTER_ACCOUNT" ] && [ -n "$SITECENTER_MONITOR" ] && [ -n "$SITECENTER_SECRET" ]; then
    echo "Setting up SiteCenter monitoring..."
    
    # Start cron daemon
    service cron start 2>/dev/null || crond -b 2>/dev/null || true
    
    # Setup monitoring job (preserves existing cron jobs)
    MONITORING_JOB="* * * * * /usr/local/bin/sitecenter-host-stats.sh $SITECENTER_ACCOUNT $SITECENTER_MONITOR $SITECENTER_SECRET"
    {
        crontab -l 2>/dev/null | grep -v "sitecenter-host-stats.sh" || true
        echo "$MONITORING_JOB"
    } | crontab -
    
    echo "Monitoring active (every minute)"
else
    echo "SiteCenter monitoring disabled (missing env vars)"
fi

# ============================================================================
# ADD LINE WITH YOUR APPLICATION STARTUP COMMAND
# ============================================================================
# For example:
# Spring Boot application:
# exec java -Xms32m -Xmx256m org.springframework.boot.loader.JarLauncher
# 
# Node.js app:
# exec node server.js
# 
# Python app:
# exec python app.py
#
# Nginx:
# exec nginx -g "daemon off;"
#
# Custom script:
# exec /app/start.sh