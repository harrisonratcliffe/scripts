#!/bin/bash

PORT=22
API_URL="https://api.github.com/meta"

# Fetch the 'actions' IPs from the GitHub API and loop through them
curl -s "$API_URL" | jq -r '.actions[]' | while read ip; do
    # Allow from this IP to the specific port
    echo "Allowing $ip on port $PORT"
    sudo ufw allow from $ip to any port $PORT
done

# Reload UFW to apply rules
sudo ufw reload
