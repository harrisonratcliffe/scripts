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

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
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

  if echo "$result" | grep -q "BEGIN CERTIFICATE\|Cipher is\|SSL handshake"; then
    if [[ "$deprecated" == "true" ]]; then
      echo -e "  ${version_name}   ${RED}✖  ENABLED${RESET}  ${YELLOW}(insecure — should be disabled)${RESET}"
    else
      echo -e "  ${version_name}   ${GREEN}✔  ENABLED${RESET}"
    fi
  else
    if [[ "$deprecated" == "true" ]]; then
      echo -e "  ${version_name}   ${GREEN}✔  DISABLED${RESET}  ${YELLOW}(correctly disabled)${RESET}"
    else
      echo -e "  ${version_name}   ${RED}✖  DISABLED${RESET}"
    fi
  fi
}

# Check if openssl is available
if ! command -v openssl &>/dev/null; then
  echo -e "${RED}Error: openssl is not installed.${RESET}"
  exit 1
fi

check_tls "-ssl2"    "SSL 2.0  " "true"
check_tls "-ssl3"    "SSL 3.0  " "true"
check_tls "-tls1"    "TLS 1.0  " "true"
check_tls "-tls1_1"  "TLS 1.1  " "true"
check_tls "-tls1_2"  "TLS 1.2  " "false"
check_tls "-tls1_3"  "TLS 1.3  " "false"

echo "─────────────────────────────────────"
echo ""
