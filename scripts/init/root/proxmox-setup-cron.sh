#!/bin/bash

set -e

echo "Creating cron directories for 1,5,15 minutes..."
mkdir -p /etc/cron.minute /etc/cron.five /etc/cron.fifteen
chmod 755 /etc/cron.minute /etc/cron.five /etc/cron.fifteen

echo "Ensuring run-parts entries exist in /etc/crontab..."

add_crontab_entry() {
  local schedule="$1"
  local folder="$2"
  local line="$schedule root run-parts $folder"

  # Add entry only if not present
  if ! grep -Fxq "$line" /etc/crontab; then
    echo "$line" >> /etc/crontab
    echo "Added: $line"
  else
    echo "Already exists: $line"
  fi
}

add_crontab_entry "* * * * *" "/etc/cron.minute"
add_crontab_entry "*/5 * * * *" "/etc/cron.five"
add_crontab_entry "*/15 * * * *" "/etc/cron.fifteen"

echo "Setup complete. Cron will now run scripts in those folders as scheduled."
