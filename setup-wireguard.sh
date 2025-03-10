#!/bin/bash
# Usage: ./setup-wireguard.sh <esp_name> <esp_pubkey> <esp_ip>

ESP_NAME=$1
ESP_PUBKEY=$2
ESP_IP=$3

if [ -z "$ESP_NAME" ] || [ -z "$ESP_PUBKEY" ] || [ -z "$ESP_IP" ]; then
  echo "Usage: $0 <esp_name> <esp_pubkey> <esp_ip>"
  exit 1
fi

# Générer des clés si elles n'existent pas
if [ ! -f /etc/wireguard/wg0.key ]; then
  wg genkey | tee /etc/wireguard/wg0.key | wg pubkey > /etc/wireguard/wg0.pub
fi

SERVER_PRIVKEY=$(cat /etc/wireguard/wg0.key)
SERVER_PUBKEY=$(cat /etc/wireguard/wg0.pub)

# Créer ou mettre à jour la configuration WireGuard
if [ ! -f /etc/wireguard/wg0.conf ]; then
  cat > /etc/wireguard/wg0.conf << EOF
[Interface]
PrivateKey = $SERVER_PRIVKEY
Address = 10.6.0.1/24
ListenPort = 51820
SaveConfig = true

EOF
fi

# Ajouter le peer ESP32
cat >> /etc/wireguard/wg0.conf << EOF
[Peer]
# $ESP_NAME
PublicKey = $ESP_PUBKEY
AllowedIPs = $ESP_IP/32
PersistentKeepalive = 25
EOF

# Démarrer ou redémarrer WireGuard
if ip link show wg0 &>/dev/null; then
  wg-quick down wg0
fi
wg-quick up wg0

echo "Configuration WireGuard pour $ESP_NAME ($ESP_IP) terminée"
echo "Configuration pour l'ESP32:"
cat << EOF
[Interface]
PrivateKey = <clé privée de l'ESP32>
Address = $ESP_IP/24
DNS = 1.1.1.1

[Peer]
PublicKey = $SERVER_PUBKEY
Endpoint = $(curl -s ifconfig.me):51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
