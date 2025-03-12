#!/bin/bash
# Usage: sudo ./setup-esp32.sh <esp_name>

# Vérifier les droits root
if [ "$EUID" -ne 0 ]; then
    echo "Ce script doit être exécuté avec sudo"
    exit 1
fi

# Installer les outils DNS si nécessaire
if ! command -v nslookup >/dev/null 2>&1; then
    echo "Installation des outils DNS..."
    apt-get update && apt-get install -y dnsutils
fi

# Rendre tous les scripts exécutables
chmod +x "$(dirname "$0")"/*.sh

ESP_NAME=$1
if [ -z "$ESP_NAME" ]; then
  echo "Usage: sudo $0 <esp_name>"
  exit 1
fi

# Déterminer le prochain index disponible
NEXT_INDEX=$(ls -1 /var/lib/tailscale-esp* 2>/dev/null | wc -l)
NEXT_INDEX=$((NEXT_INDEX + 1))


# Générer une IP WireGuard pour l'ESP32
ESP_IP="10.6.0.$((NEXT_INDEX + 1))"
NS_NAME="esp$NEXT_INDEX"

# Obtenir le vrai home directory de l'utilisateur qui a lancé sudo
REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)

# Générer les clés WireGuard pour l'ESP32
mkdir -p "$REAL_HOME/esp-keys/$ESP_NAME"
wg genkey | tee "$REAL_HOME/esp-keys/$ESP_NAME/private.key" | wg pubkey > "$REAL_HOME/esp-keys/$ESP_NAME/public.key"
ESP_PUBKEY=$(cat "$REAL_HOME/esp-keys/$ESP_NAME/public.key")

# Obtenir une clé d'authentification Tailscale
echo "Obtenez une clé d'authentification depuis la console Tailscale:"
echo "https://login.tailscale.com/admin/settings/keys"
read -p "Entrez la clé d'authentification: " AUTHKEY

# 1. Créer et configurer le namespace pour Tailscale
./isolate-tailscale.sh $NS_NAME $NEXT_INDEX

# Vérifier la connectivité DNS
echo "Vérification de la connectivité DNS dans le namespace..."
if ! ip netns exec $NS_NAME ping -c 1 8.8.8.8 > /dev/null 2>&1; then
    echo "Erreur: Pas de connectivité Internet dans le namespace"
    exit 1
fi

if ! ip netns exec $NS_NAME nslookup google.com > /dev/null 2>&1; then
    echo "Erreur: La résolution DNS ne fonctionne pas dans le namespace"
    exit 1
fi

# 2. Configurer WireGuard (dans l'espace global)
./setup-wireguard.sh $ESP_NAME $ESP_PUBKEY $ESP_IP

# 3. Démarrer Tailscale dans le namespace (sans advertise-routes)
./run-tailscale-namespace.sh $NS_NAME "$ESP_NAME" "$AUTHKEY"

# 4. Configurer le routage entre WireGuard et le namespace Tailscale
./setup-internal-routing.sh $NS_NAME $ESP_IP

echo "----------------------------------------"
echo "Configuration terminée pour $ESP_NAME"
echo "ESP32 IP (WireGuard): $ESP_IP"
echo "Configuration WireGuard pour ESP32:"
echo "----------------------------------------"
cat << EOF
[Interface]
PrivateKey = $(cat "$REAL_HOME/esp-keys/$ESP_NAME/private.key")
Address = $ESP_IP/24
DNS = 1.1.1.1

[Peer]
PublicKey = $(cat /etc/wireguard/wg0.pub)
Endpoint = $(curl -s ifconfig.me):51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
echo "----------------------------------------"
