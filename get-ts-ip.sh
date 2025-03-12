#!/bin/bash
# Usage: ./get-ts-ip.sh <esp_name>

if [ -z "$1" ]; then
    echo "Usage: $0 <esp_name>"
    exit 1
fi

# Extraire le numéro du namespace à partir du nom
ESP_NAME=$1
NS_NUM=${ESP_NAME#esp}
NS_NAME="esp$NS_NUM"

# Vérifier que le namespace existe
if ! ip netns list | grep -q "^$NS_NAME"; then
    echo "Erreur: Le namespace $NS_NAME n'existe pas"
    exit 1
fi

# Vérifier que le socket existe
if [ ! -e "/var/run/tailscale-$NS_NAME.sock" ]; then
    echo "Erreur: Le socket Tailscale pour $NS_NAME n'existe pas"
    exit 1
fi

# Obtenir le statut Tailscale
echo "Statut Tailscale pour $ESP_NAME ($NS_NAME):"
STATUS=$(ip netns exec $NS_NAME tailscale --socket=/var/run/tailscale-$NS_NAME.sock status)
echo "$STATUS"

# Extraire l'IP Tailscale (100.x.y.z)
TS_IP=$(echo "$STATUS" | grep -oE '100\.[0-9]+\.[0-9]+\.[0-9]+')
if [ ! -z "$TS_IP" ]; then
    echo -e "\nIP Tailscale: $TS_IP"
fi 