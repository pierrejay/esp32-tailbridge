#include "EspWireGuard.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "lwip/tcpip.h"
#include "lwip/err.h"
#include "lwip/sys.h"
#include "lwip/ip.h"
#include "lwip/netdb.h"

#define TAG "EspWireGuard"

bool EspWireGuard::begin(const IPAddress& localIP, const IPAddress& subnet, const IPAddress& gateway,
                     const char* privateKey, const char* remotePeerAddress, 
                     const char* remotePeerPublicKey, uint16_t remotePeerPort) {
    
    if (_is_initialized) {
        end();
    }

    // WireGuard configuration
    _address_str = localIP.toString();
    _netmask_str = subnet.toString();
    
    _wg_config.private_key = privateKey;
    _wg_config.address = _address_str.c_str();
    _wg_config.netmask = _netmask_str.c_str();
    _wg_config.endpoint = remotePeerAddress;
    _wg_config.public_key = remotePeerPublicKey;
    _wg_config.port = remotePeerPort;
    _wg_config.persistent_keepalive = 25;
    
    // Check if the endpoint is a literal IP address
    ip_addr_t temp;
    if(ipaddr_aton(remotePeerAddress, &temp)) {
        // If it's a literal IP address, assign it directly
        ip_addr_copy(_wg_config.endpoint_ip, temp);
    }
    // Otherwise, the DNS resolution will be handled by esp_wireguard_init
    
    // Initialize the platform
    if (wireguard_platform_init() != ESP_OK) {
        log_e("Failed to initialize the WireGuard platform");
        return false;
    }
    
    // Initialize WireGuard
    esp_err_t err = esp_wireguard_init(&_wg_config, &_wg_ctx);
    if (err != ESP_OK) {
        log_e("Failed to initialize WireGuard: %d", err);
        return false;
    }
    
    // Connect to WireGuard
    err = esp_wireguard_connect(&_wg_ctx);
    if (err != ESP_OK) {
        if (err == ESP_ERR_RETRY) {
            log_w("DNS resolution in progress, connection postponed");
            // We could put in place an automatic reconnection here
        } else {
            log_e("Failed to connect to WireGuard: %d", err);
            return false;
        }
    }
    
    // Add a default route via the WireGuard interface
    err = esp_wireguard_set_default(&_wg_ctx);
    if (err != ESP_OK) {
        log_e("Failed to configure the default route: %d", err);
        return false;
    }
    
    // Add a route for all traffic (0.0.0.0/0)
    err = esp_wireguard_add_allowed_ip(&_wg_ctx, "0.0.0.0", "0.0.0.0");
    if (err != ESP_OK) {
        log_e("Failed to add the allowed route: %d", err);
        return false;
    }
    
    _is_initialized = true;

    // Create the monitoring task - ADD THIS CODE AT THE END
    // Deprecated for now (the WG library looks to be handling reconnection fine by itself)
    //
    // xTaskCreate(
    //     MonitorTask,
    //     "WG_Monitor",
    //     4096,        // Stack size
    //     this,        // Parameter = pointer to the instance
    //     5,           // Priority (1-24)
    //     &_monitor_task_handle
    // );
    
    // if (_monitor_task_handle == nullptr) {
    //     log_e("Failed to create the WireGuard monitoring task");
    // } else {
    //     log_i("WireGuard monitoring task started");
    // }
    
    return true;
}

bool EspWireGuard::begin(const IPAddress& localIP, const char* privateKey, 
                     const char* remotePeerAddress, const char* remotePeerPublicKey, 
                     uint16_t remotePeerPort) {
    // This version uses the full version with default values
    IPAddress subnet(255, 255, 255, 255);
    IPAddress gateway(0, 0, 0, 0);
    return begin(localIP, subnet, gateway, privateKey, remotePeerAddress, remotePeerPublicKey, remotePeerPort);
}

void EspWireGuard::end() {
    if (!_is_initialized) return;

    // Stop the monitoring task if it exists
    if (_monitor_task_handle != nullptr) {
        vTaskDelete(_monitor_task_handle);
        _monitor_task_handle = nullptr;
    }

    esp_wireguard_disconnect(&_wg_ctx);
    _is_initialized = false;
}

bool EspWireGuard::isConnected() {
    if (!_is_initialized) return false;
    return (esp_wireguard_peer_is_up(&_wg_ctx) == ESP_OK);
}

void EspWireGuard::dump_config() {
    log_i("WireGuard Configuration:");
    log_i("  Address: %s", _wg_config.address);
    log_i("  Netmask: %s", _wg_config.netmask);
    log_i("  Private Key: %s", _wg_config.private_key);
    log_i("  Peer Endpoint: %s", _wg_config.endpoint);
    log_i("  Peer Port: %d", _wg_config.port);
    log_i("  Peer Public Key: %s", _wg_config.public_key);
    
    // Check if a pre-shared key is configured
    if (_wg_config.preshared_key != nullptr) {
        log_i("  Peer Pre-shared Key: %s", _wg_config.preshared_key);
    } else {
        log_i("  Peer Pre-shared Key: NOT IN USE");
    }
    
    // Display the connection status
    log_i("  Connection Status: %s", isConnected() ? "CONNECTED" : "DISCONNECTED");
    
    // Display the keepalive
    log_i("  Peer Persistent Keepalive: %d%s", 
          _wg_config.persistent_keepalive,
          (_wg_config.persistent_keepalive > 0 ? "s" : " (DISABLED)"));

    // Display the resolved endpoint IP
    char ip_str[INET_ADDRSTRLEN];
    ipaddr_ntoa_r(&_wg_config.endpoint_ip, ip_str, INET_ADDRSTRLEN);
    log_i("  Resolved Endpoint IP: %s", ip_str);
}

time_t EspWireGuard::get_latest_handshake() {
    time_t result;
    if (esp_wireguard_latest_handshake(&_wg_ctx, &result) != ESP_OK) {
        result = 0;
    }
    return result;
}

void EspWireGuard::check_connection() {
    if (!_is_initialized) return;
    
    esp_err_t peer_status = esp_wireguard_peer_is_up(&_wg_ctx);
    
    // Check the connection status
    if (peer_status != ESP_OK) {
        log_w("The WireGuard connection has dropped, attempting to reconnect...");
        
        // Disconnect properly first
        esp_wireguard_disconnect(&_wg_ctx);
        vTaskDelay(pdMS_TO_TICKS(1000)); // Wait a bit
        
        // Try to reconnect
        esp_err_t err = esp_wireguard_connect(&_wg_ctx);
        if (err == ESP_OK) {
            log_i("WireGuard reconnection successful");
            
            // Wait a bit for the connection to establish
            vTaskDelay(pdMS_TO_TICKS(1000));
            
            // Reconfigure the default route
            err = esp_wireguard_set_default(&_wg_ctx);
            if (err != ESP_OK) {
                log_e("Failed to reconfigure the default route: %d", err);
                return;
            }
            
            // Reconfigure the allowed routes
            err = esp_wireguard_add_allowed_ip(&_wg_ctx, "0.0.0.0", "0.0.0.0");
            if (err != ESP_OK) {
                log_e("Failed to reconfigure the allowed routes: %d", err);
                return;
            }
            
            // Check if the connection is well established
            if (esp_wireguard_peer_is_up(&_wg_ctx) == ESP_OK) {
                log_i("WireGuard connection established successfully");
            } else {
                log_w("The WireGuard connection is not yet established after reconnection");
            }
            
        } else if (err == ESP_ERR_RETRY) {
            log_w("DNS resolution in progress, reconnection postponed");
        } else {
            log_e("Failed to reconnect WireGuard: %d", err);
        }
    } else {
        // The connection is active, check the last handshake
        time_t last_handshake = get_latest_handshake();
        if (last_handshake > 0) {
            log_v("WireGuard connection active, last handshake: %ld", last_handshake);
        }
    }
}

void EspWireGuard::MonitorTask(void* parameter) {
    EspWireGuard* wg = static_cast<EspWireGuard*>(parameter);
    const TickType_t CHECK_INTERVAL = pdMS_TO_TICKS(5000); // 5 secondes 
    
    // Initial delay before starting monitoring (30s)
    const unsigned long INITIAL_GRACE_PERIOD = 60000;
    const unsigned long INITIAL_BACKOFF_TIME = 10000; // 10 seconds
    const unsigned long INCREMENT_BACKOFF_TIME = 10000; // 10 seconds
    const unsigned long MAX_BACKOFF_TIME = 120000; // 2 minutes max
    unsigned long start_time = millis();
    bool in_startup_phase = true;
    
    while (true) {
        if (wg->_is_initialized) {
            unsigned long now = millis();
            
            // Startup phase - wait for the connection to establish naturally
            if (in_startup_phase) {
                if (now - start_time < INITIAL_GRACE_PERIOD) {
                    // During the grace period, just check if the connection establishes
                    esp_err_t peer_status = esp_wireguard_peer_is_up(&wg->_wg_ctx);
                    time_t last_handshake = wg->get_latest_handshake();
                    
                    if (peer_status == ESP_OK && last_handshake > 0) {
                        log_i("WireGuard connection established during the grace period (%lu ms)",
                              now - start_time);
                        in_startup_phase = false;
                        wg->_disconnect_time = 0;
                        wg->_reconnect_attempt = 0;
                        wg->_last_reconnect_attempt = 0;
                    } else {
                        log_d("Waiting for WireGuard connection to establish... (%lu/%lu ms)",
                              now - start_time, INITIAL_GRACE_PERIOD);
                    }
                    vTaskDelay(CHECK_INTERVAL);
                    continue;
                } else {
                    log_i("End of initial grace period for WireGuard");
                    in_startup_phase = false;
                }
            }
            
            // Check the connection status
            esp_err_t peer_status = esp_wireguard_peer_is_up(&wg->_wg_ctx);
            time_t last_handshake = wg->get_latest_handshake();
            time_t current_time = time(NULL);
            
            // Consider a handshake too old (> 5 minutes) as a connection down
            bool handshake_too_old = (last_handshake > 0) && (current_time - last_handshake > 300);
            
            if (peer_status != ESP_OK || handshake_too_old) {
                // First detection of disconnection
                if (wg->_disconnect_time == 0) {
                    if (peer_status != ESP_OK) {
                        log_w("WireGuard connection lost (peer down)");
                    } else {
                        char time_str[32];
                        struct tm timeinfo;
                        localtime_r(&last_handshake, &timeinfo);
                        strftime(time_str, sizeof(time_str), "%Y-%m-%d %H:%M:%S", &timeinfo);
                        log_w("WireGuard connection inactive (last handshake: %s, too old)", time_str);
                    }
                    wg->_disconnect_time = now;
                    wg->_reconnect_attempt = 0;
                    wg->_last_reconnect_attempt = 0;
                } else {
                    // Calculate the delay before the next attempt
                    // Linear backoff: 10s, 20s, 30s, 40s, etc.
                    unsigned long backoff_time = INITIAL_BACKOFF_TIME + (wg->_reconnect_attempt * INCREMENT_BACKOFF_TIME);
                    if (backoff_time > MAX_BACKOFF_TIME) 
                        backoff_time = MAX_BACKOFF_TIME;
                    
                    if (now - wg->_last_reconnect_attempt >= backoff_time) {
                        log_w("WireGuard reconnection attempt (%d, after %lus)...", 
                              wg->_reconnect_attempt + 1, backoff_time/1000);
                        
                        // Attempt to reconnect
                        wg->reconnect();
                        
                        wg->_last_reconnect_attempt = now;
                        wg->_reconnect_attempt++;
                        
                        // Wait a good period after each attempt
                        vTaskDelay(pdMS_TO_TICKS(5000));
                    }
                }
            } else {
                // Active connection
                if (wg->_disconnect_time != 0) {
                    log_i("WireGuard connection restored after %d attempt(s)", wg->_reconnect_attempt);
                    wg->_disconnect_time = 0;
                    wg->_reconnect_attempt = 0;
                    wg->_last_reconnect_attempt = 0;
                } 
                
                // Log the last handshake
                if (last_handshake > 0) {
                    char time_str[32];
                    struct tm timeinfo;
                    localtime_r(&last_handshake, &timeinfo);
                    strftime(time_str, sizeof(time_str), "%Y-%m-%d %H:%M:%S", &timeinfo);
                    log_v("WireGuard connection active, last handshake: %s", time_str);
                }
            }
        }
        vTaskDelay(CHECK_INTERVAL);
    }
}

void EspWireGuard::reconnect() {
    if (!_is_initialized) return;
    
    // Disconnect properly first
    esp_wireguard_disconnect(&_wg_ctx);
    vTaskDelay(pdMS_TO_TICKS(1000)); // Wait a bit
    
    // Try to reconnect
    esp_err_t err = esp_wireguard_connect(&_wg_ctx);
    
    if (err == ESP_OK) {
        log_i("WireGuard reconnection initiated");
        
        // Wait for the connection to establish
        vTaskDelay(pdMS_TO_TICKS(2000));
        
        // Reconfigure the default route
        err = esp_wireguard_set_default(&_wg_ctx);
        if (err != ESP_OK) {
            log_e("Failed to reconfigure the default route: %d", err);
            return;
        }
        
        // Reconfigure the allowed routes
        err = esp_wireguard_add_allowed_ip(&_wg_ctx, "0.0.0.0", "0.0.0.0");
        if (err != ESP_OK) {
            log_e("Failed to reconfigure the allowed routes: %d", err);
            return;
        }
        
        log_i("WireGuard routes reconfigured");
    } else if (err == ESP_ERR_RETRY) {
        log_w("DNS resolution in progress, reconnection postponed");
    } else {
        log_e("Failed to reconnect WireGuard: %d", err);
    }
}