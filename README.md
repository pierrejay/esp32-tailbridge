# WireGuard-Tailscale bridge for ESP32

## Overview

This project solves a key limitation in IoT deployments: enabling ESP32 microcontrollers to participate in a Tailscale network despite not having the resources to run the Tailscale client directly. It enables secure remote access to ESP32 devices from anywhere, even when both machines are behind NAT, with unique IPs for each device.

## Problem Statement

Tailscale cannot run directly on microcontrollers like the ESP32 because:
- Limited processing power
- No full operating system
- Memory constraints

However, for IoT applications, we often need to:
- Access devices remotely from anywhere
- Navigate through NAT barriers
- Maintain secure connections
- Give each device a unique, stable IP address

## ESP32 WireGuard library

The ESP32 side uses a WireGuard client library adapted from ESPHome [implementation](https://github.com/esphome/esphome/tree/dev/esphome/components/wireguard) & [library](https://github.com/droscy/esp_wireguard). 

It requires a few flags to be defined (here in the `platformio.ini` file) for the connection to work properly:
```ini
build_flags = 
  -DCONFIG_WIREGUARD_MAX_SRC_IPS=4
  -DCONFIG_WIREGUARD_MAX_PEERS=1
```
By default, the library keeps the default network interface which will still be useable for incoming and outgoing requests while the WireGuard connection is established.
This library requires ESP32 Arduino Core 3.0+: [pioarduino](https://github.com/pioarduino/platform-espressif32)


## Solution Architecture

This project uses a Linux server acting as a proxy between the ESP32 devices and the Tailscale network. It should be exposed from where the ESP32s are located (or at least the WireGuard port), preferably with a fixed IP/hostname. If you are connecting the ESP32s within the same LAN as the proxy and plan to access them from the outside, you don't even need to setup NAT on your router as Tailscale handles NAT traversal (but in that case & if it's a private network such as home network, using WireGuard is probably overkill...).

The machine can be a low-cost Linux VPS or even a Raspberry Pi / home server. It doesn't need to be powerful, but can require quite some amount of RAM if you are planning to use the version with isolated Tailscale instances (see below) as each one will need around 80MB of RAM to work properly.

The following scripts were tested on Oracle & OVH Cloud entry-level VPS (Ubuntu 22.04 & 24.04, 1GB RAM, 1 vCPU) as well as a Raspberry Pi 3B+ (RPi OS 64-bit). They use `apt` commands to install the required packages so the scripts should work on any Debian-based system.

I describe two different approaches to solve this problem:

1. **Simple Method**: A single Tailscale instance on the proxy server with advertised routes to the WireGuard subnet
2. **Complex Method**: Multiple isolated Tailscale instances (one per ESP32) in separate network namespaces

## Simple Method (Route Advertisement)

### Architecture Overview

This approach uses a single Tailscale instance on the proxy server that advertises routes to the WireGuard subnet where ESP32 devices reside.

*Tailscale IP addresses are not real, just for illustration*
```mermaid
graph LR
    %% ESP32 devices grouping
    subgraph ESP32 [MCUs]
      direction LR
      ESP1(ESP32 #1)
      ESP2(ESP32 #2)
      ESPX(ESP32 #N)
    end

    %% Proxy server with WireGuard and a single Tailscale instance
    subgraph PROXY [WG+TS Proxy Server]
      direction TB
      WG(WireGuard<br>10.6.0.1/24)
      TS(Tailscale<br>100.83.127.46)
    end

    %% Tailnet central node
    TAILNET((Tailnet))

    %% Tailscale clients
      CLIENTA(Client A)
      CLIENTB(Client B)

    %% ESP32 to WireGuard connections
    ESP1 -->|10.6.0.2| WG
    ESP2 -->|10.6.0.3| WG
    ESPX -->|10.6.0.N+1| WG

    %% WireGuard to Tailscale connection
    WG --- TS

    %% Tailscale to Tailnet connection
    TS <-->|advertise-routes=10.6.0.0/24| TAILNET

    %% Client connections to Tailnet
    TAILNET <--> |100.76.204.153| CLIENTA 
    TAILNET <--> |100.118.92.211| CLIENTB
```

### Key Characteristics

- **Simplicity**: Requires only one Tailscale instance
- **Lower resource usage**: Minimal memory footprint
- **Limitation**: ESP32 devices appear as subnets behind the proxy, not as individual Tailscale nodes
- **Access pattern**: Other Tailscale nodes reach ESP32s through the proxy's Tailscale IP (e.g., `100.x.y.z → 10.6.0.2`)

### Server Configuration

#### WireGuard Server Setup

1. Install WireGuard
```bash
apt-get update && apt-get install -y wireguard
```

2. Generate server keys
```bash
cd /etc/wireguard
wg genkey | tee wg0.key | wg pubkey > wg0.pub
```

3. Create WireGuard configuration
```bash
cat > /etc/wireguard/wg0.conf << EOF
[Interface]
Address = 10.6.0.1/24
SaveConfig = true
ListenPort = 51820
PrivateKey = $(cat wg0.key)

# ESP32 #1
[Peer]
PublicKey = <ESP32_PUBLIC_KEY>
AllowedIPs = 10.6.0.2/32
PersistentKeepalive = 25
EOF
```

4. Start WireGuard
```bash
sudo wg-quick up wg0
```

#### Tailscale Configuration

1. Install Tailscale
```bash
curl -fsSL https://tailscale.com/install.sh | sh
```

2. Start Tailscale with route advertisement
```bash
sudo tailscale up --advertise-routes=10.6.0.0/24
```

3. Enable IP forwarding
```bash
sudo sysctl -w net.ipv4.ip_forward=1
# To make it permanent, add in /etc/sysctl.conf: net.ipv4.ip_forward = 1
```

4. Make sure the WireGuard port is accessible from the outside
```bash
# If you have a firewall (like UFW), allow UDP port 51820
sudo ufw allow 51820/udp

# If you're behind NAT, ensure port 51820 is forwarded to this server
# This is typically done in your router's configuration
```

5. Accept the advertised routes in the Tailscale admin console (https://login.tailscale.com/admin/machines)

6. Configure packet forwarding between Tailscale and WireGuard interfaces
```bash
# Enable IP forwarding between interfaces
sudo iptables -A FORWARD -i tailscale0 -o wg0 -j ACCEPT
sudo iptables -A FORWARD -i wg0 -o tailscale0 -j ACCEPT

# Set up masquerading to handle the routing correctly
sudo iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE
sudo iptables -t nat -A POSTROUTING -o tailscale0 -j MASQUERADE

# Make these rules persistent (requires iptables-persistent)
sudo apt-get install -y iptables-persistent
sudo netfilter-persistent save
```

If you want to precisely control which ports are accessible on which ESP32 devices, you can use more restrictive iptables rules. The default configuration above allows all traffic, but you can be more selective:

```bash
# Remove generic FORWARD rules (if they already exist)
sudo iptables -D FORWARD -i tailscale0 -o wg0 -j ACCEPT
sudo iptables -D FORWARD -i wg0 -o tailscale0 -j ACCEPT

# Allow only port 80 (HTTP) to ESP32 #1 (10.6.0.2)
sudo iptables -A FORWARD -i tailscale0 -o wg0 -d 10.6.0.2 -p tcp --dport 80 -j ACCEPT
sudo iptables -A FORWARD -i wg0 -o tailscale0 -s 10.6.0.2 -p tcp --sport 80 -j ACCEPT

# Allow only ports 80 and 8080 to ESP32 #2 (10.6.0.3)
sudo iptables -A FORWARD -i tailscale0 -o wg0 -d 10.6.0.3 -p tcp --dport 80 -j ACCEPT
sudo iptables -A FORWARD -i wg0 -o tailscale0 -s 10.6.0.3 -p tcp --sport 80 -j ACCEPT
sudo iptables -A FORWARD -i tailscale0 -o wg0 -d 10.6.0.3 -p tcp --dport 8080 -j ACCEPT
sudo iptables -A FORWARD -i wg0 -o tailscale0 -s 10.6.0.3 -p tcp --sport 8080 -j ACCEPT

# Allow MQTT protocol (port 1883) to ESP32 #3 (10.6.0.4)
sudo iptables -A FORWARD -i tailscale0 -o wg0 -d 10.6.0.4 -p tcp --dport 1883 -j ACCEPT
sudo iptables -A FORWARD -i wg0 -o tailscale0 -s 10.6.0.4 -p tcp --sport 1883 -j ACCEPT

# Allow ping (ICMP) to all ESP32 devices
sudo iptables -A FORWARD -i tailscale0 -o wg0 -p icmp -j ACCEPT
sudo iptables -A FORWARD -i wg0 -o tailscale0 -p icmp -j ACCEPT

# Block everything else by default (if your default policy isn't DROP)
# sudo iptables -A FORWARD -i tailscale0 -o wg0 -j DROP

# Make these rules persistent
sudo netfilter-persistent save
```

7. Verify routing is working by pinging an ESP32 device from another Tailscale node. You can also use the `sudo wg show` command to check if a handshake happened on the WireGuard link.

### ESP32 Configuration

Similar to the other method, the ESP32 connects to the WireGuard server:

```cpp
#include <Arduino.h>
#include <ESPAsyncWebServer.h>
#include <ESP32-WireGuard.h>

static WireGuard wg;

// Configuration parameters
static const IPAddress WG_LOCAL_IP("10.6.0.2");
static const IPAddress WG_SUBNET("255.255.255.255");
static const IPAddress WG_GATEWAY("192.168.0.1");
static const char* WG_PRIVATE_KEY = "PRIVATE_KEY_HERE";
static const char* WG_ENDPOINT_ADDRESS = "YOUR_SERVER_IP";
static const char* WG_ENDPOINT_PUBLIC_KEY = "PUBLIC_KEY_HERE";
static const uint16_t WG_ENDPOINT_PORT = 51820;

AsyncWebServer server(80);

void setup() {
  // Initialize WireGuard connection
  wg.begin(
    WG_LOCAL_IP,
    WG_SUBNET,
    WG_GATEWAY,
    WG_PRIVATE_KEY,
    WG_ENDPOINT_ADDRESS,
    WG_ENDPOINT_PUBLIC_KEY,
    WG_ENDPOINT_PORT
  );
  
  // Setup web server routes
  server.on("/", HTTP_GET, [](AsyncWebServerRequest *request){
    request->send(200, "text/plain", "Hello from ESP32!");
  });
  
  server.begin();
}

void loop() {
  // WireGuard connection is handled automatically
  delay(100);
}
```

### Accessing ESP32 Devices

From other Tailscale nodes, access the ESP32 devices using their WireGuard IPs:
- ESP32 #1: `10.6.0.2`
- ESP32 #2: `10.6.0.3`
- And so on...

The proxy server routes traffic between the Tailscale and WireGuard networks automatically.

### Advantages of the Simple Method

- **Easy setup**: Minimal configuration required
- **Low resource usage**: Only one Tailscale instance needed
- **Efficient**: Works well for many ESP32 devices with minimal overhead
- **Simplified management**: Single point of administration

### Limitations of the Simple Method

- **Indirect routing**: ESP32s aren't directly visible as Tailscale nodes
- **Single point of failure**: If the Tailscale connection drops, all ESP32s lose connectivity
- **Less isolation**: All ESP32s share the same routing infrastructure

## Complex Method (Multiple Tailscale Instances)

### Architecture Overview

*Tailscale IP addresses are not real, just for illustration*
```mermaid
graph LR
    %% Regroupement des dispositifs ESP32
    subgraph ESP32 [MCUs]
      direction LR
      ESP1(ESP32 #1)
      ESP2(ESP32 #2)
      ESPX(ESP32 #N)
    end

    %% Serveur Proxy hébergeant les instances Tailscale
    subgraph PROXY [WG+TS Proxy Server]
      direction TB
      WG(WireGuard<br>10.6.0.1/24)
      TS1(Tailscale #1)
      TS2(Tailscale #2)
      TSX(Tailscale #N)
    end

    %% Noeud central Tailnet
    TAILNET((Tailnet))

    %% Regroupement des clients Tailscale
      CLIENTA(Client A)
      CLIENTB(Client B)

    %% Connexions ESP32 vers WireGuard
    ESP1 -->|10.6.0.2| WG
    ESP2 -->|10.6.0.3| WG
    ESPX -->|10.6.0.N+1| WG

    %% Connexions du serveur WireGuard vers les instances Tailscale
    WG --> TS1
    WG --> TS2
    WG --> TSX

    %% Connexions des instances Tailscale vers Tailnet
    TS1 <-->|100.83.127.46| TAILNET
    TS2 <-->|100.102.215.78| TAILNET
    TSX <-->|100.95.168.39| TAILNET

    %% Connexions des clients vers Tailnet
    TAILNET <-->|100.76.204.153| CLIENTA 
    TAILNET <-->|100.118.92.211| CLIENTB
```

The solution uses a Linux proxy server that:

1. Runs a WireGuard server that ESP32s connect to
2. Creates isolated network namespaces for each ESP32
3. Runs a separate Tailscale instance in each namespace
4. Routes traffic between WireGuard and Tailscale interfaces

This approach makes each ESP32 appear as a distinct machine in your Tailnet (unlike the simple solution using `--advertise-routes`), with its own IP address.

### Key Components

- **ESP32 Side**: Uses a WireGuard client library to connect to the proxy server
- **Proxy Server**: 
  - Runs Linux with WireGuard and Tailscale installed
  - Uses network namespaces for isolation
  - Manages routing between interfaces
  - Exposes each ESP32 as a unique Tailscale device

### Benefits

- **Security**: Both WireGuard and Tailscale are well-established secure protocols
- **Scalability**: 
  - 20+ ESP32 devices on the smallest servers (~5 €/month)
  - Easy to scale across multiple servers: proxies are transparent to other Tailscale devices
- **Transparency**: 
  - Other machines in your Tailnet see the ESP32 devices as direct Tailscale nodes. 
  - The Tailscale configuration in each namespace is totally independent & only relies on the auth key provided during commissioning, which means it can even expose Tailscale routes without having access to their host account. There's no dependency on the server's Tailscale login, so a single proxy could theoretically serve ESP32 devices across multiple users/organizations using their respective auth keys.
- **Firewall-friendly**: Works through NAT and restrictive firewalls
- **Low overhead**: Minimal resource requirements on the ESP32

## Implementation Details

### Proxy Server Setup

The proxy server configuration is handled through a series of shell scripts:

1. `setup-esp32.sh`: Main entry point that orchestrates the setup process
2. `isolate-tailscale.sh`: Creates isolated network namespaces
3. `setup-wireguard.sh`: Configures the WireGuard server
4. `run-tailscale-namespace.sh`: Starts Tailscale in the isolated namespace
5. `setup-internal-routing.sh`: Creates routing between interfaces
6. `cleanup.sh`: Removes configurations for cleanup

An additional script `wireguard-monitor.py` is only used for tests. When reconnecting an ESP32 quickly when behind a NAT, it can get an origin port unknown to the WireGuard server for its public key & IP, which it won't update immediately in its configuration. This can cause the ESP32 to be unable to connect for a random amount of time. The script avoids this issue by monitoring the WireGuard connection and reloading it when it detects packets coming from a legit IP with a different, unregistered origin port, which enables the ESP32 to connect quickly after a few handshake attempts.

### ESP32 Test Code

The example implementation includes:

- WireGuard connection management
- Basic HTTP server for testing
- Connection monitoring and auto-reconnection

```cpp
#include <Arduino.h>
#include <ESPAsyncWebServer.h>
#include <ESP32-WireGuard.h>

static WireGuard wg;

// Configuration parameters
static const IPAddress WG_LOCAL_IP("10.6.0.2");
static const IPAddress WG_SUBNET("255.255.255.255");
static const IPAddress WG_GATEWAY("192.168.0.1");
static const char* WG_PRIVATE_KEY = "PRIVATE_KEY_HERE";
static const char* WG_ENDPOINT_ADDRESS = "YOUR_SERVER_IP";
static const char* WG_ENDPOINT_PUBLIC_KEY = "PUBLIC_KEY_HERE";
static const uint16_t WG_ENDPOINT_PORT = 51820;

AsyncWebServer server(80);

void setup() {
  // Initialize WireGuard connection
  wg.begin(
    WG_LOCAL_IP,
    WG_SUBNET,
    WG_GATEWAY,
    WG_PRIVATE_KEY,
    WG_ENDPOINT_ADDRESS,
    WG_ENDPOINT_PUBLIC_KEY,
    WG_ENDPOINT_PORT
  );
  
  // Setup web server routes
  server.on("/", HTTP_GET, [](AsyncWebServerRequest *request){
    request->send(200, "text/plain", "Hello from ESP32!");
  });
  
  server.begin();
}

void loop() {
  // WireGuard connection is handled automatically
  delay(100);
}
```

## Setup Instructions

### Prerequisites

- A Linux server (e.g. Ubuntu 22.04) with
  - WireGuard
  - Tailscale
  - Python 3.x
  (will be installed by the scripts if not present)
- PlatformIO + ESP32 Arduino Core 3.0+: [pioarduino](https://github.com/pioarduino/platform-espressif32)

### Server Setup (Complex Method)

1. Clone the repository to your server
2. Make sure the WireGuard port is accessible from the outside
```bash
# If you have a firewall (like UFW), allow UDP port 51820
sudo ufw allow 51820/udp

# If you're behind NAT, ensure port 51820 is forwarded to this server
# This is typically done in your router's configuration
```
3. Run the setup script for each ESP32 device:

```bash
sudo ./setup-esp32.sh <esp_name>
```

3. When prompted, get a Tailscale authentication key from your [Tailscale admin console](https://login.tailscale.com/admin/settings/keys)
4. The script will generate a WireGuard configuration for your ESP32
5. The Tailscale node for ESP32 will be commissioned and appear in your Tailscale admin panel

### ESP32 Setup

1. Copy the WireGuard configuration parameters from the server output
2. Insert the parameters into your ESP32 code:
   - Private key
   - Local IP address
   - Endpoint address and port
   - Endpoint public key
3. Compile and upload the code to your ESP32
4. Let it connect to the WireGuard server and handle requests from other Tailscale nodes

Note: in case you want the default network interface (non-VPN) to be used for outbound requests from the ESP, use the `WIREGUARD_KEEP_DEFAULT_NETIF` flag (e.g. to the platformio.ini file or in `ESP32-WireGuard.h`). 

## How It Works (Complex Method)

- Each ESP32 gets its own isolated Linux network namespace
- A separate Tailscale instance runs in each namespace
- ESP32 connects via WireGuard to the server
- Traffic is seamlessly routed between interfaces with DNAT / `iptables` rules
- Both WireGuard and Tailscale handle NAT traversal

## Testing and Verification

Once setup is complete, you can test the connection:

1. **ESP32 Web Server Test**: Access the ESP32's web server from another Tailscale device using its Tailscale IP address
2. **Ping Test**: Ping the ESP32 from another Tailscale device
3. **Monitoring Connection**: Check the WireGuard connection status on the server

```bash
# Check WireGuard status
sudo wg show

# Check Tailscale status for a specific namespace (Complex Method)
sudo ip netns exec esp1 tailscale --socket=/var/run/tailscale-esp1.sock status
```

## Scaling Considerations

- **Single Server Scaling**: A small VPS can typically handle 40+ ESP32 devices w/ 4 GB RAM since each Tailscale instance eats up around 80 MB of RAM
- **Multiple Server Scaling**: The architecture is inherently distributed
- **Resource Requirements**:
  - Each namespace adds minimal overhead
  - Main limitation is typically network bandwidth, not CPU or memory (but can be a problem if you're adding a lot of isolated instances with the 2nd method).

## Troubleshooting

### Common Issues

1. **ESP32 Cannot Connect to WireGuard Server**:
   - Check firewall settings on the server
   - Verify the ESP32 has internet connectivity
   - Check that UDP port 51820 is open on the server

2. **Tailscale Instance Not Appearing Online**:
   - Check if the namespace was created correctly
   - Verify the Tailscale authorization key is valid
   - Check tailscaled logs in the namespace

3. **Routing Issues**:
   - Verify iptables rules are set correctly
   - Check that IP forwarding is enabled on the server
   - Verify the network interface configurations

### Diagnostic Commands

```bash
# Check namespace existence
ip netns list | grep esp

# Check interfaces in a namespace
ip netns exec esp1 ip addr

# Check routing in a namespace
ip netns exec esp1 ip route

# View iptables rules
sudo iptables -L -v
sudo iptables -t nat -L -v

# Check WireGuard connections
sudo wg show
```

## Cleanup

To remove all configurations for a specific ESP32:

```bash
sudo ./cleanup.sh <esp_name>
```

To remove all configurations:

```bash
sudo ./cleanup.sh
```

## Advanced Configuration

### Port Forwarding

By default, the setup only forwards HTTP traffic (port 80). To forward additional ports:

1. Edit `setup-internal-routing.sh`
2. Add additional DNAT rules for the desired ports

Example for forwarding TCP port 8080:

```bash
# Add in setup-internal-routing.sh
ip netns exec $NS_NAME iptables -t nat -A PREROUTING -i tailscale-netns -p tcp --dport 8080 -j DNAT --to-destination $ESP_IP:8080
```

## Choosing between the simple and complex methods

### When to use the Simple Method

- **You have limited server resources**: The simple method requires significantly less memory
- **You don't need individual device identity in Tailscale**: All ESP32s appear behind a single proxy node
- **You want the simplest possible setup**: Fewer components to configure and maintain
- **You're managing a small number of devices**: Easier to keep track of the WireGuard IPs

### When to use the Complex Method

- **You need each ESP32 to have its own Tailscale identity**: Each ESP32 appears as a separate node in your Tailnet
- **You need multi-organization support**: Different ESP32s can be part of different Tailscale organizations
- **You need fine-grained access control**: Tailscale ACLs can be applied to individual ESP32 devices
- **You want to scale to many devices**: Better isolation and management for large deployments

## A Note about the "complex method" (multiple Tailscale instances)

Just a heads up — I built the complex method as a fun weekend project, and while it works, it's definitely not production-ready yet. It doesn't survive server reboots, and you'll need to manually restart everything if your server goes down. Also worth noting: this works great with the official Tailscale service, but I've had some trouble getting it to play nicely with custom Headscale setups. I'm not sure exactly why, and honestly don't have the time to spend hours debugging it so I suggest the "simple method" that will work reliably in this case even if it's less flexible.

If you're actually using this and find it useful, I'd love some help making it more robust! The core idea works great, but it needs some work to become something you'd actually want to run in production. If you're interested, please jump in! I'd be super grateful for any contributions. This was mostly a "let's see if this works" kind of project that turned out to be pretty handy, but could be so much better with a few more hands on deck.

## Conclusion

This solution allows IoT-enabled microcontrollers like ESP32 fully participating in Tailscale networks, providing secure remote access with unique IPs. The architecture is scalable, transparent to other Tailscale devices, and works reliably across NAT boundaries.

By using either the simple approach with route advertising or the complex approach with network namespaces, we overcome the hardware limitations of microcontrollers while still benefiting from Tailscale's secure networking capabilities.