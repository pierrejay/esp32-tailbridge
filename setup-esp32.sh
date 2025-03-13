#!/bin/bash
# Usage: sudo ./setup-esp32.sh <esp_name>

# Check root privileges
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run with sudo"
    exit 1
fi

# Function to install dependencies
install_dependencies() {
    echo "Installing dependencies..."
    
    # Update packages
    apt-get update

    # Install WireGuard
    if ! command -v wg >/dev/null 2>&1; then
        echo "Installing WireGuard..."
        apt-get install -y wireguard
    fi

    # Install DNS tools (dig, nslookup)
    if ! command -v dig >/dev/null 2>&1; then
        echo "Installing DNS tools..."
        apt-get install -y dnsutils
    fi

    # Install curl
    if ! command -v curl >/dev/null 2>&1; then
        echo "Installing curl..."
        apt-get install -y curl
    fi

    # Install Tailscale
    if ! command -v tailscale >/dev/null 2>&1; then
        echo "Installing Tailscale..."
        curl -fsSL https://tailscale.com/install.sh | sh
    fi

    # Install network tools (for ip, iptables, etc.)
    if ! command -v ip >/dev/null 2>&1; then
        echo "Installing network tools..."
        apt-get install -y iproute2
    fi

    # Install iptables
    if ! command -v iptables >/dev/null 2>&1; then
        echo "Installing iptables..."
        apt-get install -y iptables
    fi
}

# Check and install dependencies
echo "Checking dependencies..."
MISSING_DEPS=0

# List of required commands
REQUIRED_COMMANDS=(
    "wg"        # WireGuard
    "dig"       # DNS utils
    "curl"      # For downloads
    "tailscale" # Tailscale
    "ip"        # iproute2
    "iptables"  # iptables
)

# Check each command
for cmd in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Missing command: $cmd"
        MISSING_DEPS=1
    fi
done

# Installer les dépendances si nécessaire
if [ "$MISSING_DEPS" -eq 1 ]; then
    echo "Missing dependencies."
    read -p "Do you want to install them now? (o/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Oo]$ ]]; then
        install_dependencies
    else
        echo "Installation cancelled. The script cannot continue without dependencies."
        exit 1
    fi
fi

# Make all scripts executable
chmod +x "$(dirname "$0")"/*.sh

ESP_NAME=$1
if [ -z "$ESP_NAME" ]; then
  echo "Usage: sudo $0 <esp_name>"
  exit 1
fi

# Determine the next available index
NEXT_INDEX=$(ip netns list | grep -c "esp")
NEXT_INDEX=$((NEXT_INDEX + 1))


# Generate a WireGuard IP for the ESP32
ESP_IP="10.6.0.$((NEXT_INDEX + 1))"
NS_NAME="esp$NEXT_INDEX"

# Delete old rules that might interfere
iptables -D FORWARD -i wg0 -o veth-h-$NS_NAME -j ACCEPT 2>/dev/null
iptables -D FORWARD -i veth-h-$NS_NAME -o wg0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null

# Get the real home directory of the user who launched sudo
REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)

# Generate WireGuard keys for the ESP32
mkdir -p "$REAL_HOME/esp-keys/$ESP_NAME"
wg genkey | tee "$REAL_HOME/esp-keys/$ESP_NAME/private.key" | wg pubkey > "$REAL_HOME/esp-keys/$ESP_NAME/public.key"
ESP_PUBKEY=$(cat "$REAL_HOME/esp-keys/$ESP_NAME/public.key")

# Get a Tailscale authentication key
echo "Get an authentication key from the Tailscale console:"
echo "https://login.tailscale.com/admin/settings/keys"
read -p "Enter the authentication key: " AUTHKEY

# 1. Create and configure the Tailscale namespace
./isolate-tailscale.sh $NS_NAME $NEXT_INDEX

# Check DNS connectivity
echo "Checking DNS connectivity in the namespace..."
if ! ip netns exec $NS_NAME ping -c 1 8.8.8.8 > /dev/null 2>&1; then
    echo "Error: No Internet connectivity in the namespace"
    exit 1
fi

if ! ip netns exec $NS_NAME nslookup google.com > /dev/null 2>&1; then
    echo "Error: DNS resolution failed in the namespace"
    exit 1
fi

# 2. Configure WireGuard (in the global space)
./setup-wireguard.sh $ESP_NAME $ESP_PUBKEY $ESP_IP

# 3. Start Tailscale in the namespace (without advertise-routes)
./run-tailscale-namespace.sh $NS_NAME "$ESP_NAME" "$AUTHKEY"

# 4. Configure routing between WireGuard and the Tailscale namespace
./setup-internal-routing.sh $NS_NAME $ESP_IP

echo "----------------------------------------"
echo "Configuration completed for $ESP_NAME"
echo "ESP32 IP (WireGuard): $ESP_IP"
echo "WireGuard configuration for ESP32:"
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
