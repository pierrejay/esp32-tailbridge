#!/bin/bash
# Usage: ./setup-internal-routing.sh <namespace-name> <esp_ip>

NS_NAME=$1
ESP_IP=$2

if [ -z "$NS_NAME" ] || [ -z "$ESP_IP" ]; then
  echo "Usage: $0 <namespace-name> <esp_ip>"
  exit 1
fi

# Extraire l'index du nom du namespace
INDEX=${NS_NAME#esp}

# Noms corrects des interfaces
VETH_NS="veth-$NS_NAME"
VETH_HOST="veth-h-$NS_NAME"

echo "Configuration de routage pour $NS_NAME avec ESP IP $ESP_IP"
echo "Interfaces: $VETH_NS (namespace) et $VETH_HOST (hôte)"

# Vérifier que les interfaces existent
if ! ip link show $VETH_HOST &>/dev/null; then
  echo "ERREUR: L'interface $VETH_HOST n'existe pas dans l'hôte"
  exit 1
fi

if ! ip netns exec $NS_NAME ip link show $VETH_NS &>/dev/null; then
  echo "ERREUR: L'interface $VETH_NS n'existe pas dans le namespace $NS_NAME"
  exit 1
fi

# Configuration NAT dans le namespace
ip netns exec $NS_NAME iptables -t nat -A POSTROUTING -s 10.6.0.0/24 -j MASQUERADE

# Configuration DNAT pour le port 80
ip netns exec $NS_NAME iptables -t nat -A PREROUTING -i tailscale-netns -p tcp --dport 80 -j DNAT --to-destination $ESP_IP:80

# Route vers l'ESP depuis le namespace
ip netns exec $NS_NAME ip route add $ESP_IP/32 via 10.100.$INDEX.1

# Route inverse sur l'hôte (normalement pas nécessaire)
# ip route replace $ESP_IP/32 dev wg0

# Autoriser le forwarding entre les interfaces
iptables -A FORWARD -i wg0 -o $VETH_HOST -j ACCEPT
iptables -A FORWARD -i $VETH_HOST -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT

# Règles de forwarding dans le namespace pour le port 80
ip netns exec $NS_NAME iptables -A FORWARD -i tailscale-netns -o $VETH_NS -p tcp --dport 80 -j ACCEPT
ip netns exec $NS_NAME iptables -A FORWARD -i $VETH_NS -o tailscale-netns -m state --state RELATED,ESTABLISHED -j ACCEPT

echo "Configuration du routage interne terminée pour $NS_NAME"