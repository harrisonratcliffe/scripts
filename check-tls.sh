#!/bin/bash

# check_tls.sh - Check which TLS versions are enabled on a domain
# Usage: ./check_tls.sh <domain> [port]

DOMAIN="${1}"
PORT="${2:-443}"

if [[ -z "$DOMAIN" ]]; then
  echo "Usage: $0 <domain> [port]"
  echo "Example: $0 example.com"
  echo "         $0 example.com 8443"
  exit 1
fi

if ! command -v openssl &>/dev/null; then
  echo "Error: openssl is not installed."
  exit 1
fi

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
GRAY='\033[0;90m'
BOLD='\033[1m'
RESET='\033[0m'

echo ""
echo -e "${BOLD}TLS Version Check${RESET}"
echo -e "Host: ${BOLD}${DOMAIN}:${PORT}${RESET}"
echo "─────────────────────────────────────"

check_tls() {
  local version_flag="$1"
  local version_name="$2"
  local deprecated="$3"

  result=$(echo "" | timeout 5 openssl s_client \
    -connect "${DOMAIN}:${PORT}" \
    ${version_flag} \
    -servername "${DOMAIN}" \
    2>&1)

  # Check if openssl itself doesn't support this version (not a server result)
  if echo "$result" | grep -qiE "unknown option|unsupported option|Option unknown|no protocols available|ssl[23]? support|wrong version number|no cipher|SSL routines.*version"; then
    echo -e "  ${version_name}  ${GRAY}—  UNKNOWN${RESET}  ${GRAY}(openssl build doesn't support this version)${RESET}"
    return
  fi

  # Successful handshake = server accepted this TLS version
  if echo "$result" | grep -qE "BEGIN CERTIFICATE|Cipher    :|Cipher is [^(none)]|SSL-Session"; then
    if [[ "$deprecated" == "true" ]]; then
      echo -e "  ${version_name}  ${RED}✖  ENABLED${RESET}  ${YELLOW}(insecure — should be disabled)${RESET}"
    else
      echo -e "  ${version_name}  ${GREEN}✔  ENABLED${RESET}"
    fi
  # Server explicitly rejected/closed = disabled
  elif echo "$result" | grep -qiE "alert|handshake failure|no protocols|connection refused|CONNECTED.*errno|ssl handshake failure|tlsv1 alert|no shared cipher|peer error"; then
    if [[ "$deprecated" == "true" ]]; then
      echo -e "  ${version_name}  ${GREEN}✔  DISABLED${RESET}  ${GRAY}(correctly disabled)${RESET}"
    else
      echo -e "  ${version_name}  ${RED}✖  DISABLED${RESET}"
    fi
  # Timeout or connection issue
  elif echo "$result" | grep -qiE "timeout|Connection timed out|connect:errno"; then
    echo -e "  ${version_name}  ${GRAY}—  TIMEOUT${RESET}"
  else
    # Fallback: treat non-handshake as disabled
    if [[ "$deprecated" == "true" ]]; then
      echo -e "  ${version_name}  ${GREEN}✔  DISABLED${RESET}  ${GRAY}(correctly disabled)${RESET}"
    else
      echo -e "  ${version_name}  ${RED}✖  DISABLED${RESET}"
    fi
  fi
}

check_tls "-ssl2"   "SSL 2.0" "true"
check_tls "-ssl3"   "SSL 3.0" "true"
check_tls "-tls1"   "TLS 1.0" "true"
check_tls "-tls1_1" "TLS 1.1" "true"
check_tls "-tls1_2" "TLS 1.2" "false"
check_tls "-tls1_3" "TLS 1.3" "false"

echo "─────────────────────────────────────"
echo ""
