#!/bin/bash
# Usage: ./sitecenter-install-host-trace.sh ACCOUNT_CODE MONITOR_CODE SECRET TARGETS_CSV
# Version: 2026-06-26-API-DOMAIN-FAILOVER

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

echo "Downloading API domain helper from $HELPER_URL..."
download_script "$HELPER_URL" "$LOCAL_HELPER_PATH"
chmod 644 "$LOCAL_HELPER_PATH"

echo "Downloading monitoring script from $SCRIPT_URL..."
download_script "$SCRIPT_URL" "$LOCAL_SCRIPT_PATH"

chmod +x "$LOCAL_SCRIPT_PATH"

CRON_LINE="* * * * * $LOCAL_SCRIPT_PATH $LOCAL_ENV_PATH"

TMP_CRON=$(mktemp)
crontab -l 2>/dev/null | grep -v "$LOCAL_SCRIPT_PATH" > "$TMP_CRON" || true
echo "$CRON_LINE" >> "$TMP_CRON"
crontab "$TMP_CRON"
rm "$TMP_CRON"

if crontab -l | grep -qF "$LOCAL_SCRIPT_PATH"; then
  echo "Environment variables stored securely in $LOCAL_ENV_PATH"
  echo "This env file is dedicated to monitor $MONITOR_CODE."
  echo ""
  echo "To uninstall: crontab -e (remove the line with $LOCAL_SCRIPT_PATH)"
else
  echo "Failed to update crontab."
  exit 1
fi
