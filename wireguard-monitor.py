#!/usr/bin/env python3
import subprocess
import re
import time
import logging
import sys
import fcntl
import os
import select
from collections import defaultdict

# Logging configuration
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler("/var/log/wireguard-monitor.log"),
        logging.StreamHandler()
    ]
)

# Define commands
WG_SHOW_CMD = ["sudo", "wg", "show"]
TCPDUMP_CMD = ["sudo", "tcpdump", "-i", "any", "udp port 51820", "-n", "-l"]
RESTART_WG_CMD = ["sudo", "systemctl", "restart", "wg-quick@wg0"]

# Extract the known endpoints of WireGuard
def get_wg_endpoints():
    try:
        result = subprocess.run(WG_SHOW_CMD, capture_output=True, text=True, check=True)
        output = result.stdout
        
        endpoints = {}
        current_peer = None
        
        for line in output.splitlines():
            line = line.strip()
            
            # Find a peer line
            if line.startswith("peer:"):
                current_peer = line.split(":", 1)[1].strip()
            
            # Find an endpoint line
            elif current_peer and "endpoint:" in line:
                endpoint = line.split(":", 1)[1].strip()
                ip, port = endpoint.rsplit(":", 1)
                endpoints[current_peer] = {"ip": ip, "port": int(port)}
        
        logging.info(f"Current WireGuard endpoints: {endpoints}")
        return endpoints
    except Exception as e:
        logging.error(f"Error getting WireGuard endpoints: {e}")
        return {}

# Restart the WireGuard service
def restart_wireguard():
    try:
        logging.info("Restarting the WireGuard service...")
        subprocess.run(RESTART_WG_CMD, check=True)
        logging.info("WireGuard service restarted successfully")
        return True
    except Exception as e:
        logging.error(f"Error restarting WireGuard: {e}")
        return False

# Start the tcpdump and process the output
def monitor_udp_traffic():
    # Get the known endpoints
    known_endpoints = get_wg_endpoints()
    
    # Create an inverted dictionary for quick IP search
    known_ips = {}
    for peer, endpoint in known_endpoints.items():
        known_ips[endpoint["ip"]] = {"peer": peer, "port": endpoint["port"]}
    
    # Tracking of the latest requests by IP
    recent_requests = defaultdict(list)
    
    # Variables to track restarts and checks
    last_restart_time = 0
    grace_period = 30  # Grace period of 30 seconds after a restart
    grace_check_scheduled = False
    pending_port_updates = {}
    
    # Start tcpdump
    logging.info("Starting UDP monitoring...")
    tcpdump_process = subprocess.Popen(TCPDUMP_CMD, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
    
    # Regular expression to extract the IP and port from the tcpdump output
    pattern = r'(\d+\.\d+\.\d+\.\d+)\.(\d+) > .+\.51820:'
    
    try:
        # Make the stdout non-blocking
        fd = tcpdump_process.stdout.fileno()
        fl = fcntl.fcntl(fd, fcntl.F_GETFL)
        fcntl.fcntl(fd, fcntl.F_SETFL, fl | os.O_NONBLOCK)
        
        while True:
            # Check if we have data to read with a timeout
            ready, _, _ = select.select([tcpdump_process.stdout], [], [], 1.0)
            
            # Check if the tcpdump process is still running
            if tcpdump_process.poll() is not None:
                logging.warning("The tcpdump process ended unexpectedly")
                break
                
            # Check if the grace period has expired and a check is expected
            current_time = time.time()
            if grace_check_scheduled and current_time - last_restart_time >= grace_period:
                grace_check_scheduled = False
                logging.info("Grace period expired, checking endpoint updates...")
                
                # Get the current endpoints
                updated_endpoints = get_wg_endpoints()
                updated_ips = {}
                for p, ep in updated_endpoints.items():
                    updated_ips[ep["ip"]] = {"peer": p, "port": ep["port"]}
                
                # Check if the updates have been taken into account
                for ip, update in pending_port_updates.items():
                    if ip in updated_ips:
                        current_port = updated_ips[ip]["port"]
                        expected_port = update["new_port"]
                        if current_port == expected_port:
                            logging.info(f"Update confirmed for {update['peer']} ({ip}): port changed to {expected_port}")
                        else:
                            logging.warning(f"Update not effective for {update['peer']} ({ip}): current port {current_port}, expected {expected_port}")
                            # If the port has not been updated, keep it in pending_port_updates
                            # for a later check
                            continue
                    else:
                        logging.warning(f"IP {ip} not found in the current endpoints")
                
                # Update our knowledge with the verified endpoints
                known_endpoints = updated_endpoints
                known_ips = updated_ips
                
                # Reset the processed updates
                pending_port_updates = {ip: update for ip, update in pending_port_updates.items() 
                                       if ip in updated_ips and updated_ips[ip]["port"] != update["new_port"]}
            
            if ready:
                try:
                    line = tcpdump_process.stdout.readline()
                    if not line:  # EOF
                        break
                        
                    # Search only incoming requests
                    if "In" not in line:
                        continue
                        
                    match = re.search(pattern, line)
                    if match:
                        src_ip = match.group(1)
                        src_port = int(match.group(2))
                        
                        logging.debug(f"UDP request detected from {src_ip}:{src_port}")
                        
                        # Check if this IP is known as a WireGuard endpoint
                        if src_ip in known_ips:
                            known_peer_data = known_ips[src_ip]
                            known_port = known_peer_data["port"]
                            peer = known_peer_data["peer"]
                            
                            # If the port has changed compared to what WireGuard knows
                            if src_port != known_port:
                                logging.info(f"Port change detected for {src_ip}: {known_port} -> {src_port}")
                                
                                # Add this request to the recent history
                                recent_requests[src_ip].append(src_port)
                                
                                # If we have seen several consecutive requests from the same port
                                # (avoid false positives)
                                if len(recent_requests[src_ip]) >= 3:
                                    last_ports = recent_requests[src_ip][-3:]
                                    if all(port == src_port for port in last_ports):
                                        # Check if we are in the grace period after a restart
                                        current_time = time.time()
                                        if current_time - last_restart_time < grace_period:
                                            logging.info(f"Port change detected during the grace period, waiting...")
                                            continue
                                        
                                        logging.info(f"Port change confirmed for {peer} ({src_ip}): {known_port} -> {src_port}")
                                        
                                        # Restart WireGuard
                                        if restart_wireguard():
                                            # Update the timestamp of the last restart
                                            last_restart_time = time.time()
                                            logging.info(f"Grace period of {grace_period} seconds started")
                                            
                                            # Register the port updates in progress
                                            pending_port_updates[src_ip] = {
                                                "peer": peer,
                                                "old_port": known_port, 
                                                "new_port": src_port
                                            }
                                            grace_check_scheduled = True
                                            
                                            # Update our knowledge of the endpoints after a restart
                                            time.sleep(1)  # Wait for WireGuard to start
                                            known_endpoints = get_wg_endpoints()
                                            
                                            # Update the inverted dictionary
                                            known_ips = {}
                                            for p, ep in known_endpoints.items():
                                                known_ips[ep["ip"]] = {"peer": p, "port": ep["port"]}
                                        
                                        # Reset the request history for this IP
                                        recent_requests[src_ip] = []
                        
                        # Limit the size of the request history
                        if len(recent_requests[src_ip]) > 10:
                            recent_requests[src_ip] = recent_requests[src_ip][-10:]
                except:
                    # If an error occurs during reading, skip to the next iteration
                    pass
                    
    except KeyboardInterrupt:
        logging.info("Stopping the monitor...")
    finally:
        # Ensure the tcpdump process is properly terminated
        try:
            tcpdump_process.terminate()
            tcpdump_process.wait(timeout=5)  # Wait max 5 seconds
        except:
            # If the process does not terminate properly, kill it
            try:
                tcpdump_process.kill()
            except:
                pass
                
        logging.info("Monitor stopped")

def signal_handler(sig, frame):
    logging.info("Termination signal received, stopping the program...")
    # This signal handler allows handling Ctrl+C even when the program is waiting
    raise KeyboardInterrupt

if __name__ == "__main__":
    import signal
    
    # Register the signal handler for Ctrl+C (SIGINT)
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    
    logging.info("Starting the WireGuard monitor (Ctrl+C to quit)")
    
    try:
        monitor_udp_traffic()
    except KeyboardInterrupt:
        logging.info("Program terminated by the user")
        # Clean exit
        sys.exit(0)
    except Exception as e:
        logging.error(f"Error in the monitor: {e}")
        sys.exit(1)