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

# Interface veth interne au namespace
VETH_NS="veth-n-$NS_NAME"

# Configuration NAT dans le namespace
ip netns exec $NS_NAME iptables -t nat -A POSTROUTING -s 10.6.0.0/24 -j MASQUERADE

# Configuration DNAT pour le port 80
ip netns exec $NS_NAME iptables -t nat -A PREROUTING -i tailscale-netns -p tcp --dport 80 -j DNAT --to-destination $ESP_IP:80

# Route vers l'ESP depuis le namespace
ip netns exec $NS_NAME ip route add $ESP_IP/32 dev $VETH_NS

# Route inverse sur l'hôte et route spécifique pour WireGuard
ip route replace $ESP_IP/32 dev wg0

# Autoriser le forwarding entre les interfaces
iptables -A FORWARD -i wg0 -o veth-h-$NS_NAME -j ACCEPT
iptables -A FORWARD -i veth-h-$NS_NAME -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT

# Règles de forwarding dans le namespace pour le port 80
ip netns exec $NS_NAME iptables -A FORWARD -i tailscale-netns -o veth-esp2 -p tcp --dport 80 -j ACCEPT
ip netns exec $NS_NAME iptables -A FORWARD -i veth-esp2 -o tailscale-netns -m state --state RELATED,ESTABLISHED -j ACCEPT

echo "Configuration du routage interne terminée pour $NS_NAME"

# MODIFICATION DE LA CONFIGURATION POUR QUE CA MARCHE SUR ORACLE VM
# sudo iptables -D INPUT -j REJECT --reject-with icmp-host-prohibited
# sudo iptables -A INPUT -p udp --dport 51820 -j ACCEPT
# sudo iptables -A INPUT -j REJECT --reject-with icmp-host-prohibited

# LIEN DIRECT ESP <-> wg0
# sudo ip route del 10.6.0.3
# sudo ip route add 10.6.0.3/32 dev wg0