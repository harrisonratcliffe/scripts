#!/bin/bash

# Prompt for necessary variables
read -p "Enter the Manager IP Address: " MANAGER_IP
read -p "Should this node be a master (y/n)? " IS_MASTER

# Ask for the Swarm cluster token based on the node type
if [[ "$IS_MASTER" == "y" || "$IS_MASTER" == "Y" ]]; then
    read -p "Enter the Swarm cluster token (you can get the token from the manager with 'docker swarm join-token manager'): " SWARM_TOKEN
else
    read -p "Enter the Swarm cluster token (you can get the token from the manager with 'docker swarm join-token worker'): " SWARM_TOKEN
fi

echo "Starting the process to add this node to the Docker Swarm cluster..."
echo ""

# Add the node to the Docker Swarm
if [[ "$IS_MASTER" == "y" || "$IS_MASTER" == "Y" ]]; then
    echo "This node will be added as a master..."
    sudo docker swarm join --advertise-addr $MANAGER_IP:2377 --token $SWARM_TOKEN
else
    echo "This node will be added as a worker..."
    sudo docker swarm join --token $SWARM_TOKEN $MANAGER_IP:2377
fi

echo "Node has been added to the Docker Swarm cluster."
echo ""
echo "You can delete the join script with: rm /tmp/join-swarm-cluster.sh"
