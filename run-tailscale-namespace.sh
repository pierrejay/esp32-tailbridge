#!/bin/bash

# Usage: ./run-tailscale-namespace.sh <namespace-name> <hostname> <authkey>

NS_NAME=$1
HOSTNAME=$2
AUTHKEY=$3

# Checks
if [ -z "$NS_NAME" ] || [ -z "$HOSTNAME" ] || [ -z "$AUTHKEY" ]; then
  echo "Usage: $0 <namespace-name> <hostname> <authkey>"
  exit 1
fi

# Create a unique state directory
mkdir -p /var/lib/tailscale-$NS_NAME

# Start Tailscale in the isolated namespace
ip netns exec $NS_NAME tailscaled \
  --state=/var/lib/tailscale-$NS_NAME/state.json \
  --socket=/var/run/tailscale-$NS_NAME.sock \
  --tun=tailscale-netns &

sleep 2

# Authenticate with the key
ip netns exec $NS_NAME tailscale \
  --socket=/var/run/tailscale-$NS_NAME.sock up \
  --authkey="$AUTHKEY" \
  --hostname="$HOSTNAME" \
  --advertise-routes=10.6.0.0/24 \
  --accept-routes

echo "Tailscale started in the namespace $NS_NAME"
