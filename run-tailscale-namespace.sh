#!/bin/bash

# Usage: ./run-tailscale-namespace.sh <namespace-name> <esp-address> <hostname> <authkey>

NS_NAME=$1
ESP_ADDRESS=$2
HOSTNAME=$3
AUTHKEY=$4

# Vérifications
if [ -z "$NS_NAME" ] || [ -z "$ESP_ADDRESS" ] || [ -z "$HOSTNAME" ] || [ -z "$AUTHKEY" ]; then
  echo "Usage: $0 <namespace-name> <esp-address> <hostname> <authkey>"
  exit 1
fi

# Créer répertoire d'état unique
mkdir -p /var/lib/tailscale-$NS_NAME

# Démarrer Tailscale dans l'espace de noms isolé
# IMPORTANT: utiliser --tun=userspace-networking pour éviter les conflits d'interface
ip netns exec $NS_NAME tailscaled \
  --tun=userspace-networking \
  --state=/var/lib/tailscale-$NS_NAME/state.json \
  --socket=/var/run/tailscale-$NS_NAME.sock &

sleep 2

# Authentifier avec la clé
ip netns exec $NS_NAME tailscale \
  --socket=/var/run/tailscale-$NS_NAME.sock up \
  --authkey="$AUTHKEY" \
  --hostname="$HOSTNAME" \
  --advertise-routes="$ESP_ADDRESS/32" \
  --accept-routes

echo "Tailscale démarré dans l'espace de noms $NS_NAME"
