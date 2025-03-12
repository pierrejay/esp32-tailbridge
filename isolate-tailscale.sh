#!/bin/bash

# Usage: ./isolate-tailscale.sh <namespace-name> <index>

NS_NAME=$1
INDEX=$2

# Déterminer l'interface de sortie Internet
DEFAULT_IF=$(ip route show default | awk '/default/ {print $5}')
if [ -z "$DEFAULT_IF" ]; then
    echo "Erreur: Impossible de trouver l'interface par défaut"
    exit 1
fi
echo "Interface de sortie Internet: $DEFAULT_IF"

echo "Configuration du namespace $NS_NAME..."

# Créer l'espace de noms
ip netns add $NS_NAME

# Créer les interfaces veth
ip link add veth-$NS_NAME type veth peer name veth-h-$NS_NAME
ip link set veth-h-$NS_NAME up
ip link set veth-$NS_NAME netns $NS_NAME

# Configuration dans l'espace de noms
ip netns exec $NS_NAME ip link set lo up
ip netns exec $NS_NAME ip link set veth-$NS_NAME up
ip netns exec $NS_NAME ip addr add 10.100.$INDEX.2/24 dev veth-$NS_NAME

# Configuration sur l'hôte
ip addr add 10.100.$INDEX.1/24 dev veth-h-$NS_NAME

# Configuration DNS
mkdir -p /etc/netns/$NS_NAME
# Utiliser les DNS de Google comme fallback
cat > /etc/netns/$NS_NAME/resolv.conf << EOF
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF

# Routage
ip netns exec $NS_NAME ip route add default via 10.100.$INDEX.1

# Activer le transfert IP
sysctl -w net.ipv4.ip_forward=1

# Configuration du forwarding et NAT
echo "Configuration du forwarding et NAT..."

echo "Vérification des règles de forwarding système..."
sysctl net.ipv4.conf.all.forwarding=1
sysctl net.ipv4.conf.$DEFAULT_IF.forwarding=1

# S'assurer que le traffic peut passer entre les interfaces
iptables -A FORWARD -i $DEFAULT_IF -o veth-h-$NS_NAME -j ACCEPT
iptables -A FORWARD -i veth-h-$NS_NAME -o $DEFAULT_IF -m state --state RELATED,ESTABLISHED -j ACCEPT

# Autoriser le trafic entrant depuis l'interface veth 
iptables -A INPUT -i veth-h-$NS_NAME -j ACCEPT

# Vérifier que le NAT est bien configuré
iptables -t nat -C POSTROUTING -s 10.100.$INDEX.0/24 -o $DEFAULT_IF -j MASQUERADE || \
  iptables -t nat -A POSTROUTING -s 10.100.$INDEX.0/24 -o $DEFAULT_IF -j MASQUERADE

# 1. Autoriser tout le trafic sortant du namespace
iptables -I FORWARD 1 -s "10.100.$INDEX.0/24" -j ACCEPT

# 2. Autoriser le trafic de retour établi
iptables -I FORWARD 2 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# Vérifications
echo "Vérification de la configuration..."
echo "1. Interface dans le namespace:"
ip netns exec $NS_NAME ip addr show

echo "2. Route par défaut dans le namespace:"
ip netns exec $NS_NAME ip route show

echo "3. Test de connectivité:"
echo "   a. Ping vers la passerelle:"
ip netns exec $NS_NAME ping -c 1 10.100.$INDEX.1
echo "   b. Ping vers 8.8.8.8:"
ip netns exec $NS_NAME ping -c 1 8.8.8.8
echo "   c. Test DNS:"
ip netns exec $NS_NAME nslookup google.com

# Copier les binaires Tailscale dans un emplacement spécifique pour l'isolation
mkdir -p /var/lib/tailscale-$NS_NAME

echo "Espace de noms $NS_NAME isolé et prêt"

# Créer le device TUN dans le namespace
ip netns exec $NS_NAME mkdir -p /dev/net
ip netns exec $NS_NAME mknod /dev/net/tun c 10 200
ip netns exec $NS_NAME chmod 0666 /dev/net/tun

# Activer le forwarding dans le namespace
ip netns exec $NS_NAME sysctl -w net.ipv4.ip_forward=1
