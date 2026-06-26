#!/bin/bash
# SiteCenter API domain failover helpers (sourced, not executed directly).
# Version: 2026-06-26

SITECENTER_DEFAULT_API_DOMAINS=(
  mon.sitecenter.app
  mon2.sitecenter.app
  mon3.sitecenter.app
)

SITECENTER_HTTP_CODE=""
SITECENTER_RESPONSE_BODY=""
SITECENTER_API_DOMAIN_USED=""
SITECENTER_CRITICAL_ERROR=""
SITECENTER_API_DOMAINS_LIST=()
SITECENTER_DOMAIN_TRY_ORDER=()

sitecenter_normalize_domain() {
  local domain="$1"
  domain="${domain#https://}"
  domain="${domain#http://}"
  domain="${domain%%/*}"
  domain="${domain%%:*}"
  printf '%s' "$domain"
}

sitecenter_is_valid_domain() {
  [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]
}

sitecenter_get_api_domains() {
  SITECENTER_API_DOMAINS_LIST=()

  if [ -n "${SITECENTER_API_DOMAINS:-}" ]; then
    local raw="${SITECENTER_API_DOMAINS//,/ }"
    local token normalized
    for token in $raw; do
      normalized=$(sitecenter_normalize_domain "$token")
      if sitecenter_is_valid_domain "$normalized"; then
        SITECENTER_API_DOMAINS_LIST+=("$normalized")
      fi
    done
  fi

  if [ ${#SITECENTER_API_DOMAINS_LIST[@]} -eq 0 ]; then
    SITECENTER_API_DOMAINS_LIST=("${SITECENTER_DEFAULT_API_DOMAINS[@]}")
  fi
}

sitecenter_get_domain_state_file() {
  printf '/tmp/sitecenter-api-domain-%s.state' "$1"
}

sitecenter_load_preferred_domain() {
  local state_key="$1"
  local state_file preferred

  state_file=$(sitecenter_get_domain_state_file "$state_key")
  preferred=""
  if [ -f "$state_file" ] && [ -r "$state_file" ]; then
    preferred=$(head -n 1 "$state_file" 2>/dev/null | tr -d '\r\n')
    preferred=$(sitecenter_normalize_domain "$preferred")
    if ! sitecenter_is_valid_domain "$preferred"; then
      preferred=""
    fi
  fi
  printf '%s' "$preferred"
}

sitecenter_save_preferred_domain() {
  local state_key="$1"
  local domain="$2"
  local state_file tmp_file

  state_file=$(sitecenter_get_domain_state_file "$state_key")
  tmp_file=$(mktemp "${state_file}.XXXXXX") || return 1
  printf '%s\n' "$domain" > "$tmp_file"
  mv "$tmp_file" "$state_file"
}

sitecenter_build_domain_try_order() {
  local preferred="$1"
  shift
  local -a all_domains=("$@")
  local domain found=0

  SITECENTER_DOMAIN_TRY_ORDER=()

  if [ -n "$preferred" ]; then
    for domain in "${all_domains[@]}"; do
      if [ "$domain" = "$preferred" ]; then
        found=1
        break
      fi
    done
  fi

  if [ "$found" -eq 1 ]; then
    SITECENTER_DOMAIN_TRY_ORDER=("$preferred")
    for domain in "${all_domains[@]}"; do
      [ "$domain" = "$preferred" ] && continue
      SITECENTER_DOMAIN_TRY_ORDER+=("$domain")
    done
  else
    SITECENTER_DOMAIN_TRY_ORDER=("${all_domains[@]}")
  fi
}

sitecenter_check_critical_response() {
  SITECENTER_CRITICAL_ERROR=""
  if echo "$SITECENTER_RESPONSE_BODY" | grep -q "Invalid secret!"; then
    SITECENTER_CRITICAL_ERROR="invalid_secret"
    return 0
  fi
  if echo "$SITECENTER_RESPONSE_BODY" | grep -q "Monitor is not active!"; then
    SITECENTER_CRITICAL_ERROR="monitor_inactive"
    return 0
  fi
  return 1
}

# Returns: 0=HTTP 200, 1=all domains failed, 2=critical auth/account error
sitecenter_post_with_domain_failover() {
  local state_key="$1"
  local api_path="$2"
  local secret_code="${3:-}"
  local payload="$4"
  local curl_timeout="${5:-30}"
  local operation_label="${6:-API request}"
  local preferred domain response http_code curl_status
  local -a try_order=()

  if ! command -v curl >/dev/null 2>&1; then
    echo "curl is required for $operation_label" >&2
    return 1
  fi

  SITECENTER_HTTP_CODE=""
  SITECENTER_RESPONSE_BODY=""
  SITECENTER_API_DOMAIN_USED=""
  SITECENTER_CRITICAL_ERROR=""

  sitecenter_get_api_domains
  preferred=$(sitecenter_load_preferred_domain "$state_key")
  sitecenter_build_domain_try_order "$preferred" "${SITECENTER_API_DOMAINS_LIST[@]}"
  try_order=("${SITECENTER_DOMAIN_TRY_ORDER[@]}")

  for domain in "${try_order[@]}"; do
    echo "Trying API domain: $domain ($operation_label)" >&2

    if command -v timeout >/dev/null 2>&1; then
      if [ -n "$secret_code" ]; then
        response=$(timeout "$curl_timeout" curl -s -w "\nHTTP_CODE:%{http_code}" -X POST \
          "https://${domain}${api_path}" \
          -H "Content-Type: application/json" \
          -H "X-Monitor-Secret: ${secret_code}" \
          -d "$payload" 2>&1) || curl_status=$?
      else
        response=$(timeout "$curl_timeout" curl -s -w "\nHTTP_CODE:%{http_code}" -X POST \
          "https://${domain}${api_path}" \
          -H "Content-Type: application/json" \
          -d "$payload" 2>&1) || curl_status=$?
      fi
    elif [ -n "$secret_code" ]; then
      response=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X POST \
        "https://${domain}${api_path}" \
        -H "Content-Type: application/json" \
        -H "X-Monitor-Secret: ${secret_code}" \
        -d "$payload" 2>&1) || curl_status=$?
    else
      response=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X POST \
        "https://${domain}${api_path}" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>&1) || curl_status=$?
    fi
    curl_status=${curl_status:-0}

    http_code=$(echo "$response" | grep "HTTP_CODE:" | tail -n 1 | cut -d: -f2)
    SITECENTER_RESPONSE_BODY=$(echo "$response" | sed '/HTTP_CODE:/d')
    SITECENTER_HTTP_CODE="${http_code:-}"

    if sitecenter_check_critical_response; then
      return 2
    fi

    if [ "$curl_status" -ne 0 ] || [ -z "$http_code" ] || [ "$http_code" = "000" ]; then
      echo "API domain $domain failed (connection error)" >&2
      continue
    fi

    if [ "$http_code" = "200" ]; then
      SITECENTER_API_DOMAIN_USED="$domain"
      sitecenter_save_preferred_domain "$state_key" "$domain"
      echo "API domain $domain succeeded, saved as preferred" >&2
      return 0
    fi

    echo "API domain $domain failed (HTTP $http_code)" >&2
  done

  echo "All API domains failed for $operation_label" >&2
  return 1
}

sitecenter_source_api_domains() {
  local script_dir helper_path

  for helper_path in \
    "/usr/local/bin/sitecenter-api-domains.sh" \
    "$(cd "$(dirname "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")" 2>/dev/null && pwd)/sitecenter-api-domains.sh"; do
    if [ -f "$helper_path" ]; then
      # shellcheck source=/dev/null
      source "$helper_path"
      return 0
    fi
  done

  return 1
}
