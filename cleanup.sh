#!/bin/bash
# Usage: ./cleanup.sh [esp_name]
# Si esp_name est fourni, nettoie uniquement cet ESP
# Sinon, nettoie tous les ESP
# IMPORTANT: Ne touche pas à l'instance Tailscale principale de la VM !

ESP_NAME=$1

# Fonction pour supprimer toutes les règles correspondant à un pattern (chaîne, table, pattern)
remove_all_matching_rules() {
    local chain="$1"
    local table="$2"
    local pattern="$3"
    local table_opt=""
    
    if [ -n "$table" ]; then
        table_opt="-t $table"
    fi

    # Continuer à essayer jusqu'à ce qu'il n'y ait plus de règles correspondantes
    while iptables $table_opt -L $chain -n | grep -q "$pattern"; do
        local rule_num=$(iptables $table_opt -L $chain --line-numbers -n | grep "$pattern" | head -n1 | awk '{print $1}')
        if [ -n "$rule_num" ]; then
            echo "Suppression règle #$rule_num dans $chain ($table) contenant '$pattern'"
            iptables $table_opt -D $chain $rule_num
        else
            break
        fi
    done
}

# Fonction pour nettoyer toutes les règles spécifiques à un ESP
cleanup_iptables_for_esp() {
    local ns_name=$1
    local index=${ns_name#esp}
    echo "Nettoyage exhaustif des règles iptables pour $ns_name..."

    # Suppression des règles INPUT avec veth-h-$ns_name
    remove_all_matching_rules "INPUT" "" "veth-h-$ns_name"
    
    # Suppression des règles FORWARD avec veth-h-$ns_name
    remove_all_matching_rules "FORWARD" "" "veth-h-$ns_name"
    
    # Suppression des règles FORWARD pour le réseau 10.100.$index.0/24
    remove_all_matching_rules "FORWARD" "" "10.100.$index.0/24"
    
    # Suppression des règles NAT POSTROUTING pour le réseau 10.100.$index.0/24
    remove_all_matching_rules "POSTROUTING" "nat" "10.100.$index.0/24"
}

# Fonction pour nettoyer les règles iptables globales
cleanup_global_iptables() {
    echo "Nettoyage des règles iptables globales..."

    # Nettoyer les règles FORWARD globales
    remove_all_matching_rules "FORWARD" "" "ctstate RELATED,ESTABLISHED"
    remove_all_matching_rules "FORWARD" "" "state RELATED,ESTABLISHED"
    
    # Supprimer les règles pour tous les réseaux 10.100
    remove_all_matching_rules "FORWARD" "" "10.100"
    remove_all_matching_rules "POSTROUTING" "nat" "10.100"
    
    # Supprimer les règles pour l'interface wg0
    remove_all_matching_rules "FORWARD" "" "wg0"
    
    # Supprimer TOUTES les règles INPUT pour veth
    remove_all_matching_rules "INPUT" "" "veth"
}

# Fonction pour supprimer une règle nftables spécifique
cleanup_nft_rule() {
    local chain="$1"
    local table="$2"
    local pattern="$3"
    
    # Obtenir le handle de la règle qui match le pattern
    local handles=$(nft -a list chain ip $table $chain | grep "$pattern" | grep -o "handle [0-9]*" | awk '{print $2}')
    
    for handle in $handles; do
        echo "Suppression règle nftables dans $table $chain (handle $handle) contenant '$pattern'"
        nft delete rule ip $table $chain handle $handle
    done
}

# Fonction pour nettoyer les règles nftables d'un ESP spécifique
cleanup_nft_for_esp() {
    local ns_name=$1
    echo "Nettoyage des règles nftables pour $ns_name..."
    
    # Nettoyer les règles INPUT pour veth-h-$ns_name
    cleanup_nft_rule "INPUT" "filter" "iifname \"veth-h-$ns_name\""
    
    # Nettoyer les règles FORWARD pour veth-h-$ns_name
    cleanup_nft_rule "FORWARD" "filter" "oifname \"veth-h-$ns_name\""
    cleanup_nft_rule "FORWARD" "filter" "iifname \"veth-h-$ns_name\""
}

cleanup_esp() {
    local name=$1
    local ns_name="esp${name#esp}"

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

    # Nettoyer les règles nftables pour cet ESP
    cleanup_nft_for_esp "$ns_name"

    echo "Nettoyage de $name terminé"
}

# Fonction pour vider complètement une chaîne iptables
flush_chain() {
    local chain="$1"
    local table="$2"
    local table_opt=""
    
    if [ -n "$table" ]; then
        table_opt="-t $table"
    fi
    
    echo "Vidage complet de la chaîne $chain ${table:+dans la table $table}..."
    iptables $table_opt -F $chain 2>/dev/null
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
    
    # Nettoyer également les règles INPUT pour veth, même en mode ESP unique
    remove_all_matching_rules "INPUT" "" "veth-h-$ESP_NAME"
    
    echo "Note: La configuration WireGuard globale n'a pas été supprimée"
    echo "Pour la supprimer complètement, relancez sans argument: ./cleanup.sh"
fi

# Nettoyage final des règles veth résiduelles dans INPUT
remove_all_matching_rules "INPUT" "" "veth"

# Tentatives supplémentaires pour les règles tenaces
echo "Nettoyage supplémentaire des règles tenaces..."

# 1. Suppression directe et ciblée
iptables -D INPUT -i veth-h-esp1 -j ACCEPT 2>/dev/null
iptables -D INPUT -i veth-h-esp1 -p 0 -j ACCEPT 2>/dev/null

# 2. Si les règles veth persistent, on vide complètement la chaîne INPUT
# et on laisse la politique par défaut (généralement ACCEPT)
if iptables -L INPUT -n | grep -q "veth"; then
    echo "Règles veth persistantes détectées, vidage complet de la chaîne INPUT..."
    flush_chain "INPUT"
fi

# Nettoyage final des règles tenaces avec protocole 0
for veth in $(ip link show | grep 'veth' | cut -d: -f2 | cut -d@ -f1); do
    iptables -D INPUT -i $veth -p 0 -j ACCEPT 2>/dev/null
    iptables -D INPUT -i $veth -j ACCEPT 2>/dev/null
done

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