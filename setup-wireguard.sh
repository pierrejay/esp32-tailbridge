#!/bin/bash
# Usage: ./setup-wireguard.sh <esp_name> <esp_pubkey> <esp_ip>

ESP_NAME=$1
ESP_PUBKEY=$2
ESP_IP=$3

if [ -z "$ESP_NAME" ] || [ -z "$ESP_PUBKEY" ] || [ -z "$ESP_IP" ]; then
  echo "Usage: $0 <esp_name> <esp_pubkey> <esp_ip>"
  exit 1
fi

# Generate keys if they don't exist
if [ ! -f /etc/wireguard/wg0.key ]; then
  wg genkey | tee /etc/wireguard/wg0.key | wg pubkey > /etc/wireguard/wg0.pub
fi

SERVER_PRIVKEY=$(cat /etc/wireguard/wg0.key)
SERVER_PUBKEY=$(cat /etc/wireguard/wg0.pub)

# Check if the wg0 interface already exists
if ip link show wg0 &>/dev/null; then
  # Add the new peer directly to the active interface
  echo "Adding peer $ESP_NAME to the existing WireGuard interface..."
  wg set wg0 peer $ESP_PUBKEY allowed-ips $ESP_IP/32 persistent-keepalive 25
else
  # First startup: create a basic configuration
  cat > /etc/wireguard/wg0.conf << EOF
[Interface]
PrivateKey = $SERVER_PRIVKEY
Address = 10.6.0.1/24
ListenPort = 51820
SaveConfig = true

[Peer]
# $ESP_NAME
PublicKey = $ESP_PUBKEY
AllowedIPs = $ESP_IP/32
PersistentKeepalive = 25
EOF

  # Start WireGuard
  wg-quick up wg0
  echo "WireGuard interface (wg0) created with the first peer $ESP_NAME"
fi

echo "WireGuard configuration for $ESP_NAME ($ESP_IP) completed"

# Function to get the public IP with manual DNS resolution
get_public_ip() {
  if command -v dig >/dev/null 2>&1; then
    echo "Test with dig..."
    IP=$(dig +short ifconfig.me @8.8.8.8)
    if [ -n "$IP" ]; then
      # Use curl with the IP directly
      curl -s --connect-to ifconfig.me:80:$IP:80 http://ifconfig.me
      return
    fi
  fi

  # Fallback with nslookup if dig is not available
  if command -v nslookup >/dev/null 2>&1; then
    IP=$(nslookup ifconfig.me 8.8.8.8 | awk '/Address/ { print $2 }' | tail -n1)
    if [ -n "$IP" ]; then
      curl -s --connect-to ifconfig.me:80:$IP:80 http://ifconfig.me
      return
    fi
  fi

  # If everything fails, use a default IP or display an error message
  echo "Unable to retrieve the public IP. Please configure it manually."
}

echo "Configuration for the ESP32:"
cat << EOF
[Interface]
PrivateKey = <ESP32 private key>
Address = $ESP_IP/24
DNS = 1.1.1.1

[Peer]
PublicKey = $SERVER_PUBKEY
Endpoint = $(get_public_ip):51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF