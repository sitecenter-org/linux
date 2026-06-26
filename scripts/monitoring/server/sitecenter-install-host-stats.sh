#!/bin/bash
# SiteCenter Host Monitoring Installer
# Note: Run with the same user privileges that will execute the cron job
# (typically 'sudo' for system-wide monitoring)
# Version: 2026-06-26-API-DOMAIN-FAILOVER
set -e

ACCOUNT_CODE="$1"
MONITOR_CODE="$2"
SECRET="$3"

if [[ -z "$ACCOUNT_CODE" || -z "$MONITOR_CODE" || -z "$SECRET" ]]; then
  echo "Usage: $0 ACCOUNT_CODE MONITOR_CODE SECRET"
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
HELPER_NAME="sitecenter-api-domains.sh"
ENV_NAME="sc-${MONITOR_CODE}.env"
LOCAL_SCRIPT_PATH="$INSTALL_PATH/$SCRIPT_NAME"
LOCAL_HELPER_PATH="$INSTALL_PATH/$HELPER_NAME"
LOCAL_ENV_PATH="$INSTALL_PATH/$ENV_NAME"
SCRIPT_URL="https://raw.githubusercontent.com/sitecenter-org/linux/main/scripts/monitoring/server/$SCRIPT_NAME"
HELPER_URL="https://raw.githubusercontent.com/sitecenter-org/linux/main/scripts/monitoring/server/$HELPER_NAME"

download_script() {
    local url="$1"
    local dest="$2"
    local tmp_file
    tmp_file=$(mktemp)

    if ! curl -fsSL -o "$tmp_file" "$url"; then
        rm -f "$tmp_file"
        echo "Failed to download $url" >&2
        return 1
    fi

    if [ ! -s "$tmp_file" ] || ! head -n 1 "$tmp_file" | grep -q '^#!'; then
        rm -f "$tmp_file"
        echo "Downloaded content from $url is not a valid shell script" >&2
        return 1
    fi

    mv "$tmp_file" "$dest"
}

# Create environment file
echo "Creating environment file at $LOCAL_ENV_PATH..."
cat > "$LOCAL_ENV_PATH" << EOF
#!/bin/bash
# SiteCenter Host Monitoring Environment Variables
# Generated on $(date)

export SITECENTER_ACCOUNT="$ACCOUNT_CODE"
export SITECENTER_MONITOR="$MONITOR_CODE"
export SITECENTER_SECRET="$SECRET"
EOF

# Set appropriate permissions and ownership
# Make readable by owner and group (in case cron runs as different user)
chmod 640 "$LOCAL_ENV_PATH"

# If running as root, ensure the file is owned by root
if [ "$EUID" -eq 0 ]; then
    chown root:root "$LOCAL_ENV_PATH"
fi

# Download the monitoring script and API domain helper
echo "Downloading API domain helper from $HELPER_URL..."
download_script "$HELPER_URL" "$LOCAL_HELPER_PATH"
chmod 644 "$LOCAL_HELPER_PATH"

echo "Downloading monitoring script from $SCRIPT_URL..."
download_script "$SCRIPT_URL" "$LOCAL_SCRIPT_PATH"

chmod +x "$LOCAL_SCRIPT_PATH"

# Prepare the cron job line with explicit environment file
CRON_LINE="* * * * * $LOCAL_SCRIPT_PATH $LOCAL_ENV_PATH"

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
  echo "Environment variables stored securely in $LOCAL_ENV_PATH"
  echo "This env file is dedicated to monitor $MONITOR_CODE."
  echo ""
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
