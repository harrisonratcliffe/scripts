#!/usr/bin/env bash

# ==============================================================================
# Script: build-ubuntu.sh
# Production Server Provisioning & Hardening Wizard
# Target OS: Ubuntu 22.04 / 24.04 / 26.04 LTS & Debian 11 / 12
# ==============================================================================

set -Eeuo pipefail

# ------------------------------------------------------------------------------
# PIPELINE RULE (read before editing):
#
# With "pipefail" enabled, never END a pipeline with a command that stops
# reading early (awk '{...; exit}', head, grep -q, grep -m, sed q). The writer
# receives SIGPIPE, the pipeline returns 141, and "set -e" aborts the script.
# Capture the output into a variable first, then parse the variable.
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Error handling
#
# Any unexpected failure prints the line and command that failed instead of
# stopping silently. If it happens while SSH / firewall changes are in flight,
# the SSH port change is rolled back so port 22 remains reachable.
# ------------------------------------------------------------------------------

SSH_CHANGES_IN_FLIGHT="N"

on_error() {

    local rc="$1"
    local line="$2"
    local cmd="$3"

    # With errtrace (-E) the trap also fires inside command substitutions.
    # Let the parent shell report the failure once, not twice.
    if (( BASH_SUBSHELL > 0 )); then
        return
    fi

    trap - ERR

    echo -e "\033[0;31m[!] Script aborted: exit code ${rc} at line ${line}\033[0m" >&2
    echo -e "\033[0;31m[!] Failed command: ${cmd}\033[0m" >&2

    if [[ "$SSH_CHANGES_IN_FLIGHT" == "Y" ]] && declare -F rollback_ssh >/dev/null; then
        rollback_ssh || true
    fi

    exit "$rc"

}

trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

# True if systemd knows the unit. No pipeline, so no SIGPIPE risk.
unit_exists() {
    systemctl cat "$1" &>/dev/null
}

# ------------------------------------------------------------------------------
# systemd / D-Bus health check
#
# Almost every SSH step (and the rollback) depends on systemctl. If PID 1 or
# the system bus is unreachable - e.g. after an upgrade re-executed systemd or
# deferred a dbus restart - the script must stop BEFORE touching SSH, because
# it would not be able to roll a failed port change back.
# ------------------------------------------------------------------------------

check_system_bus() {

    local stage="$1"
    local problem=""

    if ! systemctl show --property=Version --value >/dev/null 2>&1; then
        problem="systemctl cannot reach systemd (PID 1)"
    elif ! busctl --system list --no-pager >/dev/null 2>&1; then
        problem="the D-Bus system bus is not responding"
    fi

    if [[ -n "$problem" ]]; then

        echo -e "\033[0;31m[!] Health check failed (${stage}): ${problem}.\033[0m" >&2
        echo -e "\033[0;31m[!] Stopping before any SSH or firewall changes are made.\033[0m" >&2
        echo -e "\033[1;33m[*] Reboot the server (a pending kernel/systemd upgrade is the usual cause), then re-run this script.\033[0m" >&2

        exit 1

    fi

}

# ------------------------------------------------------------------------------
# Root check
# ------------------------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo "[!] This script must be run as root."
    exit 1
fi

check_system_bus "startup"

# ------------------------------------------------------------------------------
# Terminal colors
# ------------------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

clear

echo -e "${BLUE}================================================================${NC}"
echo -e "${BLUE}           Ubuntu Server Provisioning & Hardening Wizard        ${NC}"
echo -e "${BLUE}                         (build-ubuntu.sh)                      ${NC}"
echo -e "${BLUE}================================================================${NC}"
echo ""

# ==============================================================================
# 1. Interactive Configuration Wizard
# ==============================================================================

# ------------------------------------------------------------------------------
# 1.1 Full System Package Upgrade
# ------------------------------------------------------------------------------

read -rp "Run full 'apt update && apt upgrade -y'? [Y/n]: " DO_UPGRADE
DO_UPGRADE=${DO_UPGRADE:-Y}

# ------------------------------------------------------------------------------
# 1.2 Hostname
# ------------------------------------------------------------------------------

CURRENT_HOSTNAME="$(hostname)"

echo ""
echo -e "Current hostname: ${CYAN}${CURRENT_HOSTNAME}${NC}"

read -rp "Change the system hostname? [y/N]: " CHANGE_HOSTNAME
CHANGE_HOSTNAME=${CHANGE_HOSTNAME:-N}

NEW_HOSTNAME="$CURRENT_HOSTNAME"

if [[ "$CHANGE_HOSTNAME" =~ ^[Yy]$ ]]; then

    echo ""
    echo "You may enter a short name (web01) or a fully qualified name (web01.example.com)."
    echo ""

    while true; do

        read -rp "Enter new hostname: " NEW_HOSTNAME

        # Strip a trailing dot if the user typed an absolute FQDN.
        NEW_HOSTNAME="${NEW_HOSTNAME%.}"

        if [[ -z "$NEW_HOSTNAME" ]]; then
            echo -e "${RED}[!] Hostname cannot be empty.${NC}"
            continue
        fi

        if (( ${#NEW_HOSTNAME} > 253 )); then
            echo -e "${RED}[!] Hostname exceeds the 253 character maximum.${NC}"
            continue
        fi

        # Validate each dot-separated label: alphanumeric, may contain internal
        # hyphens, 1-63 characters, must not start or end with a hyphen.
        HOSTNAME_VALID="Y"

        IFS='.' read -ra HOSTNAME_LABELS <<< "$NEW_HOSTNAME"

        for LABEL in "${HOSTNAME_LABELS[@]}"; do

            if [[ ! "$LABEL" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
                HOSTNAME_VALID="N"
                break
            fi

        done

        if [[ "$HOSTNAME_VALID" == "Y" ]]; then
            break
        fi

        echo -e "${RED}[!] Invalid hostname. Use letters, numbers and hyphens; each label must be 1-63 characters and must not begin or end with a hyphen.${NC}"

    done

fi

# Short name is everything before the first dot; used as the /etc/hosts alias.
NEW_HOSTNAME_SHORT="${NEW_HOSTNAME%%.*}"

# ------------------------------------------------------------------------------
# 1.3 Non-root Admin Username (optional)
#
# Leaving this blank skips user creation entirely. In that case the script also
# leaves PermitRootLogin untouched, so whatever the server already has (e.g.
# Ubuntu's default "prohibit-password") stays in effect.
# ------------------------------------------------------------------------------

echo ""
echo "Leave the username blank to skip creating a new admin user."
echo "(If skipped, the existing PermitRootLogin setting is left unchanged.)"
echo ""

CREATE_USER="N"

while true; do
    read -rp "Enter new administrative username (e.g. deployer) [blank = skip]: " NEW_USER

    if [[ -z "$NEW_USER" ]]; then
        CREATE_USER="N"
        break
    fi

    if [[ ! "$NEW_USER" =~ [^a-z0-9_-] ]]; then
        CREATE_USER="Y"
        break
    fi

    echo -e "${RED}[!] Invalid username. Use lowercase letters, numbers, hyphens, or underscores.${NC}"
done

# ------------------------------------------------------------------------------
# 1.4 SSH Public Key Input
# ------------------------------------------------------------------------------

USER_SSH_KEY=""
DISABLE_PASSWORD_AUTH="Y"

if [[ "$CREATE_USER" == "Y" ]]; then

    echo ""
    echo -e "${YELLOW}Paste your public SSH key (e.g. ssh-ed25519 AAAA...):${NC}"

    read -rp "SSH Key: " USER_SSH_KEY

    while [[ -z "$USER_SSH_KEY" ]]; do
        echo -e "${RED}[!] An SSH key is required because password authentication will be disabled.${NC}"
        read -rp "SSH Key: " USER_SSH_KEY
    done

else

    echo ""
    echo -e "${YELLOW}[*] Skipping new user creation.${NC}"

    # Lockout guard: password authentication is about to be disabled, so make
    # sure SOME account already has an authorized key before doing that.
    EXISTING_KEYS="N"

    for KEYFILE in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
        if [[ -s "$KEYFILE" ]]; then
            EXISTING_KEYS="Y"
            break
        fi
    done

    if [[ "$EXISTING_KEYS" == "Y" ]]; then

        echo -e "${GREEN}[*] Existing authorized_keys found. Password authentication will be disabled.${NC}"

    else

        echo -e "${RED}[!] No existing authorized_keys found for root or any /home user.${NC}"
        echo -e "${RED}[!] Disabling password authentication now could lock you out.${NC}"

        read -rp "Disable SSH password authentication anyway? [y/N]: " FORCE_DISABLE_PW
        FORCE_DISABLE_PW=${FORCE_DISABLE_PW:-N}

        if [[ ! "$FORCE_DISABLE_PW" =~ ^[Yy]$ ]]; then
            DISABLE_PASSWORD_AUTH="N"
            echo -e "${YELLOW}[*] Password authentication settings will be left unchanged.${NC}"
        fi

    fi

fi

# ------------------------------------------------------------------------------
# 1.5 SSH Port Setup
# ------------------------------------------------------------------------------

echo ""

read -rp "Change default SSH port 22? [Y/n]: " CHANGE_SSH
CHANGE_SSH=${CHANGE_SSH:-Y}

if [[ "$CHANGE_SSH" =~ ^[Yy]$ ]]; then

    while true; do

        read -rp "Enter SSH port [Default: 922]: " SSH_PORT
        SSH_PORT=${SSH_PORT:-922}

        if [[ "$SSH_PORT" =~ ^[0-9]+$ ]] &&
           (( SSH_PORT >= 1 && SSH_PORT <= 65535 )); then
            break
        fi

        echo -e "${RED}[!] Invalid port. Enter a number between 1 and 65535.${NC}"

    done

else

    SSH_PORT=22

fi

# ------------------------------------------------------------------------------
# 1.6 Trusted IP / CIDR Whitelist
# ------------------------------------------------------------------------------

echo ""
echo -e "${YELLOW}Optional firewall trusted-source whitelist:${NC}"
echo ""
echo "If enabled:"
echo "  - SSH will NOT be opened globally in UFW."
echo "  - Each trusted IP/CIDR receives FULL inbound firewall access."
echo "  - HTTP 80 and HTTPS 443 will still remain publicly accessible."
echo ""
echo "You may enter multiple IPs/CIDRs separated by commas."
echo ""
echo "Examples:"
echo "  203.0.113.25"
echo "  203.0.113.25,198.51.100.10"
echo "  203.0.113.0/24,2001:db8:1234::/64"
echo ""

read -rp "Restrict SSH using trusted IP/CIDR whitelist? [y/N]: " ENABLE_WHITELIST
ENABLE_WHITELIST=${ENABLE_WHITELIST:-N}

TRUSTED_SOURCES=()

if [[ "$ENABLE_WHITELIST" =~ ^[Yy]$ ]]; then

    while true; do

        read -rp "Trusted IPs/CIDRs (comma separated): " TRUSTED_INPUT

        TRUSTED_SOURCES=()

        IFS=',' read -ra RAW_TRUSTED_SOURCES <<< "$TRUSTED_INPUT"

        for SOURCE in "${RAW_TRUSTED_SOURCES[@]}"; do

            # Trim leading whitespace
            SOURCE="${SOURCE#"${SOURCE%%[![:space:]]*}"}"

            # Trim trailing whitespace
            SOURCE="${SOURCE%"${SOURCE##*[![:space:]]}"}"

            [[ -z "$SOURCE" ]] && continue

            TRUSTED_SOURCES+=("$SOURCE")

        done

        if (( ${#TRUSTED_SOURCES[@]} > 0 )); then
            break
        fi

        echo -e "${RED}[!] At least one trusted IP address or CIDR is required.${NC}"

    done

fi

# ------------------------------------------------------------------------------
# 1.7 Dynamic SWAP Calculator
# ------------------------------------------------------------------------------

echo ""

TOTAL_RAM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
TOTAL_RAM_GB=$(awk -v ram="$TOTAL_RAM_KB" \
    'BEGIN {print int((ram / 1024 / 1024) + 0.999)}')

# Production swap recommendation
if (( TOTAL_RAM_GB <= 2 )); then

    REC_SWAP=$(( TOTAL_RAM_GB * 2 ))

elif (( TOTAL_RAM_GB <= 8 )); then

    REC_SWAP=$TOTAL_RAM_GB

else

    REC_SWAP=$(( (TOTAL_RAM_GB + 1) / 2 ))

fi

echo -e "Detected RAM: ${CYAN}${TOTAL_RAM_GB} GB${NC}"

read -rp "Configure a SWAP file? [Y/n]: " CONFIGURE_SWAP
CONFIGURE_SWAP=${CONFIGURE_SWAP:-Y}

SWAP_SIZE_GB=$REC_SWAP

if [[ "$CONFIGURE_SWAP" =~ ^[Yy]$ ]]; then

    read -rp "SWAP size in GB [Recommended: ${REC_SWAP}G]: " CUSTOM_SWAP

    if [[ -n "$CUSTOM_SWAP" ]]; then

        if [[ "$CUSTOM_SWAP" =~ ^[0-9]+$ ]] && (( CUSTOM_SWAP > 0 )); then

            SWAP_SIZE_GB=$CUSTOM_SWAP

        else

            echo -e "${YELLOW}[*] Invalid custom size. Using recommended ${REC_SWAP}G.${NC}"

        fi

    fi

fi

# ------------------------------------------------------------------------------
# 1.8 Security Layer Selection
# ------------------------------------------------------------------------------

echo ""
echo "Select intrusion detection layer:"
echo ""
echo "  1) CrowdSec + Firewall Bouncer (Recommended)"
echo "  2) Fail2Ban"
echo "  3) Both (CrowdSec + Fail2Ban)"
echo "  4) None / Skip"
echo ""

while true; do

    read -rp "Choice [1-4, Default: 1]: " SEC_CHOICE
    SEC_CHOICE=${SEC_CHOICE:-1}

    if [[ "$SEC_CHOICE" =~ ^[1-4]$ ]]; then
        break
    fi

    echo -e "${RED}[!] Enter a number between 1 and 4.${NC}"

done

# ------------------------------------------------------------------------------
# 1.9 Docker Engine Installation
# ------------------------------------------------------------------------------

echo ""

read -rp "Install Docker Engine & Docker Compose plugin? [Y/n]: " INSTALL_DOCKER
INSTALL_DOCKER=${INSTALL_DOCKER:-Y}

# ------------------------------------------------------------------------------
# Configuration Summary
# ------------------------------------------------------------------------------

echo ""
echo -e "${GREEN}Configuration captured.${NC}"
echo ""

if [[ "$CHANGE_HOSTNAME" =~ ^[Yy]$ ]]; then
    echo "  Hostname:         ${CURRENT_HOSTNAME} -> ${NEW_HOSTNAME}"
else
    echo "  Hostname:         ${CURRENT_HOSTNAME} (unchanged)"
fi

if [[ "$CREATE_USER" == "Y" ]]; then
    echo "  Admin user:       ${NEW_USER}"
    echo "  Root login:       Will be disabled"
else
    echo "  Admin user:       (none - skipped)"
    echo "  Root login:       Left unchanged"
fi

if [[ "$DISABLE_PASSWORD_AUTH" == "Y" ]]; then
    echo "  Password auth:    Will be disabled"
else
    echo "  Password auth:    Left unchanged"
fi

echo "  SSH port:         ${SSH_PORT}"

if [[ "$ENABLE_WHITELIST" =~ ^[Yy]$ ]]; then

    echo "  SSH exposure:     Trusted sources only"
    echo "  Trusted sources:"

    for SOURCE in "${TRUSTED_SOURCES[@]}"; do
        echo "                    - ${SOURCE}"
    done

else

    echo "  SSH exposure:     Public TCP/${SSH_PORT}"

fi

if [[ "$CONFIGURE_SWAP" =~ ^[Yy]$ ]]; then
    echo "  Swap:             ${SWAP_SIZE_GB} GB"
else
    echo "  Swap:             Disabled"
fi

echo ""

# ==============================================================================
# 2. Base System Updates & Essential Packages
# ==============================================================================

export DEBIAN_FRONTEND=noninteractive

echo -e "\n${BLUE}[1/9] Updating package index and installing essentials...${NC}"

apt-get update -y

if [[ "$DO_UPGRADE" =~ ^[Yy]$ ]]; then

    echo -e "${BLUE}[*] Performing full system package upgrade...${NC}"
    apt-get upgrade -y

fi

apt-get install -y \
    curl \
    wget \
    git \
    ufw \
    unattended-upgrades \
    apt-transport-https \
    ca-certificates \
    gnupg \
    lsb-release \
    htop \
    iotop \
    net-tools \
    iproute2 \
    systemd-timesyncd

# The upgrade may have re-executed systemd or deferred a dbus restart.
check_system_bus "after package upgrade"

# Enable network time synchronization
timedatectl set-ntp true

# ==============================================================================
# 3. Hostname Configuration
# ==============================================================================

echo -e "\n${BLUE}[2/9] Configuring hostname...${NC}"

if [[ "$CHANGE_HOSTNAME" =~ ^[Yy]$ ]]; then

    echo -e "${BLUE}[*] Setting hostname to '${NEW_HOSTNAME}'...${NC}"

    hostnamectl set-hostname "$NEW_HOSTNAME"

    # --------------------------------------------------------------------------
    # /etc/hosts
    #
    # Debian convention: the 127.0.1.1 line carries the machine's own name so
    # that "hostname -f" and anything calling gethostbyname() resolves locally
    # even with no DNS. Leave the 127.0.0.1 localhost line alone.
    # --------------------------------------------------------------------------

    cp -a /etc/hosts "/etc/hosts.bak.$(date +%Y%m%d%H%M%S)"

    if [[ "$NEW_HOSTNAME" == "$NEW_HOSTNAME_SHORT" ]]; then
        HOSTS_ENTRY=$'127.0.1.1\t'"${NEW_HOSTNAME}"
    else
        HOSTS_ENTRY=$'127.0.1.1\t'"${NEW_HOSTNAME} ${NEW_HOSTNAME_SHORT}"
    fi

    if grep -qE '^[[:space:]]*127\.0\.1\.1[[:space:]]' /etc/hosts; then

        # Replace the existing 127.0.1.1 mapping in place.
        awk -v entry="$HOSTS_ENTRY" '
            /^[[:space:]]*127\.0\.1\.1[[:space:]]/ && !done { print entry; done = 1; next }
            { print }
        ' /etc/hosts > /etc/hosts.tmp

        cat /etc/hosts.tmp > /etc/hosts
        rm -f /etc/hosts.tmp

    else

        printf '%s\n' "$HOSTS_ENTRY" >> /etc/hosts

    fi

    # Remove any stale mapping that still points at the previous short name,
    # but never touch the loopback localhost line.
    OLD_SHORT="${CURRENT_HOSTNAME%%.*}"

    if [[ -n "$OLD_SHORT" && "$OLD_SHORT" != "$NEW_HOSTNAME_SHORT" && "$OLD_SHORT" != "localhost" ]]; then

        awk -v old="$OLD_SHORT" '
            $1 == "127.0.0.1" { print; next }
            {
                for (i = 2; i <= NF; i++) {
                    if ($i == old) { next }
                }
                print
            }
        ' /etc/hosts > /etc/hosts.tmp

        cat /etc/hosts.tmp > /etc/hosts
        rm -f /etc/hosts.tmp

    fi

    echo -e "${GREEN}[*] Hostname set. Current /etc/hosts:${NC}"
    cat /etc/hosts

else

    echo -e "${YELLOW}[*] Hostname unchanged (${CURRENT_HOSTNAME}).${NC}"

fi

# ==============================================================================
# 4. Validate Trusted Firewall Sources
# ==============================================================================

if [[ "$ENABLE_WHITELIST" =~ ^[Yy]$ ]]; then

    echo -e "\n${BLUE}[*] Validating trusted firewall sources...${NC}"

    for SOURCE in "${TRUSTED_SOURCES[@]}"; do

        # Explicitly reject values that effectively mean "everyone".
        case "$SOURCE" in
            any|0.0.0.0/0|::/0)
                echo -e "${RED}[!] '${SOURCE}' would allow the entire Internet and is not valid for whitelist mode.${NC}"
                exit 1
                ;;
        esac

        # Let UFW validate IPv4, IPv6 and CIDR syntax before changing anything.
        if ! ufw --dry-run allow from "$SOURCE" >/dev/null 2>&1; then

            echo -e "${RED}[!] Invalid IP address or CIDR: ${SOURCE}${NC}"
            echo -e "${RED}[!] Firewall configuration has NOT been changed.${NC}"
            exit 1

        fi

        echo -e "${GREEN}[*] Valid trusted source: ${SOURCE}${NC}"

    done

fi

# ==============================================================================
# 5. User Provisioning & Passwordless Sudo
# ==============================================================================

if [[ "$CREATE_USER" == "Y" ]]; then

    echo -e "\n${BLUE}[3/9] Provisioning user '${NEW_USER}' with passwordless sudo...${NC}"

    if id "$NEW_USER" &>/dev/null; then

        echo -e "${YELLOW}[*] User ${NEW_USER} already exists. Ensuring sudo and SSH access...${NC}"

    else

        adduser --disabled-password --gecos "" "$NEW_USER"

    fi

    usermod -aG sudo "$NEW_USER"

    # Configure passwordless sudo
    echo "${NEW_USER} ALL=(ALL) NOPASSWD:ALL" \
        > "/etc/sudoers.d/90-${NEW_USER}-init"

    chmod 0440 "/etc/sudoers.d/90-${NEW_USER}-init"

    # Validate sudoers entry
    if ! visudo -cf "/etc/sudoers.d/90-${NEW_USER}-init" >/dev/null; then

        echo -e "${RED}[!] Generated sudoers configuration is invalid.${NC}"
        rm -f "/etc/sudoers.d/90-${NEW_USER}-init"
        exit 1

    fi

    # Deploy authorized SSH key
    USER_SSH_DIR="/home/${NEW_USER}/.ssh"

    mkdir -p "$USER_SSH_DIR"

    printf '%s\n' "$USER_SSH_KEY" \
        > "${USER_SSH_DIR}/authorized_keys"

    chmod 700 "$USER_SSH_DIR"
    chmod 600 "${USER_SSH_DIR}/authorized_keys"

    chown -R "${NEW_USER}:${NEW_USER}" "$USER_SSH_DIR"

else

    echo -e "\n${BLUE}[3/9] No admin username given. Skipping user provisioning.${NC}"

fi

# ==============================================================================
# 6. Prepare SSH Hardening Configuration
# ==============================================================================

echo -e "\n${BLUE}[4/9] Preparing SSH hardening on port ${SSH_PORT}...${NC}"

# Last health check before the point of no easy return.
check_system_bus "before SSH changes"

SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"
SSHD_DROPIN_FILE="${SSHD_DROPIN_DIR}/00-hardening.conf"

SSH_SOCKET_DROPIN_DIR="/etc/systemd/system/ssh.socket.d"
SSH_SOCKET_DROPIN_FILE="${SSH_SOCKET_DROPIN_DIR}/99-listen.conf"

# ------------------------------------------------------------------------------
# Emergency rollback: restore port 22 access so a failed port change can never
# leave the box unreachable. Defined here so the ERR trap can use it from the
# moment the first SSH file is written.
# ------------------------------------------------------------------------------

rollback_ssh() {

    SSH_CHANGES_IN_FLIGHT="N"

    echo -e "${RED}[!] Rolling back SSH port change to restore access on port 22...${NC}"

    rm -f "$SSHD_DROPIN_FILE" "$SSH_SOCKET_DROPIN_FILE"

    # Re-runs the Ubuntu sshd socket generator, which now sees port 22 again.
    systemctl daemon-reload || true

    if systemctl is-enabled --quiet ssh.socket 2>/dev/null \
        || systemctl is-active --quiet ssh.socket 2>/dev/null; then

        # Same order as the forward path: a running sshd holds the inherited
        # listener, so stop the service BEFORE re-binding the socket.
        # (KillMode=process keeps existing SSH sessions alive.)
        systemctl stop ssh.service 2>/dev/null || true
        systemctl stop ssh.socket 2>/dev/null || true
        systemctl start ssh.socket 2>/dev/null || true

    else

        systemctl restart ssh.service 2>/dev/null \
            || systemctl restart sshd.service 2>/dev/null \
            || true

    fi

    ufw allow 22/tcp comment 'SSH rollback' >/dev/null 2>&1 || true

    echo -e "${YELLOW}[*] SSH should now be reachable on port 22 again.${NC}"
    echo -e "${YELLOW}[*] Hardening drop-ins were removed. Investigate before retrying.${NC}"

}

mkdir -p "$SSHD_DROPIN_DIR"

# ------------------------------------------------------------------------------
# NOTE ON THE FILENAME:
#
# sshd uses the FIRST value it obtains for any keyword, and the stock
# sshd_config sources the drop-in directory at the very top of the file.
# Cloud images ship /etc/ssh/sshd_config.d/50-cloud-init.conf, which sorts
# before "99-*.conf" and would therefore win. Naming this file 00-hardening.conf
# guarantees our values are parsed first.
# ------------------------------------------------------------------------------

# Clean up the drop-in written by earlier revisions of this script.
rm -f "${SSHD_DROPIN_DIR}/99-hardening.conf"

# From here until the new port is verified, any unexpected failure rolls back.
SSH_CHANGES_IN_FLIGHT="Y"

# ------------------------------------------------------------------------------
# PermitRootLogin is only written when a new admin user was created. Without
# one, the keyword is omitted entirely so the server's existing setting (from
# sshd_config or another drop-in) keeps applying.
# ------------------------------------------------------------------------------

{
    echo "Port ${SSH_PORT}"

    if [[ "$CREATE_USER" == "Y" ]]; then
        echo "PermitRootLogin no"
    fi

    if [[ "$DISABLE_PASSWORD_AUTH" == "Y" ]]; then
        echo "PasswordAuthentication no"
        echo "KbdInteractiveAuthentication no"
    fi

    echo "PubkeyAuthentication yes"
    echo "X11Forwarding no"
    echo "MaxAuthTries 3"
    echo "ClientAliveInterval 300"
    echo "ClientAliveCountMax 2"
} > "$SSHD_DROPIN_FILE"

# Warn if another drop-in still sets a conflicting Port.
CONFLICTING_PORTS=$(
    grep -rlsiE '^[[:space:]]*Port[[:space:]]+' "$SSHD_DROPIN_DIR" 2>/dev/null \
    | grep -v "^${SSHD_DROPIN_FILE}$" || true
)

if [[ -n "$CONFLICTING_PORTS" ]]; then

    echo -e "${YELLOW}[*] Other sshd drop-ins also define Port (ours is parsed first):${NC}"
    printf '    %s\n' $CONFLICTING_PORTS

fi

# sshd -t / -T refuse to run without the privilege separation directory.
# /run is a tmpfs and, with socket activation, /run/sshd is only created when
# ssh.service starts - so on a freshly booted box it may not exist yet.
if [[ ! -d /run/sshd ]]; then
    mkdir -p /run/sshd
    chmod 0755 /run/sshd
fi

# Validate sshd configuration BEFORE firewall/socket changes
if ! sshd -t; then

    echo -e "${RED}[!] SSH syntax check failed.${NC}"
    echo -e "${RED}[!] Removing hardening configuration to prevent lockout.${NC}"

    rm -f "$SSHD_DROPIN_FILE"
    SSH_CHANGES_IN_FLIGHT="N"

    exit 1

fi

echo -e "${GREEN}[*] OpenSSH configuration syntax is valid.${NC}"

# Confirm sshd's effective port really is what we asked for.
#
# Capture first, then parse. Piping "sshd -T" into an awk that exits on the
# first match kills sshd with SIGPIPE, and pipefail + set -e then aborts the
# whole script silently.
SSHD_EFFECTIVE_CONFIG=$(sshd -T 2>/dev/null) || SSHD_EFFECTIVE_CONFIG=""
EFFECTIVE_PORT=$(awk '/^port / && !found { print $2; found = 1 }' <<< "$SSHD_EFFECTIVE_CONFIG")
EFFECTIVE_ROOT_LOGIN=$(awk '/^permitrootlogin / && !found { print $2; found = 1 }' <<< "$SSHD_EFFECTIVE_CONFIG")

if [[ -n "$EFFECTIVE_PORT" && "$EFFECTIVE_PORT" != "$SSH_PORT" ]]; then

    echo -e "${RED}[!] sshd reports an effective port of ${EFFECTIVE_PORT}, not ${SSH_PORT}.${NC}"
    echo -e "${RED}[!] Another configuration file is overriding the port. Aborting.${NC}"

    rm -f "$SSHD_DROPIN_FILE"
    SSH_CHANGES_IN_FLIGHT="N"

    exit 1

fi

if [[ "$CREATE_USER" != "Y" ]]; then
    echo -e "${YELLOW}[*] PermitRootLogin left unchanged (effective value: ${EFFECTIVE_ROOT_LOGIN:-unknown}).${NC}"
fi

# ------------------------------------------------------------------------------
# Configure systemd ssh.socket when the unit exists.
#
# Ubuntu 24.04+ uses socket-activated SSH by default. In that mode systemd owns
# the listening socket and "Port" in sshd_config is ignored entirely, so the
# socket unit must be overridden as well.
#
# Equivalent to:
#
#   systemctl edit ssh.socket
#
#   [Socket]
#   ListenStream=
#   ListenStream=0.0.0.0:922
#   ListenStream=[::]:922
#
# The empty ListenStream= is mandatory: it clears the port 22 entry inherited
# from the base unit. Without it, systemd APPENDS and SSH listens on both ports.
# ------------------------------------------------------------------------------

SSH_SOCKET_EXISTS="N"

if unit_exists ssh.socket; then

    SSH_SOCKET_EXISTS="Y"

    echo -e "${BLUE}[*] ssh.socket detected. Creating socket listener override...${NC}"

    mkdir -p "$SSH_SOCKET_DROPIN_DIR"

    # Drop-ins are merged in lexicographic order and ListenStream is a LIST, so
    # a stale override.conf (created by a manual "systemctl edit ssh.socket")
    # sorts AFTER 99-listen.conf and would re-add its own ports on top of ours.
    # Remove any other drop-in that touches ListenStream.
    for EXISTING_DROPIN in "$SSH_SOCKET_DROPIN_DIR"/*.conf; do

        [[ -e "$EXISTING_DROPIN" ]] || continue
        [[ "$EXISTING_DROPIN" == "$SSH_SOCKET_DROPIN_FILE" ]] && continue

        if grep -qiE '^[[:space:]]*ListenStream[[:space:]]*=' "$EXISTING_DROPIN"; then

            echo -e "${YELLOW}[*] Removing conflicting socket drop-in: ${EXISTING_DROPIN}${NC}"
            rm -f "$EXISTING_DROPIN"

        fi

    done

    cat <<EOF > "$SSH_SOCKET_DROPIN_FILE"
[Socket]
ListenStream=
ListenStream=0.0.0.0:${SSH_PORT}
ListenStream=[::]:${SSH_PORT}
EOF

else

    echo -e "${YELLOW}[*] ssh.socket is not installed. Traditional ssh.service mode will be used.${NC}"

fi

# ==============================================================================
# 7. UFW Firewall Setup
# ==============================================================================

echo -e "\n${BLUE}[5/9] Configuring UFW firewall rules...${NC}"

# IMPORTANT:
# Firewall is configured BEFORE restarting SSH so the desired access rule
# already exists when SSH starts listening on its new port.

ufw --force reset

ufw default deny incoming
ufw default allow outgoing

# ------------------------------------------------------------------------------
# SSH / Trusted Source Rules
# ------------------------------------------------------------------------------

if [[ "$ENABLE_WHITELIST" =~ ^[Yy]$ ]]; then

    echo -e "${BLUE}[*] Trusted-source mode enabled.${NC}"
    echo -e "${BLUE}[*] SSH port ${SSH_PORT} will NOT be opened globally.${NC}"

    for SOURCE in "${TRUSTED_SOURCES[@]}"; do

        echo -e "${GREEN}[*] Allowing ALL inbound traffic from ${SOURCE}${NC}"

        ufw allow from "$SOURCE" comment 'Trusted source'

    done

else

    echo -e "${BLUE}[*] Opening SSH port ${SSH_PORT}/tcp globally...${NC}"

    ufw allow "${SSH_PORT}/tcp" comment 'SSH'

fi

# ------------------------------------------------------------------------------
# Public Web Traffic
# ------------------------------------------------------------------------------

ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'

# Enable firewall non-interactively
ufw --force enable

echo ""
ufw status verbose

# ==============================================================================
# 8. Apply SSH Socket / Service Changes
# ==============================================================================

echo -e "\n${BLUE}[*] Applying SSH listener configuration...${NC}"

# Required after adding/changing/removing systemd unit drop-ins.
systemctl daemon-reload

# ------------------------------------------------------------------------------
# Decide which activation mode is in play.
#
# "Enabled" matters as much as "active": ssh.socket can be enabled but inactive
# at this instant, and it is what will bind the port after any restart.
# ------------------------------------------------------------------------------

SSH_SOCKET_MODE="N"

if [[ "$SSH_SOCKET_EXISTS" == "Y" ]]; then

    if systemctl is-active --quiet ssh.socket \
        || systemctl is-enabled --quiet ssh.socket 2>/dev/null; then

        SSH_SOCKET_MODE="Y"

    fi

fi

if [[ "$SSH_SOCKET_MODE" == "Y" ]]; then

    echo -e "${BLUE}[*] Socket-activated SSH detected.${NC}"

    # ORDER IS CRITICAL.
    #
    # With Accept=no socket activation, a running sshd has already INHERITED the
    # file descriptor systemd bound to port 22. Restarting ssh.socket while that
    # process is alive does not move the listener - the old fd stays open and SSH
    # keeps answering on 22. The service must be stopped FIRST, then the socket
    # started fresh so it binds the new port and hands down a new descriptor.

    echo -e "${BLUE}[*] Stopping ssh.service (releases the inherited port 22 socket)...${NC}"
    systemctl stop ssh.service 2>/dev/null || true

    echo -e "${BLUE}[*] Stopping ssh.socket...${NC}"
    systemctl stop ssh.socket 2>/dev/null || true

    echo -e "${BLUE}[*] Starting ssh.socket on port ${SSH_PORT}...${NC}"

    if ! systemctl start ssh.socket; then

        echo -e "${RED}[!] ssh.socket failed to start.${NC}"
        systemctl --no-pager --full status ssh.socket 2>/dev/null || true
        rollback_ssh
        exit 1

    fi

    systemctl enable ssh.socket >/dev/null 2>&1 || true

    echo -e "${BLUE}[*] Effective socket configuration:${NC}"
    systemctl cat ssh.socket 2>/dev/null \
        | grep -iE '^[[:space:]]*ListenStream' || true

else

    echo -e "${BLUE}[*] Using traditional SSH service activation...${NC}"

    if unit_exists ssh.service; then

        systemctl restart ssh.service

    elif unit_exists sshd.service; then

        systemctl restart sshd.service

    else

        echo -e "${RED}[!] Could not locate ssh.service or sshd.service.${NC}"
        rollback_ssh
        exit 1

    fi

fi

# ------------------------------------------------------------------------------
# Verify the requested SSH port is actually listening
# ------------------------------------------------------------------------------

PORT_IS_LISTENING="N"

for ATTEMPT in 1 2 3 4 5; do

    LISTENERS=$(ss -ltnH 2>/dev/null) || LISTENERS=""

    if awk -v port="$SSH_PORT" \
        '$4 ~ ":" port "$" { found = 1 } END { exit !found }' <<< "$LISTENERS"; then

        PORT_IS_LISTENING="Y"
        break

    fi

    sleep 1

done

if [[ "$PORT_IS_LISTENING" == "Y" ]]; then

    echo -e "${GREEN}[*] Verified: a TCP listener is active on port ${SSH_PORT}.${NC}"

    # SSH changes are applied and verified; the rollback window is closed.
    SSH_CHANGES_IN_FLIGHT="N"

    # A leftover listener on 22 means the old socket never released. Report it
    # rather than leaving a silent second entry point open.
    if [[ "$SSH_PORT" != "22" ]]; then

        LISTENERS=$(ss -ltnH 2>/dev/null) || LISTENERS=""

        if awk '$4 ~ /:22$/ { found = 1 } END { exit !found }' <<< "$LISTENERS"; then

            echo -e "${YELLOW}[!] Warning: something is STILL listening on port 22.${NC}"
            echo -e "${YELLOW}[!] Check for a stale sshd process or another sshd_config drop-in:${NC}"
            ss -ltnp 2>/dev/null | grep ':22 ' || true

        fi

    fi

else

    echo -e "${RED}[!] Nothing appears to be listening on SSH port ${SSH_PORT}.${NC}"
    echo ""
    echo -e "${YELLOW}ssh.socket status:${NC}"

    systemctl --no-pager --full status ssh.socket 2>/dev/null || true

    echo ""
    echo -e "${YELLOW}ssh.service status:${NC}"

    systemctl --no-pager --full status ssh.service 2>/dev/null || true

    echo ""
    echo -e "${YELLOW}Listening TCP sockets:${NC}"

    ss -ltnp || true

    rollback_ssh

    exit 1

fi

# ==============================================================================
# 9. Kernel Tuning & SWAP Creation
# ==============================================================================

echo -e "\n${BLUE}[6/9] Applying kernel network hardening & optimizations...${NC}"

cat <<EOF > /etc/sysctl.d/99-network-tuning.conf
# TCP SYN flood protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_synack_retries = 2

# Connection scaling & file limits
fs.file-max = 2097152
net.core.somaxconn = 65535

# TCP BBR congestion control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

sysctl --system >/dev/null

# ------------------------------------------------------------------------------
# SWAP
# ------------------------------------------------------------------------------

if [[ "$CONFIGURE_SWAP" =~ ^[Yy]$ ]]; then

    if [[ ! -f /swapfile ]] &&
       [[ -z "$(swapon --show --noheadings 2>/dev/null)" ]]; then

        echo -e "${BLUE}[*] Creating ${SWAP_SIZE_GB} GB swap file...${NC}"

        if ! fallocate -l "${SWAP_SIZE_GB}G" /swapfile; then

            echo -e "${YELLOW}[*] fallocate failed. Falling back to dd...${NC}"

            dd \
                if=/dev/zero \
                of=/swapfile \
                bs=1M \
                count=$(( SWAP_SIZE_GB * 1024 )) \
                status=progress

        fi

        chmod 600 /swapfile

        mkswap /swapfile
        swapon /swapfile

        if ! grep -qE '^/swapfile[[:space:]]' /etc/fstab; then
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
        fi

    else

        echo -e "${YELLOW}[*] SWAP is already configured. Skipping creation.${NC}"

    fi

fi

# ==============================================================================
# 10. Intrusion Prevention
# ==============================================================================

echo -e "\n${BLUE}[7/9] Configuring intrusion detection layer...${NC}"

# ------------------------------------------------------------------------------
# CrowdSec
# ------------------------------------------------------------------------------

if [[ "$SEC_CHOICE" == "1" || "$SEC_CHOICE" == "3" ]]; then

    echo -e "${GREEN}[*] Installing CrowdSec Security Engine + Firewall Bouncer...${NC}"

    curl -fsSL https://install.crowdsec.net | sh

    apt-get update -y
    apt-get install -y crowdsec

    if command -v nft >/dev/null 2>&1; then

        apt-get install -y crowdsec-firewall-bouncer-nftables

    else

        apt-get install -y crowdsec-firewall-bouncer-iptables

    fi

    cscli collections install crowdsecurity/linux || true
    cscli collections install crowdsecurity/sshd || true

    systemctl enable crowdsec
    systemctl restart crowdsec

fi

# ------------------------------------------------------------------------------
# Fail2Ban
# ------------------------------------------------------------------------------

if [[ "$SEC_CHOICE" == "2" || "$SEC_CHOICE" == "3" ]]; then

    echo -e "${GREEN}[*] Installing and configuring Fail2Ban...${NC}"

    apt-get install -y fail2ban

    cat <<EOF > /etc/fail2ban/jail.local
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 3

[sshd]
enabled = true
port = ${SSH_PORT}
backend = systemd
EOF

    systemctl enable fail2ban
    systemctl restart fail2ban

fi

if [[ "$SEC_CHOICE" == "4" ]]; then

    echo -e "${YELLOW}[*] Skipping intrusion detection setup.${NC}"

fi

# ==============================================================================
# 11. Unattended Security Patches
# ==============================================================================

echo -e "\n${BLUE}[8/9] Enabling automatic security upgrades...${NC}"

cat <<EOF > /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# ==============================================================================
# 12. Docker Installation
# ==============================================================================

if [[ "$INSTALL_DOCKER" =~ ^[Yy]$ ]]; then

    echo -e "\n${BLUE}[9/9] Installing Docker Engine & Docker Compose plugin...${NC}"

    curl -fsSL https://get.docker.com | sh

    if [[ "$CREATE_USER" == "Y" ]]; then
        usermod -aG docker "$NEW_USER"
    else
        echo -e "${YELLOW}[*] No new admin user; add users to the 'docker' group manually if needed.${NC}"
    fi

    systemctl enable docker
    systemctl start docker

else

    echo -e "\n${BLUE}[9/9] Docker installation skipped.${NC}"

fi

# ==============================================================================
# 13. Completion Summary
# ==============================================================================

SERVER_IP=$(
    curl -4fsS --max-time 5 https://ifconfig.me 2>/dev/null \
    || hostname -I | awk '{print $1}'
)

if [[ "$CREATE_USER" == "Y" ]]; then
    SSH_LOGIN_USER="$NEW_USER"
else
    SSH_LOGIN_USER="<your-user>"
fi

echo ""
echo -e "${GREEN}================================================================${NC}"
echo -e "${GREEN}             Server Setup & Hardening Complete!                 ${NC}"
echo -e "${GREEN}================================================================${NC}"
echo ""

echo -e "Connection & Access Details:"
echo ""
echo -e "  Hostname:        ${GREEN}$(hostname)${NC}"

if [[ "$CREATE_USER" == "Y" ]]; then
    echo -e "  Admin User:      ${GREEN}${NEW_USER}${NC}"
else
    echo -e "  Admin User:      ${YELLOW}None created (skipped)${NC}"
fi

echo -e "  SSH Port:        ${GREEN}${SSH_PORT}${NC}"

if [[ "$SSH_SOCKET_MODE" == "Y" ]]; then
    echo -e "  SSH Activation:  ${CYAN}systemd ssh.socket${NC}"
else
    echo -e "  SSH Activation:  ${CYAN}ssh.service (traditional)${NC}"
fi

if [[ "$CREATE_USER" == "Y" ]]; then
    echo -e "  Root Login:      ${RED}Disabled${NC}"
else
    echo -e "  Root Login:      ${YELLOW}Unchanged (${EFFECTIVE_ROOT_LOGIN:-unknown})${NC}"
fi

if [[ "$DISABLE_PASSWORD_AUTH" == "Y" ]]; then
    echo -e "  Password Auth:   ${RED}Disabled (SSH Key Only)${NC}"
else
    echo -e "  Password Auth:   ${YELLOW}Unchanged${NC}"
fi

if [[ "$ENABLE_WHITELIST" =~ ^[Yy]$ ]]; then

    echo -e "  SSH Firewall:    ${CYAN}Not publicly opened${NC}"
    echo -e "  Trusted Sources:"

    for SOURCE in "${TRUSTED_SOURCES[@]}"; do
        echo -e "                   ${GREEN}${SOURCE}${NC} (full inbound allow)"
    done

else

    echo -e "  SSH Firewall:    ${GREEN}TCP/${SSH_PORT} publicly allowed${NC}"

fi

if [[ "$CONFIGURE_SWAP" =~ ^[Yy]$ ]]; then
    echo -e "  SWAP Requested:  ${CYAN}${SWAP_SIZE_GB} GB${NC}"
fi

echo ""
echo -e "${YELLOW}Current UFW rules:${NC}"
ufw status numbered

echo ""
echo -e "${YELLOW}Current TCP listeners matching SSH port ${SSH_PORT}:${NC}"
ss -ltnp | grep -E ":${SSH_PORT}[[:space:]]" || true

echo ""
echo -e "${YELLOW}CRITICAL:${NC}"
echo -e "${YELLOW}Open a NEW terminal and verify SSH access before closing your current session.${NC}"
echo ""
echo -e "  ${BLUE}ssh -p ${SSH_PORT} ${SSH_LOGIN_USER}@${SERVER_IP}${NC}"
echo ""

if [[ "$ENABLE_WHITELIST" =~ ^[Yy]$ ]]; then

    echo -e "${RED}IMPORTANT:${NC}"
    echo -e "Your current public IP must match one of the trusted IP/CIDR entries."
    echo -e "SSH connections from every other source will be blocked by UFW."
    echo ""

fi

if [[ -f /var/run/reboot-required ]]; then

    echo -e "${YELLOW}[*] A reboot is required (e.g. new kernel). Reboot only AFTER confirming SSH access above.${NC}"
    echo ""

fi
