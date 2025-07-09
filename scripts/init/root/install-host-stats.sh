#!/bin/bash

set -e

ACCOUNT_CODE="$1"
MONITOR_CODE="$2"
ALIVE_CODE="$3"

if [[ -z "$ACCOUNT_CODE" || -z "$MONITOR_CODE" || -z "$ALIVE_CODE" ]]; then
  echo "Usage: $0 ACCOUNT_CODE MONITOR_CODE ALIVE_CODE"
  exit 1
fi

# Define paths
INSTALL_PATH="/usr/local/bin"
SCRIPT_NAME="sitecenter-host-stats.sh"
LOCAL_SCRIPT_PATH="$INSTALL_PATH/$SCRIPT_NAME"

# Download the monitoring script
echo "Downloading monitoring script to $LOCAL_SCRIPT_PATH..."

curl -sL -o "$LOCAL_SCRIPT_PATH" "https://raw.githubusercontent.com/sitecenter-org/linux/main/scripts/monitoring/$SCRIPT_NAME"

chmod +x "$LOCAL_SCRIPT_PATH"

echo "Script downloaded and made executable."

# Prepare the cron job line
CRON_LINE="* * * * * $LOCAL_SCRIPT_PATH $ACCOUNT_CODE $MONITOR_CODE $ALIVE_CODE"

# Remove any existing identical line first
TMP_CRON=$(mktemp)
crontab -l 2>/dev/null | grep -vF "$CRON_LINE" > "$TMP_CRON" || true

# Add the new cron job
echo "$CRON_LINE" >> "$TMP_CRON"

# Install the new crontab
crontab "$TMP_CRON"
rm "$TMP_CRON"

# Verify
if crontab -l | grep -qF "$LOCAL_SCRIPT_PATH"; then
  echo "Monitor installed and scheduled every minute via cron."
else
  echo "Failed to update crontab."
  exit 1
fi
