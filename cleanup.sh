#!/bin/bash
# Usage: ./cleanup.sh [esp_name]
# Si esp_name est fourni, nettoie uniquement cet ESP
# Sinon, nettoie tous les ESP
# IMPORTANT: Ne touche pas à l'instance Tailscale principale de la VM !

ESP_NAME=$1

cleanup_esp() {
    local name=$1
    local ns_name="esp${name#esp}"  # Extrait le numéro de l'ESP

    echo "Nettoyage de $name (namespace: $ns_name)..."

    # Arrêter UNIQUEMENT l'instance Tailscale du namespace
    if [ -e "/var/run/tailscale-$ns_name.sock" ]; then
        ip netns exec $ns_name tailscale --socket=/var/run/tailscale-$ns_name.sock down
        pkill -f "tailscaled.*state=/var/lib/tailscale-$ns_name/state.json"  # Plus précis
    fi

    # Supprimer UNIQUEMENT les fichiers Tailscale du namespace
    rm -rf "/var/lib/tailscale-$ns_name"
    rm -f "/var/run/tailscale-$ns_name.sock"

    # Supprimer les interfaces veth
    ip link del "veth-$ns_name" 2>/dev/null
    ip link del "netns0-host-$ns_name" 2>/dev/null

    # Supprimer le namespace
    ip netns del "$ns_name" 2>/dev/null

    # Supprimer la configuration DNS du namespace
    rm -rf "/etc/netns/$ns_name"

    # Supprimer les clés WireGuard de l'ESP
    rm -rf "$HOME/esp-keys/$name"

    echo "Nettoyage de $name terminé"
}

# Arrêter WireGuard (dans l'espace global)
if ip link show wg0 &>/dev/null; then
    echo "Arrêt de WireGuard..."
    wg-quick down wg0
fi

if [ -z "$ESP_NAME" ]; then
    # Nettoyer tous les ESP
    echo "Nettoyage de tous les ESP (l'instance Tailscale principale n'est pas touchée)..."
    
    # Trouver tous les namespaces esp*
    for ns in $(ip netns list | grep "esp" | cut -d' ' -f1); do
        cleanup_esp "${ns}"
    done

    # Supprimer la configuration WireGuard
    rm -f /etc/wireguard/wg0.conf
    rm -f /etc/wireguard/wg0.key
    rm -f /etc/wireguard/wg0.pub

    echo "Nettoyage complet des ESP terminé"
else
    # Nettoyer uniquement l'ESP spécifié
    cleanup_esp "$ESP_NAME"
    
    echo "Note: La configuration WireGuard globale n'a pas été supprimée"
    echo "Pour la supprimer complètement, relancez sans argument: ./cleanup.sh"
fi 