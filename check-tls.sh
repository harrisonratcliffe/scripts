#!/bin/bash

# check_tls.sh - Check which TLS versions are enabled on a domain
# Uses nmap's ssl-enum-ciphers script (independent of system OpenSSL)
# Usage: ./check_tls.sh <domain> [port]

DOMAIN="${1}"
PORT="${2:-443}"

if [[ -z "$DOMAIN" ]]; then
  echo "Usage: $0 <domain> [port]"
  echo "Example: $0 example.com"
  echo "         $0 example.com 8443"
  exit 1
fi

if ! command -v nmap &>/dev/null; then
  echo "Error: nmap is not installed."
  echo "  macOS:  brew install nmap"
  echo "  Ubuntu: sudo apt install nmap"
  echo "  CentOS: sudo yum install nmap"
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
echo "────────────────────────────────────────────────────"

# Run nmap ssl-enum-ciphers and capture output
NMAP_OUTPUT=$(nmap --script ssl-enum-ciphers -p "${PORT}" "${DOMAIN}" 2>&1)

# Check nmap actually connected
if echo "$NMAP_OUTPUT" | grep -q "Host seems down\|0 hosts up\|Failed to resolve"; then
  echo -e "${RED}Error: Could not reach ${DOMAIN}:${PORT}${RESET}"
  exit 1
fi

check_version() {
  local label="$1"
  local search="$2"
  local deprecated="$3"

  if echo "$NMAP_OUTPUT" | grep -q "$search"; then
    if [[ "$deprecated" == "true" ]]; then
      echo -e "  ${label}  ${RED}✖  ENABLED${RESET}  ${YELLOW}(insecure — should be disabled)${RESET}"
    else
      echo -e "  ${label}  ${GREEN}✔  ENABLED${RESET}"
    fi
  else
    if [[ "$deprecated" == "true" ]]; then
      echo -e "  ${label}  ${GREEN}✔  DISABLED${RESET}  ${GRAY}(correctly disabled)${RESET}"
    else
      echo -e "  ${label}  ${RED}✖  DISABLED${RESET}"
    fi
  fi
}

check_version "SSL 2.0" "SSLv2"   "true"
check_version "SSL 3.0" "SSLv3"   "true"
check_version "TLS 1.0" "TLSv1.0" "true"
check_version "TLS 1.1" "TLSv1.1" "true"
check_version "TLS 1.2" "TLSv1.2" "false"
check_version "TLS 1.3" "TLSv1.3" "false"

echo "────────────────────────────────────────────────────"
echo ""
