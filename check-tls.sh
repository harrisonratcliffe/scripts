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

# Check if openssl is available
if ! command -v openssl &>/dev/null; then
  echo -e "${RED}Error: openssl is not installed.${RESET}"
  exit 1
fi

check_tls() {
  local disable_flags="$1"
  local version_name="$2"
  local deprecated="$3"

  result=$(echo "" | timeout 5 openssl s_client \
    -connect "${DOMAIN}:${PORT}" \
    ${disable_flags} \
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

# Isolate each version by disabling all others with -no_* flags
check_tls "-no_tls1   -no_tls1_1 -no_tls1_2 -no_tls1_3"  "SSL 3.0  " "true"
check_tls "-no_ssl3   -no_tls1_1 -no_tls1_2 -no_tls1_3"  "TLS 1.0  " "true"
check_tls "-no_ssl3   -no_tls1   -no_tls1_2 -no_tls1_3"  "TLS 1.1  " "true"
check_tls "-no_ssl3   -no_tls1   -no_tls1_1 -no_tls1_3"  "TLS 1.2  " "false"
check_tls "-no_ssl3   -no_tls1   -no_tls1_1 -no_tls1_2"  "TLS 1.3  " "false"

echo "─────────────────────────────────────"
echo ""
