#!/bin/bash
# Usage: ./setup-internal-routing.sh <namespace-name> <esp_ip>

NS_NAME=$1
ESP_IP=$2

if [ -z "$NS_NAME" ] || [ -z "$ESP_IP" ]; then
  echo "Usage: $0 <namespace-name> <esp_ip>"
  exit 1
fi

# Extract the index from the namespace name
INDEX=${NS_NAME#esp}

# Correct interface names
VETH_NS="veth-$NS_NAME"
VETH_HOST="veth-h-$NS_NAME"

echo "Configuration of routing for $NS_NAME with ESP IP $ESP_IP"
echo "Interfaces: $VETH_NS (namespace) and $VETH_HOST (host)"

# Check if the interfaces exist
if ! ip link show $VETH_HOST &>/dev/null; then
  echo "ERROR: The interface $VETH_HOST does not exist in the host"
  exit 1
fi

if ! ip netns exec $NS_NAME ip link show $VETH_NS &>/dev/null; then
  echo "ERROR: The interface $VETH_NS does not exist in the namespace $NS_NAME"
  exit 1
fi

# Configuration NAT in the namespace
ip netns exec $NS_NAME iptables -t nat -A POSTROUTING -s 10.6.0.0/24 -j MASQUERADE

# Configuration DNAT for port 80
ip netns exec $NS_NAME iptables -t nat -A PREROUTING -i tailscale-netns -p tcp --dport 80 -j DNAT --to-destination $ESP_IP:80

# Route to the ESP from the namespace
ip netns exec $NS_NAME ip route add $ESP_IP/32 via 10.100.$INDEX.1

# Inverse route on the host (normally not necessary)
# ip route replace $ESP_IP/32 dev wg0

# Allow forwarding between interfaces
iptables -A FORWARD -i wg0 -o $VETH_HOST -j ACCEPT
iptables -A FORWARD -i $VETH_HOST -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT

# Forwarding rules in the namespace for port 80
ip netns exec $NS_NAME iptables -A FORWARD -i tailscale-netns -o $VETH_NS -p tcp --dport 80 -j ACCEPT
ip netns exec $NS_NAME iptables -A FORWARD -i $VETH_NS -o tailscale-netns -m state --state RELATED,ESTABLISHED -j ACCEPT

echo "Internal routing configuration completed for $NS_NAME"