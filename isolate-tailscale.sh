#!/bin/bash

# Usage: ./isolate-tailscale.sh <namespace-name> <index>

NS_NAME=$1
INDEX=$2

# Créer l'espace de noms
ip netns add $NS_NAME

# Créer les interfaces veth
ip link add veth-$NS_NAME type veth peer name veth-host-$NS_NAME
ip link set veth-host-$NS_NAME up
ip link set veth-$NS_NAME netns $NS_NAME

# Configuration dans l'espace de noms
ip netns exec $NS_NAME ip link set lo up
ip netns exec $NS_NAME ip link set veth-$NS_NAME up
ip netns exec $NS_NAME ip addr add 10.100.$INDEX.2/24 dev veth-$NS_NAME

# Configuration sur l'hôte
ip addr add 10.100.$INDEX.1/24 dev veth-host-$NS_NAME

# Configuration DNS
mkdir -p /etc/netns/$NS_NAME
cp /etc/resolv.conf /etc/netns/$NS_NAME/

# Routage
ip netns exec $NS_NAME ip route add default via 10.100.$INDEX.1

# Activer le transfert IP
sysctl -w net.ipv4.ip_forward=1

# NAT et règles de firewall pour l'accès Internet
# IMPORTANT: Ces règles sont maintenant commentées car nous utiliserons Tailscale comme exit node
# iptables -t nat -A POSTROUTING -s 10.100.$INDEX.0/24 -o ens3 -j MASQUERADE
# iptables -A FORWARD -i veth-host-$NS_NAME -o ens3 -j ACCEPT
# iptables -A FORWARD -i ens3 -o veth-host-$NS_NAME -m state --state RELATED,ESTABLISHED -j ACCEPT

# Copier les binaires Tailscale dans un emplacement spécifique pour l'isolation
mkdir -p /var/lib/tailscale-$NS_NAME

echo "Espace de noms $NS_NAME isolé et prêt"
