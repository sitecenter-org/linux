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
ENV_NAME="sitecenter-host-env.sh"
LOCAL_SCRIPT_PATH="$INSTALL_PATH/$SCRIPT_NAME"
LOCAL_ENV_PATH="$INSTALL_PATH/$ENV_NAME"

# Create environment file
echo "Creating environment file at $LOCAL_ENV_PATH..."
cat > "$LOCAL_ENV_PATH" << EOF
#!/bin/bash
# SiteCenter Host Monitoring Environment Variables
# Generated on $(date)

export SITECENTER_ACCOUNT="$ACCOUNT_CODE"
export SITECENTER_MONITOR="$MONITOR_CODE"
export SITECENTER_SECRET="$ALIVE_CODE"
EOF

# Set appropriate permissions (readable by owner only for security)
chmod 600 "$LOCAL_ENV_PATH"
echo "Environment file created with secure permissions."

# Download the monitoring script
echo "Downloading monitoring script to $LOCAL_SCRIPT_PATH..."

curl -sL -o "$LOCAL_SCRIPT_PATH" "https://raw.githubusercontent.com/sitecenter-org/linux/main/scripts/monitoring/server/$SCRIPT_NAME"

chmod +x "$LOCAL_SCRIPT_PATH"

echo "Script downloaded and made executable."

# Prepare the cron job line (without parameters - will use environment file)
CRON_LINE="* * * * * $LOCAL_SCRIPT_PATH"

# Remove any existing cron jobs for this script (with or without parameters)
TMP_CRON=$(mktemp)
crontab -l 2>/dev/null | grep -v "$LOCAL_SCRIPT_PATH" > "$TMP_CRON" || true

# Add the new cron job
echo "$CRON_LINE" >> "$TMP_CRON"

# Install the new crontab
crontab "$TMP_CRON"
rm "$TMP_CRON"

# Verify
if crontab -l | grep -qF "$LOCAL_SCRIPT_PATH"; then
  echo "Monitor installed and scheduled every minute via cron."
  echo "Environment variables stored securely in $LOCAL_ENV_PATH"
  echo "Cron job configured to run without command-line parameters."
else
  echo "Failed to update crontab."
  exit 1
fi
