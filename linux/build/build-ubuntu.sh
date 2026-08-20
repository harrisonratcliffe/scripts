#!/usr/bin/env bash

# ==============================================================================
# Script: build-ubuntu.sh
# Production Server Provisioning & Hardening Wizard
# Target OS: Ubuntu 22.04 / 24.04 LTS & Debian 11 / 12
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Root check
# ------------------------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo "[!] This script must be run as root."
    exit 1
fi

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
# 1.2 Non-root Admin Username
# ------------------------------------------------------------------------------

while true; do
    read -rp "Enter new administrative username (e.g. deployer): " NEW_USER

    if [[ -n "$NEW_USER" && ! "$NEW_USER" =~ [^a-z0-9_-] ]]; then
        break
    fi

    echo -e "${RED}[!] Invalid username. Use lowercase letters, numbers, hyphens, or underscores.${NC}"
done

# ------------------------------------------------------------------------------
# 1.3 SSH Public Key Input
# ------------------------------------------------------------------------------

echo ""
echo -e "${YELLOW}Paste your public SSH key (e.g. ssh-ed25519 AAAA...):${NC}"

read -rp "SSH Key: " USER_SSH_KEY

while [[ -z "$USER_SSH_KEY" ]]; do
    echo -e "${RED}[!] An SSH key is required because password authentication will be disabled.${NC}"
    read -rp "SSH Key: " USER_SSH_KEY
done

# ------------------------------------------------------------------------------
# 1.4 SSH Port Setup
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
# 1.5 Trusted IP / CIDR Whitelist
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
# 1.6 Dynamic SWAP Calculator
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
# 1.7 Security Layer Selection
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
# 1.8 Docker Engine Installation
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
echo "  Admin user:       ${NEW_USER}"
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

echo -e "\n${BLUE}[1/8] Updating package index and installing essentials...${NC}"

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

# Enable network time synchronization
timedatectl set-ntp true

# ==============================================================================
# 3. Validate Trusted Firewall Sources
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
# 4. User Provisioning & Passwordless Sudo
# ==============================================================================

echo -e "\n${BLUE}[2/8] Provisioning user '${NEW_USER}' with passwordless sudo...${NC}"

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

# ==============================================================================
# 5. Prepare SSH Hardening Configuration
# ==============================================================================

echo -e "\n${BLUE}[3/8] Preparing SSH hardening on port ${SSH_PORT}...${NC}"

SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"
SSH_SOCKET_DROPIN_DIR="/etc/systemd/system/ssh.socket.d"

mkdir -p "$SSHD_DROPIN_DIR"

cat <<EOF > "${SSHD_DROPIN_DIR}/99-hardening.conf"
Port ${SSH_PORT}
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
X11Forwarding no
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

# Validate sshd configuration BEFORE firewall/socket changes
if ! sshd -t; then

    echo -e "${RED}[!] SSH syntax check failed.${NC}"
    echo -e "${RED}[!] Removing hardening configuration to prevent lockout.${NC}"

    rm -f "${SSHD_DROPIN_DIR}/99-hardening.conf"

    exit 1

fi

echo -e "${GREEN}[*] OpenSSH configuration syntax is valid.${NC}"

# ------------------------------------------------------------------------------
# Configure systemd ssh.socket when the unit exists.
#
# Ubuntu 24.04 commonly uses socket-activated SSH. In that configuration,
# changing "Port" in sshd_config alone may not move the actual listening
# socket.
#
# Equivalent to:
#
#   systemctl edit ssh.socket
#
#   [Socket]
#   ListenStream=
#   ListenStream=0.0.0.0:922
#   ListenStream=[::]:922
# ------------------------------------------------------------------------------

SSH_SOCKET_EXISTS="N"

if systemctl list-unit-files ssh.socket --no-legend 2>/dev/null \
    | awk '{print $1}' \
    | grep -qx 'ssh.socket'; then

    SSH_SOCKET_EXISTS="Y"

    echo -e "${BLUE}[*] ssh.socket detected. Creating socket listener override...${NC}"

    mkdir -p "$SSH_SOCKET_DROPIN_DIR"

    cat <<EOF > "${SSH_SOCKET_DROPIN_DIR}/99-listen.conf"
[Socket]
ListenStream=
ListenStream=0.0.0.0:${SSH_PORT}
ListenStream=[::]:${SSH_PORT}
EOF

else

    echo -e "${YELLOW}[*] ssh.socket is not installed. Traditional ssh.service mode will be used.${NC}"

fi

# ==============================================================================
# 6. UFW Firewall Setup
# ==============================================================================

echo -e "\n${BLUE}[4/8] Configuring UFW firewall rules...${NC}"

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
# 7. Apply SSH Socket / Service Changes
# ==============================================================================

echo -e "\n${BLUE}[*] Applying SSH listener configuration...${NC}"

# Required after adding/changing systemd unit drop-ins
systemctl daemon-reload

if [[ "$SSH_SOCKET_EXISTS" == "Y" ]] &&
   systemctl is-active --quiet ssh.socket; then

    echo -e "${BLUE}[*] Active ssh.socket detected.${NC}"
    echo -e "${BLUE}[*] Restarting SSH socket on port ${SSH_PORT}...${NC}"

    systemctl restart ssh.socket

    # A currently running ssh.service may still have inherited the previous
    # socket descriptor. Restart it so it receives the newly configured socket.
    if systemctl is-active --quiet ssh.service; then

        echo -e "${BLUE}[*] Restarting active ssh.service...${NC}"
        systemctl restart ssh.service

    fi

else

    echo -e "${BLUE}[*] Using traditional SSH service activation...${NC}"

    if systemctl list-unit-files ssh.service --no-legend 2>/dev/null \
        | awk '{print $1}' \
        | grep -qx 'ssh.service'; then

        systemctl restart ssh.service

    elif systemctl list-unit-files sshd.service --no-legend 2>/dev/null \
        | awk '{print $1}' \
        | grep -qx 'sshd.service'; then

        systemctl restart sshd.service

    else

        echo -e "${RED}[!] Could not locate ssh.service or sshd.service.${NC}"
        exit 1

    fi

fi

# ------------------------------------------------------------------------------
# Verify requested SSH port is actually listening
# ------------------------------------------------------------------------------

sleep 1

if ss -ltnH | awk -v port="$SSH_PORT" \
    '$4 ~ ":" port "$" { found=1 } END { exit !found }'; then

    echo -e "${GREEN}[*] Verified: a TCP listener is active on port ${SSH_PORT}.${NC}"

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

    exit 1

fi

# ==============================================================================
# 8. Kernel Tuning & SWAP Creation
# ==============================================================================

echo -e "\n${BLUE}[5/8] Applying kernel network hardening & optimizations...${NC}"

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
# 9. Intrusion Prevention
# ==============================================================================

echo -e "\n${BLUE}[6/8] Configuring intrusion detection layer...${NC}"

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
# 10. Unattended Security Patches
# ==============================================================================

echo -e "\n${BLUE}[7/8] Enabling automatic security upgrades...${NC}"

cat <<EOF > /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# ==============================================================================
# 11. Docker Installation
# ==============================================================================

if [[ "$INSTALL_DOCKER" =~ ^[Yy]$ ]]; then

    echo -e "\n${BLUE}[8/8] Installing Docker Engine & Docker Compose plugin...${NC}"

    curl -fsSL https://get.docker.com | sh

    usermod -aG docker "$NEW_USER"

    systemctl enable docker
    systemctl start docker

else

    echo -e "\n${BLUE}[8/8] Docker installation skipped.${NC}"

fi

# ==============================================================================
# 12. Completion Summary
# ==============================================================================

SERVER_IP=$(
    curl -4fsS --max-time 5 https://ifconfig.me 2>/dev/null \
    || hostname -I | awk '{print $1}'
)

echo ""
echo -e "${GREEN}================================================================${NC}"
echo -e "${GREEN}             Server Setup & Hardening Complete!                 ${NC}"
echo -e "${GREEN}================================================================${NC}"
echo ""

echo -e "Connection & Access Details:"
echo ""
echo -e "  Admin User:      ${GREEN}${NEW_USER}${NC}"
echo -e "  SSH Port:        ${GREEN}${SSH_PORT}${NC}"
echo -e "  Root Login:      ${RED}Disabled${NC}"
echo -e "  Password Auth:   ${RED}Disabled (SSH Key Only)${NC}"

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
echo -e "  ${BLUE}ssh -p ${SSH_PORT} ${NEW_USER}@${SERVER_IP}${NC}"
echo ""

if [[ "$ENABLE_WHITELIST" =~ ^[Yy]$ ]]; then

    echo -e "${RED}IMPORTANT:${NC}"
    echo -e "Your current public IP must match one of the trusted IP/CIDR entries."
    echo -e "SSH connections from every other source will be blocked by UFW."
    echo ""

fi
