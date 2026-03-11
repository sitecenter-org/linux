#!/bin/bash
# Usage: ./sitecenter-install-host-trace.sh ACCOUNT_CODE MONITOR_CODE SECRET TARGETS_CSV
# Version: 2026-03-11

set -e

ACCOUNT_CODE="$1"
MONITOR_CODE="$2"
SECRET="$3"
TARGETS_CSV="$4"

if [[ -z "$ACCOUNT_CODE" || -z "$MONITOR_CODE" || -z "$SECRET" ]]; then
  echo "Usage: $0 ACCOUNT_CODE MONITOR_CODE SECRET TARGETS_CSV"
  exit 1
fi

echo "Installing as user: $(whoami) (UID: $(id -u))"
if [ "$EUID" -eq 0 ]; then
    echo "Running with root privileges - cron jobs will run as root."
else
    echo "Running as regular user - cron jobs will run as $(whoami)."
fi

INSTALL_PATH="/usr/local/bin"
SCRIPT_NAME="sitecenter-host-trace.sh"
ENV_NAME="sitecenter-host-trace-env.sh"
LOCAL_SCRIPT_PATH="$INSTALL_PATH/$SCRIPT_NAME"
LOCAL_ENV_PATH="$INSTALL_PATH/$ENV_NAME"

echo "Creating environment file at $LOCAL_ENV_PATH..."
cat > "$LOCAL_ENV_PATH" << EOF
#!/bin/bash
# SiteCenter Host Trace Environment Variables
# Generated on $(date)

export SITECENTER_ACCOUNT="$ACCOUNT_CODE"
export SITECENTER_MONITOR="$MONITOR_CODE"
export SITECENTER_SECRET="$SECRET"
export SITECENTER_TRACE_TARGETS="$TARGETS_CSV"
EOF

chmod 640 "$LOCAL_ENV_PATH"

if [ "$EUID" -eq 0 ]; then
    chown root:root "$LOCAL_ENV_PATH"
fi

echo "Downloading monitoring script to $LOCAL_SCRIPT_PATH..."
curl -sL -o "$LOCAL_SCRIPT_PATH" "https://raw.githubusercontent.com/sitecenter-org/linux/main/scripts/monitoring/server/$SCRIPT_NAME"

chmod +x "$LOCAL_SCRIPT_PATH"

CRON_LINE="* * * * * $LOCAL_SCRIPT_PATH"

TMP_CRON=$(mktemp)
crontab -l 2>/dev/null | grep -v "$LOCAL_SCRIPT_PATH" > "$TMP_CRON" || true
echo "$CRON_LINE" >> "$TMP_CRON"
crontab "$TMP_CRON"
rm "$TMP_CRON"

if crontab -l | grep -qF "$LOCAL_SCRIPT_PATH"; then
  echo "Environment variables stored securely in $LOCAL_ENV_PATH"
  echo ""
  echo "To uninstall: crontab -e (remove the line with $LOCAL_SCRIPT_PATH)"
else
  echo "Failed to update crontab."
  exit 1
fi
