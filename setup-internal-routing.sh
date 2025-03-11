#!/bin/bash
# Usage: ./setup-internal-routing.sh <namespace-name> <esp_ip>

NS_NAME=$1
ESP_IP=$2

if [ -z "$NS_NAME" ] || [ -z "$ESP_IP" ]; then
  echo "Usage: $0 <namespace-name> <esp_ip>"
  exit 1
fi

# Les noms d'interfaces doivent être plus courts (max 15 caractères)
# Au lieu de "netns0-host-esp2" et "netns0-esp2", utilisons :
VETH_HOST="veth0-h-$NS_NAME"  # ex: veth0-h-esp2
VETH_NS="veth0-n-$NS_NAME"    # ex: veth0-n-esp2

# Créer la paire veth
ip link add name $VETH_HOST type veth peer name $VETH_NS
ip link set $VETH_HOST up
ip link set $VETH_NS netns $NS_NAME

# Configuration des adresses
ip addr add 10.6.1.1/24 dev $VETH_HOST
ip netns exec $NS_NAME ip link set $VETH_NS up
ip netns exec $NS_NAME ip addr add 10.6.1.2/24 dev $VETH_NS

# Routes
ip route add $ESP_IP via 10.6.1.2
ip netns exec $NS_NAME ip route add 10.6.0.0/24 via 10.6.1.1

# Configuration du NAT dans le namespace pour Tailscale
ip netns exec $NS_NAME iptables -t nat -A POSTROUTING -o tailscale0 -j MASQUERADE
ip netns exec $NS_NAME iptables -A FORWARD -i $VETH_NS -o tailscale0 -j ACCEPT
ip netns exec $NS_NAME iptables -A FORWARD -i tailscale0 -o $VETH_NS -m state --state RELATED,ESTABLISHED -j ACCEPT

echo "Configuration du routage interne terminée pour $NS_NAME" 

# MODIFICATION DE LA CONFIGURATION POUR QUE CA MARCHE SUR ORACLE VM
# sudo iptables -D INPUT -j REJECT --reject-with icmp-host-prohibited
# sudo iptables -A INPUT -p udp --dport 51820 -j ACCEPT
# sudo iptables -A INPUT -j REJECT --reject-with icmp-host-prohibited

# LIEN DIRECT ESP <-> wg0
# sudo ip route del 10.6.0.3
# sudo ip route add 10.6.0.3/32 dev wg0