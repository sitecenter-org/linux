#!/bin/bash
# Usage:
# ./sitecenter-host-mtr.sh [/path/to/env-file.env] [ACCOUNT_CODE MONITOR_CODE SECRET_CODE TARGETS_CSV]
# Version: 2026-03-11

set -u

ENV_FILE=""

if [[ $# -gt 0 && ( "$1" == *.env || "$1" == */* ) ]]; then
    ENV_FILE="$1"
    shift
elif [ -f "/usr/local/bin/sitecenter-host-mtr-env.sh" ]; then
    ENV_FILE="/usr/local/bin/sitecenter-host-mtr-env.sh"
fi

if [[ -n "$ENV_FILE" && ! -r "$ENV_FILE" ]]; then
    echo "Environment file is not readable: $ENV_FILE" >&2
    exit 1
fi

if [[ -n "$ENV_FILE" && -f "$ENV_FILE" ]]; then
    source "$ENV_FILE" 2>/dev/null || true
fi

ACCOUNT_CODE="${1:-${SITECENTER_ACCOUNT:-}}"
MONITOR_CODE="${2:-${SITECENTER_MONITOR:-}}"
SECRET_CODE="${3:-${SITECENTER_SECRET:-}}"
TARGETS_RAW="${4:-${SITECENTER_TRACE_TARGETS:-}}"

if [[ -z "$ACCOUNT_CODE" || -z "$MONITOR_CODE" || -z "$SECRET_CODE" ]]; then
  echo "Usage: $0 [/path/to/env-file.env] [ACCOUNT_CODE MONITOR_CODE SECRET_CODE TARGETS_CSV]" >&2
  exit 1
fi

if [[ -z "$TARGETS_RAW" ]]; then
  echo "No MTR targets configured. Exiting..." >&2
  exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required" >&2
  exit 1
fi

SOURCE_HOST="$(hostname 2>/dev/null || echo unknown)"
API_URL="https://mon.sitecenter.app/api/pub/v1/a/${ACCOUNT_CODE}/monitor/${MONITOR_CODE}/host-trace"
MTR_ARGS="-rwzbc10"

json_escape() {
  printf '%s' "${1:-}" | sed ':a;N;$!ba;s/\\/\\\\/g;s/"/\\"/g;s/\r/\\r/g;s/\n/\\n/g;s/\t/\\t/g'
}

split_targets() {
  printf '%s' "$TARGETS_RAW" | tr ', ' '\n\n' | sed '/^$/d'
}

run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "$@"
  else
    shift
    "$@"
  fi
}

extract_summary() {
  printf '%s\n' "$1" | awk '
    /^Start:/ { next }
    /^HOST:/ { next }
    /^[[:space:]]*[0-9]+\./ {
      line=$0
      sub(/^[[:space:]]+/, "", line)
      last=line
    }
    END {
      if (last != "") {
        print last
      }
    }
  '
}

send_trace_payload() {
  local target_host="$1"
  local ok="$2"
  local command_str="$3"
  local exit_code="$4"
  local summary="$5"
  local raw_output="$6"
  local error_str="$7"
  local timestamp
  local payload
  local response
  local http_code
  local response_body

  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  payload=$(cat <<EOF
{"timestamp":"$(json_escape "$timestamp")","source_host":"$(json_escape "$SOURCE_HOST")","target_host":"$(json_escape "$target_host")","ok":$ok,"trace_type":"mtr","command":"$(json_escape "$command_str")","exit_code":$exit_code,"summary":"$(json_escape "$summary")","raw_output":"$(json_escape "$raw_output")","error":"$(json_escape "$error_str")"}
EOF
)

  response=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X POST \
    "$API_URL" \
    -H "Content-Type: application/json" \
    -H "X-Monitor-Secret: ${SECRET_CODE}" \
    -d "$payload" 2>&1) || true

  http_code=$(echo "$response" | grep "HTTP_CODE:" | cut -d: -f2)
  response_body=$(echo "$response" | sed '/HTTP_CODE:/d')

  if echo "$response_body" | grep -q "Invalid secret!"; then
      echo "Invalid secret. Stopping MTR monitor." >&2
      exit 1
  fi

  if echo "$response_body" | grep -q "Monitor is not active!"; then
      echo "Monitor is not active. Pausing MTR monitor." >&2
      exit 1
  fi

  if [ "$http_code" != "200" ]; then
      echo "Warning: Received HTTP code $http_code for target $target_host" >&2
  fi
}

TARGETS=$(split_targets | sort -fu)

if ! command -v mtr >/dev/null 2>&1; then
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    send_trace_payload "$target" false "" 127 "MTR tool not found" "" "mtr is not installed"
  done <<< "$TARGETS"
  exit 0
fi

while IFS= read -r target; do
  [ -n "$target" ] || continue

  command_str="mtr $MTR_ARGS $target"
  output=$(run_with_timeout 240 mtr $MTR_ARGS "$target" 2>&1)
  exit_code=$?

  summary=$(extract_summary "$output")
  if [ -z "$summary" ]; then
    summary=$([ "$exit_code" -eq 0 ] && echo "MTR completed" || echo "MTR failed")
  fi

  if [ "$exit_code" -eq 0 ]; then
    send_trace_payload "$target" true "$command_str" "$exit_code" "$summary" "$output" ""
  else
    send_trace_payload "$target" false "$command_str" "$exit_code" "$summary" "$output" "MTR command failed"
  fi
done <<< "$TARGETS"

exit 0
