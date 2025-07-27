#!/bin/bash
# SiteCenter Host Monitoring Installer
# Note: Run with the same user privileges that will execute the cron job
# (typically 'sudo' for system-wide monitoring)
# Version: 2025-07-26-16-00
set -e

ACCOUNT_CODE="$1"
MONITOR_CODE="$2"
ALIVE_CODE="$3"

if [[ -z "$ACCOUNT_CODE" || -z "$MONITOR_CODE" || -z "$ALIVE_CODE" ]]; then
  echo "Usage: $0 ACCOUNT_CODE MONITOR_CODE ALIVE_CODE"
  exit 1
fi

# Show current user context for troubleshooting
echo "Installing as user: $(whoami) (UID: $(id -u))"
if [ "$EUID" -eq 0 ]; then
    echo "Running with root privileges - cron jobs will run as root."
else
    echo "Running as regular user - cron jobs will run as $(whoami)."
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

# Set appropriate permissions and ownership
# Make readable by owner and group (in case cron runs as different user)
chmod 640 "$LOCAL_ENV_PATH"

# If running as root, ensure the file is owned by root
if [ "$EUID" -eq 0 ]; then
    chown root:root "$LOCAL_ENV_PATH"
fi

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
  echo ""
  echo "To update credentials: edit $LOCAL_ENV_PATH"
  echo "To uninstall: crontab -e (remove the line with $LOCAL_SCRIPT_PATH)"

  # Test if the monitoring script can access the environment file
  echo "Testing environment file access..."
  if [ -r "$LOCAL_ENV_PATH" ] && source "$LOCAL_ENV_PATH" 2>/dev/null; then
    echo "- Environment file test passed."
  else
    echo "! Warning: Environment file may not be accessible to cron."
    echo "  If monitoring fails, run this installer with the same user privileges as cron."
    echo "  Typically, run with 'sudo' if cron jobs run as root."
  fi
else
  echo "Failed to update crontab."
  exit 1
fi
