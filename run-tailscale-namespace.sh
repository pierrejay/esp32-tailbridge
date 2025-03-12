#!/bin/bash

# Usage: ./run-tailscale-namespace.sh <namespace-name> <hostname> <authkey>

NS_NAME=$1
HOSTNAME=$2
AUTHKEY=$3

# Vérifications
if [ -z "$NS_NAME" ] || [ -z "$HOSTNAME" ] || [ -z "$AUTHKEY" ]; then
  echo "Usage: $0 <namespace-name> <hostname> <authkey>"
  exit 1
fi

# Créer répertoire d'état unique
mkdir -p /var/lib/tailscale-$NS_NAME

# Démarrer Tailscale dans l'espace de noms isolé
ip netns exec $NS_NAME tailscaled \
  --state=/var/lib/tailscale-$NS_NAME/state.json \
  --socket=/var/run/tailscale-$NS_NAME.sock \
  --tun=tailscale-netns &

sleep 2

# Authentifier avec la clé
ip netns exec $NS_NAME tailscale \
  --socket=/var/run/tailscale-$NS_NAME.sock up \
  --authkey="$AUTHKEY" \
  --hostname="$HOSTNAME" \
  --advertise-routes=10.6.0.0/24 \
  --accept-routes

echo "Tailscale démarré dans l'espace de noms $NS_NAME"
