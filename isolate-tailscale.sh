#!/bin/bash

# Usage: ./isolate-tailscale.sh <namespace-name> <index>

NS_NAME=$1
INDEX=$2

# Determine the default output interface
DEFAULT_IF=$(ip route show default | awk '/default/ {print $5}')
if [ -z "$DEFAULT_IF" ]; then
    echo "Error: Unable to find the default interface"
    exit 1
fi
echo "Output interface: $DEFAULT_IF"

echo "Configuring namespace $NS_NAME..."

# Create the namespace
ip netns add $NS_NAME

# Create the veth interfaces
ip link add veth-$NS_NAME type veth peer name veth-h-$NS_NAME
ip link set veth-h-$NS_NAME up
ip link set veth-$NS_NAME netns $NS_NAME

# Configuration in the namespace
ip netns exec $NS_NAME ip link set lo up
ip netns exec $NS_NAME ip link set veth-$NS_NAME up
ip netns exec $NS_NAME ip addr add 10.100.$INDEX.2/24 dev veth-$NS_NAME

# Configuration on the host
ip addr add 10.100.$INDEX.1/24 dev veth-h-$NS_NAME

# DNS configuration
mkdir -p /etc/netns/$NS_NAME
# Use Google's DNS as fallback
cat > /etc/netns/$NS_NAME/resolv.conf << EOF
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF

# Routing
ip netns exec $NS_NAME ip route add default via 10.100.$INDEX.1

# Enable IP forwarding
sysctl -w net.ipv4.ip_forward=1

# Forwarding and NAT configuration
echo "Forwarding and NAT configuration..."

echo "Checking system forwarding rules..."
sysctl net.ipv4.conf.all.forwarding=1
sysctl net.ipv4.conf.$DEFAULT_IF.forwarding=1

# Ensure traffic can pass between interfaces
iptables -A FORWARD -i $DEFAULT_IF -o veth-h-$NS_NAME -j ACCEPT
iptables -A FORWARD -i veth-h-$NS_NAME -o $DEFAULT_IF -m state --state RELATED,ESTABLISHED -j ACCEPT

# Allow incoming traffic from the veth interface
iptables -A INPUT -i veth-h-$NS_NAME -j ACCEPT

# Check that NAT is properly configured
iptables -t nat -C POSTROUTING -s 10.100.$INDEX.0/24 -o $DEFAULT_IF -j MASQUERADE || \
  iptables -t nat -A POSTROUTING -s 10.100.$INDEX.0/24 -o $DEFAULT_IF -j MASQUERADE

# 1. Allow all outgoing traffic from the namespace
iptables -I FORWARD 1 -s "10.100.$INDEX.0/24" -j ACCEPT

# 2. Allow established return traffic
iptables -I FORWARD 2 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# Checks
echo "Checking configuration..."
echo "1. Interface in the namespace:"
ip netns exec $NS_NAME ip addr show

echo "2. Default route in the namespace:"
ip netns exec $NS_NAME ip route show

echo "3. Test of connectivity:"
echo "   a. Ping to the gateway:"
ip netns exec $NS_NAME ping -c 1 10.100.$INDEX.1
echo "   b. Ping to 8.8.8.8:"
ip netns exec $NS_NAME ping -c 1 8.8.8.8
echo "   c. Test DNS:"
ip netns exec $NS_NAME nslookup google.com

# Copy Tailscale binaries to a specific location for isolation
mkdir -p /var/lib/tailscale-$NS_NAME

echo "Namespace $NS_NAME is isolated and ready"

# Create the TUN device in the namespace
ip netns exec $NS_NAME mkdir -p /dev/net
ip netns exec $NS_NAME mknod /dev/net/tun c 10 200
ip netns exec $NS_NAME chmod 0666 /dev/net/tun

# Enable forwarding in the namespace
ip netns exec $NS_NAME sysctl -w net.ipv4.ip_forward=1
