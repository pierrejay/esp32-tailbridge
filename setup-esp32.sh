#!/bin/bash
# Usage: ./setup-esp32.sh <esp_name>

ESP_NAME=$1
if [ -z "$ESP_NAME" ]; then
  echo "Usage: $0 <esp_name>"
  exit 1
fi

# Déterminer le prochain index disponible
NEXT_INDEX=$(ls -1 /var/lib/tailscale-esp* 2>/dev/null | wc -l)
NEXT_INDEX=$((NEXT_INDEX + 1))

# Générer une IP WireGuard pour l'ESP32
ESP_IP="10.6.0.$((NEXT_INDEX + 1))"
NS_NAME="esp$NEXT_INDEX"

# Générer les clés WireGuard pour l'ESP32
mkdir -p ~/esp-keys/$ESP_NAME
wg genkey | tee ~/esp-keys/$ESP_NAME/private.key | wg pubkey > ~/esp-keys/$ESP_NAME/public.key
ESP_PUBKEY=$(cat ~/esp-keys/$ESP_NAME/public.key)

# Obtenir une clé d'authentification Tailscale
echo "Obtenez une clé d'authentification depuis la console Tailscale:"
echo "https://login.tailscale.com/admin/settings/keys"
read -p "Entrez la clé d'authentification: " AUTHKEY

# Isoler l'espace de noms
./isolate-tailscale.sh $NS_NAME $NEXT_INDEX

# Configurer WireGuard
./setup-wireguard.sh $ESP_NAME $ESP_PUBKEY $ESP_IP

# Démarrer Tailscale dans l'espace de noms
./run-tailscale-namespace.sh $NS_NAME $ESP_IP "$ESP_NAME" "$AUTHKEY"

echo "----------------------------------------"
echo "Configuration terminée pour $ESP_NAME"
echo "ESP32 IP (WireGuard): $ESP_IP"
echo "Configuration WireGuard pour ESP32:"
echo "----------------------------------------"
cat << EOF
[Interface]
PrivateKey = $(cat ~/esp-keys/$ESP_NAME/private.key)
Address = $ESP_IP/24
DNS = 1.1.1.1

[Peer]
PublicKey = $(cat /etc/wireguard/wg0.pub)
Endpoint = $(curl -s ifconfig.me):51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
echo "----------------------------------------"
