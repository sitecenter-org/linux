#!/bin/bash
# Version: 2025-07-26-15-22
set -e

ACCOUNT_CODE="$1"
MONITOR_CODE="$2"
ALIVE_CODE="$3"

if [[ -z "$ACCOUNT_CODE" || -z "$MONITOR_CODE" || -z "$ALIVE_CODE" ]]; then
  echo "Usage: $0 ACCOUNT_CODE MONITOR_CODE ALIVE_CODE"
  exit 1
fi

SCRIPT_PATH="/usr/local/bin/sitecenter-heartbeat.sh"

# Create the heartbeat script
cat <<EOF > "$SCRIPT_PATH"
#!/bin/bash
# Random sending delay to prevent API load spikes
sending_delay=$((RANDOM % 21))  # 0-20 seconds
#echo "Delaying ${sending_delay} seconds to distribute API calls..." >&2
sleep $sending_delay

curl -s -X POST "https://mon.sitecenter.app/api/pub/v1/a/${ACCOUNT_CODE}/heartbeat/${MONITOR_CODE}/alive?aliveCode=${ALIVE_CODE}" -H "Content-Type: application/json" > /dev/null
EOF

chmod +x "$SCRIPT_PATH"

# Add cron job
#(crontab -l 2>/dev/null; echo "* * * * * $SCRIPT_PATH") | crontab -

CRON_LINE="* * * * * $SCRIPT_PATH"

# Fetch current crontab, if any
TMP_CRON=$(mktemp)
crontab -l 2>/dev/null | grep -vF "$CRON_LINE" > "$TMP_CRON" || true

# Add the new line
echo "$CRON_LINE" >> "$TMP_CRON"

# Install the new crontab
crontab "$TMP_CRON"
rm "$TMP_CRON"

if crontab -l | grep -q "$SCRIPT_PATH"; then
  echo "Crontab updated successfully."
else
  echo "Failed to update crontab."
fi

echo "Heartbeat installed and scheduled every minute via cron."
