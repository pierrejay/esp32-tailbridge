#!/bin/bash
# Usage: ./cleanup.sh [esp_name]
# If esp_name is provided, clean only that ESP
# Otherwise, clean all ESPs
# IMPORTANT: Do not touch the main Tailscale instance of the VM!

ESP_NAME=$1

# Function to remove all rules matching a pattern (chain, table, pattern)
remove_all_matching_rules() {
    local chain="$1"
    local table="$2"
    local pattern="$3"
    local table_opt=""
    
    if [ -n "$table" ]; then
        table_opt="-t $table"
    fi

    # Continue trying until there are no more matching rules
    while iptables $table_opt -L $chain -n | grep -q "$pattern"; do
        local rule_num=$(iptables $table_opt -L $chain --line-numbers -n | grep "$pattern" | head -n1 | awk '{print $1}')
        if [ -n "$rule_num" ]; then
            echo "Removing rule #$rule_num in $chain ($table) containing '$pattern'"
            iptables $table_opt -D $chain $rule_num
        else
            break
        fi
    done
}

# Function to clean all rules specific to an ESP
cleanup_iptables_for_esp() {
    local ns_name=$1
    local index=${ns_name#esp}
    echo "Cleaning all iptables rules for $ns_name..."

    # Remove INPUT rules with veth-h-$ns_name
    remove_all_matching_rules "INPUT" "" "veth-h-$ns_name"
    
    # Remove FORWARD rules with veth-h-$ns_name
    remove_all_matching_rules "FORWARD" "" "veth-h-$ns_name"
    
    # Remove FORWARD rules for the network 10.100.$index.0/24
    remove_all_matching_rules "FORWARD" "" "10.100.$index.0/24"
    
    # Remove NAT POSTROUTING rules for the network 10.100.$index.0/24
    remove_all_matching_rules "POSTROUTING" "nat" "10.100.$index.0/24"
}

# Function to clean global iptables rules
cleanup_global_iptables() {
    echo "Cleaning global iptables rules..."

    # Clean global FORWARD rules
    remove_all_matching_rules "FORWARD" "" "ctstate RELATED,ESTABLISHED"
    remove_all_matching_rules "FORWARD" "" "state RELATED,ESTABLISHED"
    
    # Remove rules for all networks 10.100
    remove_all_matching_rules "FORWARD" "" "10.100"
    remove_all_matching_rules "POSTROUTING" "nat" "10.100"
    
    # Remove rules for the wg0 interface
    remove_all_matching_rules "FORWARD" "" "wg0"
    
    # Remove all INPUT rules for veth
    remove_all_matching_rules "INPUT" "" "veth"
}

# Function to remove a specific nftables rule
cleanup_nft_rule() {
    local chain="$1"
    local table="$2"
    local pattern="$3"
    
    # Get the handle of the rule that matches the pattern
    local handles=$(nft -a list chain ip $table $chain | grep "$pattern" | grep -o "handle [0-9]*" | awk '{print $2}')
    
    for handle in $handles; do
        echo "Removing nftables rule in $table $chain (handle $handle) containing '$pattern'"
        nft delete rule ip $table $chain handle $handle
    done
}

# Function to clean nftables rules for a specific ESP
cleanup_nft_for_esp() {
    local ns_name=$1
    echo "Cleaning nftables rules for $ns_name..."
    
    # Clean INPUT rules for veth-h-$ns_name
    cleanup_nft_rule "INPUT" "filter" "iifname \"veth-h-$ns_name\""
    
    # Clean FORWARD rules for veth-h-$ns_name
    cleanup_nft_rule "FORWARD" "filter" "oifname \"veth-h-$ns_name\""
    cleanup_nft_rule "FORWARD" "filter" "iifname \"veth-h-$ns_name\""
}

cleanup_esp() {
    local name=$1
    local ns_name="esp${name#esp}"

    echo "Cleaning $name (namespace: $ns_name)..."

    # Stop ONLY the Tailscale instance of the namespace
    if [ -e "/var/run/tailscale-$ns_name.sock" ]; then
        ip netns exec $ns_name tailscale --socket=/var/run/tailscale-$ns_name.sock down 2>/dev/null
        pkill -f "tailscaled.*state=/var/lib/tailscale-$ns_name/state.json" 2>/dev/null
    fi

    # Remove ONLY the Tailscale files of the namespace
    rm -rf "/var/lib/tailscale-$ns_name"
    rm -f "/var/run/tailscale-$ns_name.sock"

    # Clean iptables rules for this ESP
    cleanup_iptables_for_esp "$ns_name"

    # Remove veth interfaces (one command suffices, the other interface will be removed automatically)
    ip link del "veth-h-$ns_name" 2>/dev/null

    # Remove the namespace
    ip netns del "$ns_name" 2>/dev/null

    # Remove the namespace DNS configuration
    rm -rf "/etc/netns/$ns_name"

    # Remove the ESP WireGuard keys
    rm -rf "$HOME/esp-keys/$name"

    # Clean nftables rules for this ESP
    cleanup_nft_for_esp "$ns_name"

    echo "Cleaning $name completed"
}

# Function to flush a completely a chain iptables
flush_chain() {
    local chain="$1"
    local table="$2"
    local table_opt=""
    
    if [ -n "$table" ]; then
        table_opt="-t $table"
    fi
    
    echo "Flushing completely the $chain ${table:+in the table $table}..."
    iptables $table_opt -F $chain 2>/dev/null
}

# Stop WireGuard (in the global space)
if ip link show wg0 &>/dev/null; then
    echo "Stopping WireGuard..."
    wg-quick down wg0
fi

if [ -z "$ESP_NAME" ]; then
    # Clean all ESPs
    echo "Cleaning all ESPs (the main Tailscale instance is not touched)..."
    
    # Find all esp* namespaces
    for ns in $(ip netns list | grep "esp" | cut -d' ' -f1); do
        cleanup_esp "${ns}"
    done

    # Clean global iptables rules
    cleanup_global_iptables

    # Remove the WireGuard configuration
    rm -f /etc/wireguard/wg0.conf
    rm -f /etc/wireguard/wg0.key
    rm -f /etc/wireguard/wg0.pub

    echo "Cleaning all ESPs completed"
else
    # Clean only the specified ESP
    cleanup_esp "$ESP_NAME"
    
    # Clean also the INPUT rules for veth, even in single ESP mode
    remove_all_matching_rules "INPUT" "" "veth-h-$ESP_NAME"
    
    echo "Note: The global WireGuard configuration has not been removed"
    echo "To remove it completely, run without argument: ./cleanup.sh"
fi

# Final cleaning of residual veth rules in INPUT
remove_all_matching_rules "INPUT" "" "veth"

# Additional attempts to clean stubborn rules
echo "Additional cleaning of stubborn rules..."

# 1. Direct and targeted removal
iptables -D INPUT -i veth-h-esp1 -j ACCEPT 2>/dev/null
iptables -D INPUT -i veth-h-esp1 -p 0 -j ACCEPT 2>/dev/null

# 2. If the veth rules persist, flush completely the INPUT chain
# and leave the default policy (usually ACCEPT)
if iptables -L INPUT -n | grep -q "veth"; then
    echo "Detected persistent veth rules, flushing completely the INPUT chain..."
    flush_chain "INPUT"
fi

# Final cleaning of stubborn rules with protocol 0
for veth in $(ip link show | grep 'veth' | cut -d: -f2 | cut -d@ -f1); do
    iptables -D INPUT -i $veth -p 0 -j ACCEPT 2>/dev/null
    iptables -D INPUT -i $veth -j ACCEPT 2>/dev/null
done

# Final verification
echo "Final verification:"
echo "----------------------------------"
echo "Remaining interfaces:"
ip link show | grep veth || echo "None"
echo "----------------------------------"
echo "Remaining namespaces:"
ip netns list | grep esp || echo "None"
echo "----------------------------------"
echo "Residual iptables INPUT rules for veth:"
iptables -L INPUT -n -v | grep veth || echo "None"
echo "----------------------------------"
echo "Residual iptables FORWARD rules for 10.100:"
iptables -L FORWARD -n -v | grep "10.100" || echo "None"
echo "----------------------------------"
echo "Residual iptables NAT rules:"
iptables -t nat -L POSTROUTING -n -v | grep "10.100" || echo "None"
echo "----------------------------------"