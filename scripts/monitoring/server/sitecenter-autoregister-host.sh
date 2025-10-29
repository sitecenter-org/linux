#!/bin/bash
# SiteCenter Auto-Registration and Host Monitoring Installer
# Automatically registers server and installs host monitoring
# Version: 2025-07-30
set -e

# Check if monitoring is already installed
if [ -f /usr/local/bin/sitecenter-host-env.sh ]; then
    echo "SiteCenter host monitoring is already installed."
    echo "Environment file found: /usr/local/bin/sitecenter-host-env.sh"
    echo ""
    echo "To reinstall, first remove the existing installation:"
    echo "1. Remove cron job: crontab -e (delete line with sitecenter-host-stats.sh)"
    echo "2. Remove files: sudo rm /usr/local/bin/sitecenter-host-*"
    echo "3. Run this script again"
    exit 0
fi

# Source environment variables
if [ -f /usr/local/bin/sitecenter-autoregister-env.sh ]; then
    . /usr/local/bin/sitecenter-autoregister-env.sh
    echo "Loaded configuration from /usr/local/bin/sitecenter-autoregister-env.sh"
fi

# Command line parameters override environment variables
ACCOUNT_CODE="${1:-$SITECENTER_ACCOUNT_CODE}"
WORKSPACE_ID="${2:-$SITECENTER_WORKSPACE_ID}"
SECRET="${3:-$SITECENTER_SECRET}"

if [[ -z "$ACCOUNT_CODE" || -z "$WORKSPACE_ID" || -z "$SECRET" ]]; then
  echo "Usage: $0 [ACCOUNT_CODE] [WORKSPACE_ID] [SECRET]"
  echo ""
  echo "Parameters can be provided via:"
  echo "1. Command line arguments (as shown above)"
  echo "2. Environment file: /usr/local/bin/sitecenter-autoregister-env.sh"
  echo "   containing: SITECENTER_ACCOUNT_CODE, SITECENTER_WORKSPACE_ID, SITECENTER_SECRET"
  echo ""
  echo "Command line parameters override environment variables if both are provided."
  echo ""
  echo "This script will:"
  echo "1. Gather server information (hostname, local IP, external IP)"
  echo "2. Register the server with SiteCenter backend"
  echo "3. Install host monitoring using the returned credentials"
  exit 1
fi

echo "SiteCenter Auto-Registration and Installation"
echo "============================================="
echo "Account Code: $ACCOUNT_CODE"
echo "Workspace ID: $WORKSPACE_ID"
echo ""

# Show current user context for troubleshooting
echo "Installing as user: $(whoami) (UID: $(id -u))"
if [ "$EUID" -eq 0 ]; then
    echo "Running with root privileges - cron jobs will run as root."
else
    echo "Running as regular user - cron jobs will run as $(whoami)."
fi
echo ""

# Gather server information
echo "Gathering server information..."

# Get hostname
HOSTNAME=$(hostname)
echo "Hostname: $HOSTNAME"

# Get local IP address (primary interface)
LOCAL_IP=$(ip route get 8.8.8.8 | awk -F"src " 'NR==1{split($2,a," ");print a[1]}' 2>/dev/null || echo "unknown")
if [[ "$LOCAL_IP" == "unknown" ]]; then
    # Fallback method
    LOCAL_IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "127.0.0.1")
fi
echo "Local IP: $LOCAL_IP"

# Get external IP address
echo "Detecting external IP..."
EXTERNAL_IP=$(curl -s --max-time 10 https://myip1.com/raw 2>/dev/null || \
              curl -s --max-time 10 ifconfig.me 2>/dev/null || \
              curl -s --max-time 10 icanhazip.com 2>/dev/null || \
              curl -s --max-time 10 ipecho.net/plain 2>/dev/null || \
              echo "unknown")
if [[ "$EXTERNAL_IP" == "unknown" ]]; then
    echo "Warning: Could not detect external IP address"
else
    echo "External IP: $EXTERNAL_IP"
fi
echo ""

# Prepare JSON payload
echo "Registering server with SiteCenter..."
JSON_PAYLOAD=$(cat <<EOF
{
  "secret": "$SECRET",
  "localIp": "$LOCAL_IP",
  "externalIp": "$EXTERNAL_IP",
  "hostname": "$HOSTNAME"
}
EOF
)

# Make API request
API_URL="https://mon.sitecenter.app/api/pub/v1/a/$ACCOUNT_CODE/ws/$WORKSPACE_ID/servers/autoRegisterNew"
echo "API Endpoint: $API_URL"

# Create temporary file for response
RESPONSE_FILE=$(mktemp)
HTTP_CODE=$(curl -w "%{http_code}" -s -o "$RESPONSE_FILE" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "$JSON_PAYLOAD" \
    "$API_URL")

# Check HTTP response code
if [[ "$HTTP_CODE" -ne 200 ]]; then
    echo "Error: API request failed with HTTP code $HTTP_CODE"
    echo "Response:"
    cat "$RESPONSE_FILE"
    rm "$RESPONSE_FILE"
    exit 1
fi

# Parse JSON response
echo "Server registration successful!"
echo "Response received from API:"
cat "$RESPONSE_FILE"
echo ""

# Extract values from JSON response using basic tools
# Note: This assumes the response is properly formatted JSON
RESPONSE_ACCOUNT_CODE=$(grep -o '"accountcode":"[^"]*"' "$RESPONSE_FILE" | cut -d'"' -f4)
RESPONSE_MONITOR_CODE=$(grep -o '"MonitorCode":"[^"]*"' "$RESPONSE_FILE" | cut -d'"' -f4)
RESPONSE_SECRET=$(grep -o '"secret":"[^"]*"' "$RESPONSE_FILE" | cut -d'"' -f4)

# Clean up response file
rm "$RESPONSE_FILE"

# Validate extracted values
if [[ -z "$RESPONSE_ACCOUNT_CODE" || -z "$RESPONSE_MONITOR_CODE" || -z "$RESPONSE_SECRET" ]]; then
    echo "Error: Could not extract required values from API response"
    echo "Expected fields: accountcode, MonitorCode, secret"
    exit 1
fi

echo "Extracted registration details:"
echo "Account Code: $RESPONSE_ACCOUNT_CODE"
echo "Monitor Code: $RESPONSE_MONITOR_CODE"
echo "Secret: [HIDDEN]"
echo ""

# Download and execute the install-host-stats script
echo "Downloading and executing install-host-stats script..."
INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/sitecenter-org/linux/main/scripts/monitoring/server/sitecenter-install-host-stats.sh"
TEMP_INSTALL_SCRIPT=$(mktemp)

if curl -sL -o "$TEMP_INSTALL_SCRIPT" "$INSTALL_SCRIPT_URL"; then
    chmod +x "$TEMP_INSTALL_SCRIPT"
    echo "Executing: $TEMP_INSTALL_SCRIPT $RESPONSE_ACCOUNT_CODE $RESPONSE_MONITOR_CODE [SECRET]"
    
    # Execute the install script with the returned credentials
    "$TEMP_INSTALL_SCRIPT" "$RESPONSE_ACCOUNT_CODE" "$RESPONSE_MONITOR_CODE" "$RESPONSE_SECRET"
    
    # Clean up
    rm "$TEMP_INSTALL_SCRIPT"
    
    echo ""
    echo "Installation completed successfully!"
    echo "Server '$HOSTNAME' has been registered and monitoring is now active."
else
    echo "Error: Could not download install-host-stats script from $INSTALL_SCRIPT_URL"
    echo "Manual installation required with these credentials:"
    echo "  Account Code: $RESPONSE_ACCOUNT_CODE"
    echo "  Monitor Code: $RESPONSE_MONITOR_CODE"
    echo "  Secret: $RESPONSE_SECRET"
    rm "$TEMP_INSTALL_SCRIPT"
    exit 1
fi