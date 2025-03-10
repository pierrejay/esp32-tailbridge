#!/bin/bash
# Usage: ./setup-internal-routing.sh <namespace-name> <esp_ip>

NS_NAME=$1
ESP_IP=$2

if [ -z "$NS_NAME" ] || [ -z "$ESP_IP" ]; then
  echo "Usage: $0 <namespace-name> <esp_ip>"
  exit 1
fi

# Créer un veth pair pour relier l'hôte au namespace
ip link add netns0-$NS_NAME type veth peer name netns0-host-$NS_NAME
ip link set netns0-host-$NS_NAME up
ip link set netns0-$NS_NAME netns $NS_NAME

# Configuration dans le namespace
ip netns exec $NS_NAME ip link set netns0-$NS_NAME up
ip netns exec $NS_NAME ip addr add 10.200.0.2/24 dev netns0-$NS_NAME

# Configuration sur l'hôte
ip addr add 10.200.0.1/24 dev netns0-host-$NS_NAME

# Ajouter les routes nécessaires
ip route add $ESP_IP/32 via 10.200.0.2

# Configuration du NAT dans le namespace pour Tailscale
ip netns exec $NS_NAME iptables -t nat -A POSTROUTING -o tailscale0 -j MASQUERADE
ip netns exec $NS_NAME iptables -A FORWARD -i netns0-$NS_NAME -o tailscale0 -j ACCEPT
ip netns exec $NS_NAME iptables -A FORWARD -i tailscale0 -o netns0-$NS_NAME -m state --state RELATED,ESTABLISHED -j ACCEPT

echo "Configuration du routage interne terminée pour $NS_NAME" 