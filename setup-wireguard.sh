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

# Vérifier si l'interface wg0 existe déjà
if ip link show wg0 &>/dev/null; then
  # Ajouter directement le nouveau peer à l'interface active
  echo "Ajout du peer $ESP_NAME à l'interface WireGuard existante..."
  wg set wg0 peer $ESP_PUBKEY allowed-ips $ESP_IP/32 persistent-keepalive 25
else
  # Premier démarrage : créer une configuration de base
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

  # Démarrer WireGuard
  wg-quick up wg0
  echo "Interface WireGuard (wg0) créée avec le premier peer $ESP_NAME"
fi

echo "Configuration WireGuard pour $ESP_NAME ($ESP_IP) terminée"

# Fonction pour obtenir l'IP publique avec résolution DNS manuelle
get_public_ip() {
  if command -v dig >/dev/null 2>&1; then
    echo "Test avec dig..."
    IP=$(dig +short ifconfig.me @8.8.8.8)
    if [ -n "$IP" ]; then
      # Utiliser curl avec l'IP directement
      curl -s --connect-to ifconfig.me:80:$IP:80 http://ifconfig.me
      return
    fi
  fi

  # Fallback avec nslookup si dig n'est pas disponible
  if command -v nslookup >/dev/null 2>&1; then
    IP=$(nslookup ifconfig.me 8.8.8.8 | awk '/Address/ { print $2 }' | tail -n1)
    if [ -n "$IP" ]; then
      curl -s --connect-to ifconfig.me:80:$IP:80 http://ifconfig.me
      return
    fi
  fi

  # Si tout échoue, utiliser une IP par défaut ou afficher un message d'erreur
  echo "Impossible de récupérer l'IP publique. Veuillez la configurer manuellement."
}

echo "Configuration pour l'ESP32:"
cat << EOF
[Interface]
PrivateKey = <clé privée de l'ESP32>
Address = $ESP_IP/24
DNS = 1.1.1.1

[Peer]
PublicKey = $SERVER_PUBKEY
Endpoint = $(get_public_ip):51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF