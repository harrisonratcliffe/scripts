#!/bin/bash

echo "Starting the process to set up the Docker environment..."
echo ""

# Update the package list
echo "Updating package list..."
sudo apt update
echo ""

# Install necessary packages
echo "Installing necessary packages: apt-transport-https, ca-certificates, curl, software-properties-common..."
sudo apt install -y apt-transport-https ca-certificates curl software-properties-common
echo ""

# Add Docker's official GPG key
echo "Adding Docker's official GPG key..."
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo ""

# Set up the Docker repository
echo "Setting up the Docker repository..."
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
echo ""

# Update the package list again after adding Docker's repository
echo "Updating package list again to include Docker repository..."
sudo apt update
echo ""

# Install Docker
echo "Installing Docker..."
sudo apt install -y docker-ce
echo ""

# Check if Docker is installed
echo "Checking if Docker is installed..."
if ! sudo systemctl status docker > /dev/null; then
    echo "Docker installation failed. Exiting script."
    exit 1
else
    echo "Docker is installed successfully."
fi
echo ""

# Check if the 'docker' group exists, create if it doesn't
if ! getent group docker > /dev/null; then
    echo "Group 'docker' does not exist. Creating group 'docker'..."
    sudo groupadd docker
else
    echo "Group 'docker' already exists, continuing..."
fi
echo ""

# Check if user 'admin' exists using id -u
if id -u admin >/dev/null 2>&1; then
    echo "User 'admin' exists. Adding to the docker group..."
    sudo usermod -aG docker admin
else
    echo "User 'admin' does not exist. Creating user 'admin'..."
    sudo useradd -m -s /bin/bash -G docker admin
fi
echo ""

# Download the join swarm script to /tmp
echo "Downloading the join swarm script to /tmp..."
curl -o /tmp/join-swarm-cluster.sh https://scripts.hcloud.uk/spin/join-swarm-cluster.sh
echo ""

echo "Process completed successfully. You can now run the following to add this node to a Docker Swarm cluster."
echo "sudo -u admin sh /tmp/join-swarm-cluster.sh"
echo ""

# Echo the admin user at the end
echo "The admin user is 'admin'."
