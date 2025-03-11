#!/bin/bash

# Usage: ./run-tailscale-namespace.sh <namespace-name> <hostname> <authkey>

NS_NAME=$1
# ESP_ADDRESS=$2  # On commente cette ligne car on n'en a plus besoin
HOSTNAME=$2       # Était $3 avant
AUTHKEY=$3        # Était $4 avant

# Vérifications
if [ -z "$NS_NAME" ] || [ -z "$HOSTNAME" ] || [ -z "$AUTHKEY" ]; then
  echo "Usage: $0 <namespace-name> <hostname> <authkey>"
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
  --accept-routes=true
# --advertise-routes="$ESP_ADDRESS/32" \  # On commente cette ligne

echo "Tailscale démarré dans l'espace de noms $NS_NAME"
