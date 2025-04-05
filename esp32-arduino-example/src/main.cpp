#include <Arduino.h>
#include <ESPAsyncWebServer.h>
#include <EspWireGuard.h>

static EspWireGuard wg;

// Chose which interface to use
// #define WG_USE_WIFI
#define WG_USE_ETH

// Definition of pins
#ifdef WG_USE_ETH
  #include <EthernetESP32.h>
  static constexpr int ETH_MOSI = 11;
  static constexpr int ETH_MISO = 12;
  static constexpr int ETH_CLK = 13;
  static constexpr int ETH_CS = 14;
  static constexpr int ETH_INT = 10;
  static constexpr int ETH_RST = 9;
  W5500Driver driver(ETH_CS, ETH_INT, ETH_RST);
#endif

// Definition of WireGuard parameters
// Signature: begin(const IPAddress& localIP, const IPAddress& Subnet, const IPAddress& Gateway, const char* privateKey, const char* remotePeerAddress, const char* remotePeerPublicKey, uint16_t remotePeerPort)
static const IPAddress WG_LOCAL_IP("client_wireguard_ip"); // Normally 10.6.0.2++ with the scripts
static const IPAddress WG_SUBNET("client_wireguard_subnet"); // Normally 255.255.255.255 with the scripts
static const IPAddress WG_GATEWAY("local_gateway_ip"); // Can be captured from WiFi/ETH initialisation
static const char* WG_PRIVATE_KEY = "client_private_key"; // Displayed at end of shell scripts
static const char* WG_ENDPOINT_ADDRESS = "server_ip_address"; // Displayed at end of shell scripts
static const char* WG_ENDPOINT_PUBLIC_KEY = "server_public_key"; // Displayed at end of shell scripts
static const uint16_t WG_ENDPOINT_PORT = 51820; // Displayed at end of shell scripts

AsyncWebServer server(80);

void setup() {
  Serial.begin(115200);
  delay(2000);
  Serial.println("== ESP32-TAILBRIDGE ==");

  // Configure the log level for wireguardif
  esp_log_level_set("wireguardif", ESP_LOG_DEBUG);  // or ESP_LOG_DEBUG for more details

  #ifdef WG_USE_ETH
    SPI.begin(ETH_CLK, ETH_MISO, ETH_MOSI);
    driver.setSPI(SPI);
    Ethernet.init(driver);

    //Generate a MAC address
    uint8_t mac[6] = {0x02, 0x00, 0x00, 0x00, 0x00, 0x01};
    
    //Start Ethernet
    if (Ethernet.begin(mac)) {
        Serial.println("Ethernet configured via DHCP");
        Serial.print("IP: ");
        Serial.println(Ethernet.localIP());
      } else {
        Serial.println("DHCP configuration failed");
    }

    // Wait for the interface to be really ready
    delay(1000);
    
    // Debug the network interfaces
    struct netif *n;
    Serial.println("Network interfaces available :");
    NETIF_FOREACH(n) {
        Serial.printf("  - Interface %c%c%d : ", n->name[0], n->name[1], n->num);
        Serial.printf("IP: %s ", ip4addr_ntoa(&n->ip_addr.u_addr.ip4));
        Serial.printf("Status: %s ", netif_is_up(n) ? "UP" : "DOWN");
        Serial.printf("Link: %s\n", netif_is_link_up(n) ? "UP" : "DOWN");
    }
    
    // Check if the Ethernet interface is the default interface
    Serial.printf("Default interface : %s\n", 
                 netif_default ? ip4addr_ntoa(&netif_default->ip_addr.u_addr.ip4) : "None");
  #endif

  #ifdef WG_USE_WIFI
    WiFi.setSleep(WIFI_PS_NONE); // Disable WiFi sleep mode for better latency
    WiFi.begin("SSID", "PASSWORD");
    while (WiFi.status() != WL_CONNECTED) {
      delay(1000);
      Serial.println("WiFi connection...");
    }
    Serial.println("WiFi connection successful");
    Serial.print("IP: ");
    Serial.println(WiFi.localIP());
  #endif

  server.on("/", HTTP_GET, [](AsyncWebServerRequest *request){
    Serial.printf("[HTTP] GET / from %s\n", request->client()->remoteIP().toString().c_str());
    request->send(200, "text/plain", "Hello World");
  });


  server.begin();

  Serial.println("Server started");

  configTime(0, 0, "ntp.jst.mfeed.ad.jp", "ntp.nict.jp", "time.google.com");

  bool ret = wg.begin(
    WG_LOCAL_IP,                        // IP address of the Wireguard interface
    WG_SUBNET,                           // Subnet of the Wireguard interface
    WG_GATEWAY,                         // Gateway of the local interface
    WG_PRIVATE_KEY,                  // ESP32 Wireguard private key
    WG_ENDPOINT_ADDRESS,      // Wireguard endpoint peer IP address.
    WG_ENDPOINT_PUBLIC_KEY, // Wireguard endpoint peer public key.
    WG_ENDPOINT_PORT             // Wireguard endpoint peer port.
  );     

  if (ret) {
    Serial.println("WireGuard started");
    wg.dump_config();  // Display the configuration
  } else {
    Serial.println("WireGuard failed to start");    
  }
}

void loop() {
    // WireGuard library automatically handles connection
    vTaskDelete(NULL);
}