#!/bin/bash

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
curl -s -X POST "https://sitecenter.app/api/pub/v1/a/${ACCOUNT_CODE}/heartbeat/${MONITOR_CODE}/alive?aliveCode=${ALIVE_CODE}" -H "Content-Type: application/json" > /dev/null
EOF

chmod +x "$SCRIPT_PATH"

# Add cron job
(crontab -l 2>/dev/null; echo "* * * * * $SCRIPT_PATH") | crontab -

echo "Heartbeat installed and scheduled every minute via cron."
