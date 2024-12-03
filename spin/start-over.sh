#!/bin/bash

# Cleanup Docker Environment

# Remove all services
echo "Removing all Docker services..."
sudo docker service rm $(sudo docker service ls -q)

# Stop all containers
echo "Stopping all Docker containers..."
sudo docker stop $(sudo docker ps -aq)

# Remove all containers
echo "Removing all Docker containers..."
sudo docker rm $(sudo docker ps -aq)

# Remove all unused images and networks
echo "Removing all unused images and networks..."
sudo docker system prune --all -f

# Remove all volumes
echo "Removing all Docker volumes..."
sudo docker volume rm $(sudo docker volume ls -q)

# Remove all configurations
echo "Removing all Docker configurations..."
sudo docker config rm $(sudo docker config ls -q)

echo "Docker cleanup completed."