#ifndef ESP_WIRE_GUARD_H
#define ESP_WIRE_GUARD_H

#include <Arduino.h>
#include <IPAddress.h>

// Define this constant ourselves if it's not found
#ifndef WIREGUARDIF_INVALID_INDEX
#define WIREGUARDIF_INVALID_INDEX (0xFF)
#endif

extern "C" {
#include "esp_wireguard.h"
#include "wireguardif.h"
#include "wireguard-platform.h"
}

class EspWireGuard {
private:
    bool _is_initialized = false;
    struct netif _wg_netif_struct = {0};
    struct netif *_wg_netif = NULL;
    struct netif *_previous_default_netif = NULL;
    uint8_t _wireguard_peer_index = WIREGUARDIF_INVALID_INDEX;
    String _address_str;
    String _netmask_str;
    
    // Initialisation to zero instead of using macros that cause problems
    wireguard_ctx_t _wg_ctx = {0};
    wireguard_config_t _wg_config = {0};

    unsigned long _last_handshake = 0;

    TaskHandle_t _monitor_task_handle = nullptr;
    unsigned long _disconnect_time = 0;
    unsigned long _last_reconnect_attempt = 0;
    uint8_t _reconnect_attempt = 0;
    static const unsigned long MAX_BACKOFF_TIME = 300000; // 5 minutes max
    
    static void MonitorTask(void* parameter);
    void reconnect();

public:
    EspWireGuard() {}
    ~EspWireGuard() { end(); }

    // Full version compatible with ESPHome implementation
    bool begin(const IPAddress& localIP, const IPAddress& subnet, const IPAddress& gateway, 
              const char* privateKey, const char* remotePeerAddress, 
              const char* remotePeerPublicKey, uint16_t remotePeerPort);
    
    // Version compatible with the old API
    bool begin(const IPAddress& localIP, const char* privateKey, 
              const char* remotePeerAddress, const char* remotePeerPublicKey, 
              uint16_t remotePeerPort);
    
    void end();
    bool isConnected();
    void dump_config();
    time_t get_latest_handshake();
    void check_connection();
};

#endif // ESP_WIRE_GUARD_H