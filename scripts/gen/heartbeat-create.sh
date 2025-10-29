#!/bin/bash

set -e

ACCOUNT_CODE="$1"
MONITOR_CODE="$2"
ALIVE_CODE="$3"

if [[ -z "$ACCOUNT_CODE" || -z "$MONITOR_CODE" || -z "$ALIVE_CODE" ]]; then
  echo "Usage: $0 ACCOUNT_CODE MONITOR_CODE ALIVE_CODE"
  exit 1
fi

SCRIPT_PATH="./sitecenter-heartbeat.sh"

# Create the heartbeat script with editable values
cat <<EOF > "$SCRIPT_PATH"
#!/bin/bash

# Edit these values if needed
ACCOUNT_CODE="${ACCOUNT_CODE}"
MONITOR_CODE="${MONITOR_CODE}"
ALIVE_CODE="${ALIVE_CODE}"

curl -s -X POST "https://mon.sitecenter.app/api/pub/v1/a/\${ACCOUNT_CODE}/heartbeat/\${MONITOR_CODE}/alive?aliveCode=\${ALIVE_CODE}" -H "Content-Type: application/json" > /dev/null
EOF

chmod +x "$SCRIPT_PATH"

echo "Heartbeat script created at $SCRIPT_PATH"
