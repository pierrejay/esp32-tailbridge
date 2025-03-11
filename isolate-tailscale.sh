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
# Utiliser les DNS de Google comme fallback
cat > /etc/netns/$NS_NAME/resolv.conf << EOF
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF

# Routage
ip netns exec $NS_NAME ip route add default via 10.100.$INDEX.1

# Activer le transfert IP
sysctl -w net.ipv4.ip_forward=1

# Trouver l'index de la règle REJECT
REJECT_LINE=$(iptables -L FORWARD --line-numbers | grep "REJECT.*icmp-host-prohibited" | awk '{print $1}')

# Ajouter nos règles juste avant la règle REJECT
if [ -n "$REJECT_LINE" ]; then
    echo "Ajout des règles de forwarding avant la règle REJECT (ligne $REJECT_LINE)"
    iptables -I FORWARD $REJECT_LINE -i "veth-host-$NS_NAME" -o "$DEFAULT_IF" -j ACCEPT
    iptables -I FORWARD $REJECT_LINE -i "$DEFAULT_IF" -o "veth-host-$NS_NAME" -m state --state RELATED,ESTABLISHED -j ACCEPT
else
    echo "Règle REJECT non trouvée, ajout des règles à la fin"
    iptables -A FORWARD -i "veth-host-$NS_NAME" -o "$DEFAULT_IF" -j ACCEPT
    iptables -A FORWARD -i "$DEFAULT_IF" -o "veth-host-$NS_NAME" -m state --state RELATED,ESTABLISHED -j ACCEPT
fi

# NAT pour permettre l'accès Internet depuis le namespace
echo "Configuration du NAT avec interface de sortie $DEFAULT_IF"
iptables -t nat -A POSTROUTING -s "10.100.$INDEX.0/24" -o "$DEFAULT_IF" -j MASQUERADE

# Afficher les règles de firewall actuelles
echo "Règles de firewall actuelles:"
echo "1. Table NAT:"
iptables -t nat -L -n -v
echo "2. Table FILTER:"
iptables -L -n -v

# Vérifications
echo "Vérification de la configuration..."
echo "1. Interface dans le namespace:"
ip netns exec $NS_NAME ip addr show

echo "2. Route par défaut dans le namespace:"
ip netns exec $NS_NAME ip route show

echo "3. Règles NAT:"
iptables -t nat -L -n -v | grep 10.100.$INDEX

echo "4. Test de ping vers la passerelle:"
ip netns exec $NS_NAME ping -c 1 10.100.$INDEX.1

echo "5. Test de ping vers 8.8.8.8:"
ip netns exec $NS_NAME ping -c 1 8.8.8.8

# Copier les binaires Tailscale dans un emplacement spécifique pour l'isolation
mkdir -p /var/lib/tailscale-$NS_NAME

echo "Espace de noms $NS_NAME isolé et prêt"
