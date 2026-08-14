#!/usr/bin/env bash

# ==============================================================================
# Script: build-ubuntu.sh
# Production Server Provisioning & Hardening Wizard
# Target OS: Ubuntu 22.04 / 24.04 (LTS) & Debian 11 / 12
# ==============================================================================

set -euo pipefail

# Ensure script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "[!] This script must be run as root."
   exit 1
fi

# Terminal colors
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

# ------------------------------------------------------------------------------
# 1. Interactive Configuration Wizard
# ------------------------------------------------------------------------------

# 1.1 Full System Package Upgrade
read -rp "Run full 'apt update && apt upgrade -y'? [Y/n]: " DO_UPGRADE
DO_UPGRADE=${DO_UPGRADE:-Y}

# 1.2 Non-root Admin Username
while true; do
    read -rp "Enter new administrative username (e.g. deployer): " NEW_USER
    if [[ -n "$NEW_USER" && ! "$NEW_USER" =~ [^a-z0-9_-] ]]; then
        break
    else
        echo -e "${RED}[!] Invalid username. Use lowercase letters, numbers, hyphens, or underscores.${NC}"
    fi
done

# 1.3 SSH Public Key Input
echo ""
echo -e "${YELLOW}Paste your public SSH key (e.g. ssh-ed25519 AAAA... or ssh-rsa AAAA...):${NC}"
read -rp "SSH Key: " USER_SSH_KEY
while [[ -z "$USER_SSH_KEY" ]]; do
    echo -e "${RED}[!] An SSH key is required since password authentication will be disabled.${NC}"
    read -rp "SSH Key: " USER_SSH_KEY
done

# 1.4 SSH Port Setup
echo ""
read -rp "Change default SSH port 22? [Y/n]: " CHANGE_SSH
CHANGE_SSH=${CHANGE_SSH:-Y}
if [[ "$CHANGE_SSH" =~ ^[Yy]$ ]]; then
    read -rp "Enter SSH port [Default: 922]: " SSH_PORT
    SSH_PORT=${SSH_PORT:-922}
else
    SSH_PORT=22
fi

# 1.5 Dynamic SWAP Calculator & Override
echo ""
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_GB=$(awk -v ram="$TOTAL_RAM_KB" 'BEGIN {print int((ram / 1024 / 1024) + 0.999)}')

# Standard production swap scaling rule
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
    read -rp "SWAP size in GB [Auto-calculated recommendation: ${REC_SWAP}G] (Press Enter to accept or type custom number): " CUSTOM_SWAP
    if [[ -n "$CUSTOM_SWAP" && "$CUSTOM_SWAP" =~ ^[0-9]+$ ]]; then
        SWAP_SIZE_GB=$CUSTOM_SWAP
    fi
fi

# 1.6 Security Layer Selection
echo ""
echo "Select intrusion detection layer:"
echo "  1) CrowdSec + Firewall Bouncer (Recommended)"
echo "  2) Fail2Ban"
echo "  3) Both (CrowdSec + Fail2Ban)"
echo "  4) None / Skip"
read -rp "Choice [1-4, Default: 1]: " SEC_CHOICE
SEC_CHOICE=${SEC_CHOICE:-1}

# 1.7 Docker Engine Installation
echo ""
read -rp "Install Docker Engine & Docker Compose plugin? [Y/n]: " INSTALL_DOCKER
INSTALL_DOCKER=${INSTALL_DOCKER:-Y}

echo ""
echo -e "${GREEN}Configuration captured! Beginning deployment...${NC}"
sleep 2

# ------------------------------------------------------------------------------
# 2. Base System Updates & Essential Packages
# ------------------------------------------------------------------------------
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
    systemd-timesyncd

# Enable network time synchronization
timedatectl set-ntp true

# ------------------------------------------------------------------------------
# 3. User Provisioning & Passwordless Sudo
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}[2/8] Provisioning user '${NEW_USER}' with passwordless sudo...${NC}"

if id "$NEW_USER" &>/dev/null; then
    echo -e "${YELLOW}[*] User ${NEW_USER} already exists. Ensuring sudo and SSH access...${NC}"
else
    adduser --disabled-password --gecos "" "$NEW_USER"
fi

usermod -aG sudo "$NEW_USER"

# Configure passwordless sudo
echo "$NEW_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-${NEW_USER}-init"
chmod 0440 "/etc/sudoers.d/90-${NEW_USER}-init"

# Deploy authorized SSH keys
USER_SSH_DIR="/home/${NEW_USER}/.ssh"
mkdir -p "$USER_SSH_DIR"
echo "$USER_SSH_KEY" > "${USER_SSH_DIR}/authorized_keys"
chmod 700 "$USER_SSH_DIR"
chmod 600 "${USER_SSH_DIR}/authorized_keys"
chown -R "${NEW_USER}:${NEW_USER}" "$USER_SSH_DIR"

# ------------------------------------------------------------------------------
# 4. SSH Daemon Hardening
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}[3/8] Hardening SSH (Port ${SSH_PORT}, no root, keys only)...${NC}"

SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"
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

# Validate SSH configuration syntax before applying
if sshd -t; then
    systemctl restart ssh || systemctl restart sshd
else
    echo -e "${RED}[!] SSH syntax check failed. Reverting drop-in config to prevent lockout...${NC}"
    rm -f "${SSHD_DROPIN_DIR}/99-hardening.conf"
    exit 1
fi

# ------------------------------------------------------------------------------
# 5. UFW Firewall Setup
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}[4/8] Configuring UFW firewall rules...${NC}"

ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# Allow custom SSH and Web traffic
ufw allow "${SSH_PORT}/tcp" comment 'Custom SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'

# Enable firewall non-interactively
echo "y" | ufw enable
ufw status verbose

# ------------------------------------------------------------------------------
# 6. Kernel Tuning & SWAP Creation
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}[5/8] Applying kernel network hardening & optimizations...${NC}"

cat <<EOF > /etc/sysctl.d/99-network-tuning.conf
# TCP SYN Flood Protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_synack_retries = 2

# Connection scaling & file limits
fs.file-max = 2097152
net.core.somaxconn = 65535

# TCP BBR Congestion Control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

sysctl --system > /dev/null

if [[ "$CONFIGURE_SWAP" =~ ^[Yy]$ ]]; then
    if [ ! -f /swapfile ] && [ "$(swapon --show | wc -l)" -le 1 ]; then
        echo -e "${BLUE}[*] Creating ${SWAP_SIZE_GB} GB swap file...${NC}"
        fallocate -l "${SWAP_SIZE_GB}G" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=$(( SWAP_SIZE_GB * 1024 ))
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    else
        echo -e "${YELLOW}[*] SWAP already configured on this system. Skipping creation.${NC}"
    fi
fi

# ------------------------------------------------------------------------------
# 7. Intrusion Prevention (CrowdSec / Fail2Ban)
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}[6/8] Configuring intrusion detection layer...${NC}"

if [[ "$SEC_CHOICE" == "1" || "$SEC_CHOICE" == "3" ]]; then
    echo -e "${GREEN}[*] Installing CrowdSec Security Engine + Firewall Bouncer...${NC}"
    curl -s https://install.crowdsec.net | sh
    apt-get update -y
    apt-get install -y crowdsec
    
    if command -v nft &> /dev/null; then
        apt-get install -y crowdsec-firewall-bouncer-nftables
    else
        apt-get install -y crowdsec-firewall-bouncer-iptables
    fi

    cscli collections install crowdsecurity/linux
    cscli collections install crowdsecurity/sshd
    systemctl restart crowdsec
fi

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

# ------------------------------------------------------------------------------
# 8. Unattended Security Patches
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}[7/8] Enabling automatic security upgrades...${NC}"

cat <<EOF > /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# ------------------------------------------------------------------------------
# 9. Docker Installation (Optional)
# ------------------------------------------------------------------------------
if [[ "$INSTALL_DOCKER" =~ ^[Yy]$ ]]; then
    echo -e "\n${BLUE}[8/8] Installing Docker Engine & Compose plugin...${NC}"
    curl -fsSL https://get.docker.com | sh
    usermod -aG docker "$NEW_USER"
    systemctl enable docker
fi

# ------------------------------------------------------------------------------
# Completion Summary
# ------------------------------------------------------------------------------
SERVER_IP=$(curl -4s https://ifconfig.me || hostname -I | awk '{print $1}')

echo ""
echo -e "${GREEN}================================================================${NC}"
echo -e "${GREEN}             Server Setup & Hardening Complete!                 ${NC}"
echo -e "${GREEN}================================================================${NC}"
echo ""
echo -e "Connection & Access Details:"
echo -e "  Admin User:     ${GREEN}${NEW_USER}${NC}"
echo -e "  SSH Port:       ${GREEN}${SSH_PORT}${NC}"
echo -e "  Root Login:     ${RED}Disabled${NC}"
echo -e "  Password Auth:  ${RED}Disabled (SSH Key Only)${NC}"
if [[ "$CONFIGURE_SWAP" =~ ^[Yy]$ ]]; then
    echo -e "  SWAP Space:     ${CYAN}${SWAP_SIZE_GB} GB Active${NC}"
fi
echo ""
echo -e "${YELLOW}CRITICAL: Open a NEW terminal window to verify SSH access before exiting:${NC}"
echo -e "  ${BLUE}ssh -p ${SSH_PORT} ${NEW_USER}@${SERVER_IP}${NC}"
echo ""
