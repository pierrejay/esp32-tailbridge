#!/bin/bash
# Usage: sudo ./setup-esp32.sh <esp_name>

# Vérifier les droits root
if [ "$EUID" -ne 0 ]; then
    echo "Ce script doit être exécuté avec sudo"
    exit 1
fi

# Fonction pour installer les dépendances
install_dependencies() {
    echo "Installation des dépendances..."
    
    # Mise à jour des paquets
    apt-get update

    # Installation de WireGuard
    if ! command -v wg >/dev/null 2>&1; then
        echo "Installation de WireGuard..."
        apt-get install -y wireguard
    fi

    # Installation des outils DNS (dig, nslookup)
    if ! command -v dig >/dev/null 2>&1; then
        echo "Installation des outils DNS..."
        apt-get install -y dnsutils
    fi

    # Installation de curl
    if ! command -v curl >/dev/null 2>&1; then
        echo "Installation de curl..."
        apt-get install -y curl
    fi

    # Installation de Tailscale
    if ! command -v tailscale >/dev/null 2>&1; then
        echo "Installation de Tailscale..."
        curl -fsSL https://tailscale.com/install.sh | sh
    fi

    # Installation des outils réseau (pour ip, iptables, etc.)
    if ! command -v ip >/dev/null 2>&1; then
        echo "Installation des outils réseau..."
        apt-get install -y iproute2
    fi

    # Installation de iptables
    if ! command -v iptables >/dev/null 2>&1; then
        echo "Installation de iptables..."
        apt-get install -y iptables
    fi
}

# Vérifier et installer les dépendances
echo "Vérification des dépendances..."
MISSING_DEPS=0

# Liste des commandes requises
REQUIRED_COMMANDS=(
    "wg"        # WireGuard
    "dig"       # DNS utils
    "curl"      # Pour les téléchargements
    "tailscale" # Tailscale
    "ip"        # iproute2
    "iptables"  # iptables
)

# Vérifier chaque commande
for cmd in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Commande manquante: $cmd"
        MISSING_DEPS=1
    fi
done

# Installer les dépendances si nécessaire
if [ "$MISSING_DEPS" -eq 1 ]; then
    echo "Des dépendances sont manquantes."
    read -p "Voulez-vous les installer maintenant ? (o/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Oo]$ ]]; then
        install_dependencies
    else
        echo "Installation annulée. Le script ne peut pas continuer sans les dépendances."
        exit 1
    fi
fi

# Rendre tous les scripts exécutables
chmod +x "$(dirname "$0")"/*.sh

ESP_NAME=$1
if [ -z "$ESP_NAME" ]; then
  echo "Usage: sudo $0 <esp_name>"
  exit 1
fi

# Déterminer le prochain index disponible
NEXT_INDEX=$(ip netns list | grep -c "esp")
NEXT_INDEX=$((NEXT_INDEX + 1))


# Générer une IP WireGuard pour l'ESP32
ESP_IP="10.6.0.$((NEXT_INDEX + 1))"
NS_NAME="esp$NEXT_INDEX"

# Supprimer les anciennes règles qui pourraient interférer
iptables -D FORWARD -i wg0 -o veth-h-$NS_NAME -j ACCEPT 2>/dev/null
iptables -D FORWARD -i veth-h-$NS_NAME -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null

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
