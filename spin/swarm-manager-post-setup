#!/bin/bash

echo "This script should only be ran on manager nodes that are being used in a cluster. Continuing in 10 seconds..."
echo ""
sleep 10

# Prompt for the private IP range
read -p "Enter the private IP range (e.g., 10.0.0.0/16): " private_ip_range

# Configure UFW firewall rules
echo "Configuring UFW firewall rules..."
sudo ufw allow 22/tcp
sudo ufw allow from $private_ip_range to any port 2377 proto tcp
sudo ufw allow from $private_ip_range to any port 7946 proto tcp
sudo ufw allow from $private_ip_range to any port 7946 proto udp
sudo ufw allow from $private_ip_range to any port 4789 proto udp
echo ""

echo "Post setup completed successfully. Unless this is the first manager node, you can now run the following to add this node to a Docker Swarm cluster."
echo "sudo -u admin bash /tmp/join-swarm-cluster.sh"
