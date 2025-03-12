#!/bin/bash
# Usage: ./cleanup.sh [esp_name]
# Si esp_name est fourni, nettoie uniquement cet ESP
# Sinon, nettoie tous les ESP
# IMPORTANT: Ne touche pas à l'instance Tailscale principale de la VM !

ESP_NAME=$1

# Fonction pour nettoyer les règles iptables spécifiques à un ESP
cleanup_iptables_for_esp() {
    local ns_name=$1
    local index=${ns_name#esp}
    echo "Nettoyage des règles iptables pour $ns_name..."

    # Nettoyer les règles INPUT
    iptables -D INPUT -i veth-h-$ns_name -j ACCEPT 2>/dev/null

    # Nettoyer les règles FORWARD spécifiques
    iptables -D FORWARD -i wg0 -o veth-h-$ns_name -j ACCEPT 2>/dev/null
    iptables -D FORWARD -i veth-h-$ns_name -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
    iptables -D FORWARD -i ens3 -o veth-h-$ns_name -j ACCEPT 2>/dev/null
    iptables -D FORWARD -i veth-h-$ns_name -o ens3 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null

    # Nettoyer les règles FORWARD basées sur les réseaux
    while iptables -D FORWARD -s 10.100.$index.0/24 -j ACCEPT 2>/dev/null; do
        echo "Suppression d'une règle FORWARD pour 10.100.$index.0/24"
    done

    # Nettoyer les règles NAT
    iptables -t nat -D POSTROUTING -s 10.100.$index.0/24 -o ens3 -j MASQUERADE 2>/dev/null
}

# Fonction pour nettoyer les règles iptables globales
cleanup_global_iptables() {
    echo "Nettoyage des règles iptables globales..."

    # Nettoyer les règles FORWARD globales
    while iptables -D FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do
        echo "Suppression d'une règle FORWARD pour RELATED,ESTABLISHED"
    done

    # Alternative plus sûre avec grep
    for rule in $(iptables -L FORWARD --line-numbers -n | grep "RELATED,ESTABLISHED" | awk '{print $1}' | sort -nr); do
        iptables -D FORWARD $rule 2>/dev/null
    done

    # Supprimer toutes les règles avec "ctstate RELATED,ESTABLISHED"
    for rule in $(iptables -L FORWARD --line-numbers -n | grep "ctstate RELATED,ESTABLISHED" | awk '{print $1}' | sort -nr); do
        iptables -D FORWARD $rule 2>/dev/null
    done
}

cleanup_esp() {
    local name=$1
    local ns_name="esp${name#esp}"  # Extrait le numéro de l'ESP

    echo "Nettoyage de $name (namespace: $ns_name)..."

    # Arrêter UNIQUEMENT l'instance Tailscale du namespace
    if [ -e "/var/run/tailscale-$ns_name.sock" ]; then
        ip netns exec $ns_name tailscale --socket=/var/run/tailscale-$ns_name.sock down 2>/dev/null
        pkill -f "tailscaled.*state=/var/lib/tailscale-$ns_name/state.json" 2>/dev/null
    fi

    # Supprimer UNIQUEMENT les fichiers Tailscale du namespace
    rm -rf "/var/lib/tailscale-$ns_name"
    rm -f "/var/run/tailscale-$ns_name.sock"

    # Nettoyer les règles iptables pour cet ESP
    cleanup_iptables_for_esp "$ns_name"

    # Supprimer les interfaces veth (une seule commande suffit, l'autre interface sera supprimée automatiquement)
    ip link del "veth-h-$ns_name" 2>/dev/null

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

    # Nettoyer les règles iptables globales
    cleanup_global_iptables

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

# Vérification finale
echo "Vérification après nettoyage:"
echo "----------------------------------"
echo "Interfaces résiduelles:"
ip link show | grep veth || echo "Aucune"
echo "----------------------------------"
echo "Namespaces restants:"
ip netns list | grep esp || echo "Aucun"
echo "----------------------------------"
echo "Règles iptables INPUT résiduelles pour veth:"
iptables -L INPUT -n -v | grep veth || echo "Aucune"
echo "----------------------------------"
echo "Règles iptables FORWARD résiduelles pour 10.100:"
iptables -L FORWARD -n -v | grep "10.100" || echo "Aucune"
echo "----------------------------------"
echo "Règles iptables NAT résiduelles:"
iptables -t nat -L POSTROUTING -n -v | grep "10.100" || echo "Aucune"
echo "----------------------------------"