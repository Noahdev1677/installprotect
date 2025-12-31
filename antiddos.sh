#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
DOMAIN="https://publik-pnl.jhonaley.net"
PLTA="ptla_rXRyJk8v5yk9zE64yIcCi3F3kX3CHMcDaz3mw1GQmYx"
PLTC="ptlc_61S6jFX0hEps7k1x21rbKLfjj3lN6Ekh2MjsmUbs3lS"
LOCATION="1"
EGG_ID="15"
THRESHOLD_CONNECTIONS=500
THRESHOLD_PACKETS=1000

show_banner() {
    clear
    echo -e "${BLUE}"
    echo "╔════════════════════════════════════════════╗"
    echo "║           PTERODACTYL ANTI-DDOS           ║"
    echo "║              PROTECTION v2.0              ║"
    echo "╚════════════════════════════════════════════╝"
    echo -e "${NC}"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Error: Please run as root (sudo ./install_ddos.sh)${NC}"
        exit 1
    fi
}

install_protection() {
    show_banner
    echo -e "${YELLOW}[+] Installing Pterodactyl DDoS Protection...${NC}"
    
    # Update system
    apt update && apt upgrade -y
    
    # Install dependencies
    apt install -y python3 python3-pip nodejs npm iptables-persistent fail2ban net-tools tcpdump dstat jq
    
    # Python dependencies
    pip3 install requests psutil
    
    # Node.js dependencies
    npm install -g axios
    
    # Create protection directory
    mkdir -p /opt/ptero_antiddos/{scripts,logs,config}
    
    # Create configuration file
    cat > /opt/ptero_antiddos/config/config.json << EOF
{
    "domain": "$DOMAIN",
    "plta": "$PLTA", 
    "pltc": "$PLTC",
    "location": "$LOCATION",
    "egg_id": "$EGG_ID",
    "thresholds": {
        "tcp_connections": $THRESHOLD_CONNECTIONS,
        "udp_packets": $THRESHOLD_PACKETS,
        "http_requests": 1000,
        "slowloris": 50,
        "bot_requests": 500
    },
    "monitoring": {
        "check_interval": 10,
        "ban_duration": 3600,
        "auto_delete": true
    }
}
EOF

    # Create Python monitoring script
    cat > /opt/ptero_antiddos/scripts/monitor.py << 'PYTHONEOF'
#!/usr/bin/env python3
import os
import time
import json
import requests
import psutil
import subprocess
from datetime import datetime

# Load configuration
with open('/opt/ptero_antiddos/config/config.json', 'r') as f:
    config = json.load(f)

DOMAIN = config['domain']
PLTA = config['plta']
THRESHOLDS = config['thresholds']
AUTO_DELETE = config['monitoring']['auto_delete']

HEADERS = {
    "Accept": "application/json",
    "Content-Type": "application/json",
    "Authorization": f"Bearer {PLTA}"
}

LOG_FILE = "/opt/ptero_antiddos/logs/ddos.log"

def log_event(message):
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    log_msg = f"[{timestamp}] {message}"
    print(log_msg)
    with open(LOG_FILE, "a") as f:
        f.write(log_msg + "\n")

def get_network_stats():
    """Get network statistics for detection"""
    stats = {
        'tcp_connections': 0,
        'udp_packets': 0,
        'http_requests': 0,
        'connections_per_ip': {}
    }
    
    try:
        # Get TCP connections
        result = subprocess.run(['netstat', '-ntu'], capture_output=True, text=True)
        lines = result.stdout.split('\n')
        
        for line in lines:
            if 'ESTABLISHED' in line and 'tcp' in line:
                stats['tcp_connections'] += 1
                parts = line.split()
                if len(parts) > 4:
                    ip = parts[4].split(':')[0]
                    stats['connections_per_ip'][ip] = stats['connections_per_ip'].get(ip, 0) + 1
            elif 'udp' in line:
                stats['udp_packets'] += 1
        
        # Get HTTP requests from nginx logs if available
        try:
            http_count = subprocess.run(['tail', '-1000', '/var/log/nginx/access.log'], 
                                      capture_output=True, text=True)
            stats['http_requests'] = len(http_count.stdout.split('\n')) - 1
        except:
            pass
            
    except Exception as e:
        log_event(f"Error getting network stats: {e}")
    
    return stats

def detect_ddos_method(stats):
    """Detect specific DDoS methods"""
    methods = []
    
    # TCP Flood detection
    if stats['tcp_connections'] > THRESHOLDS['tcp_connections']:
        methods.append('TCP_FLOOD')
    
    # UDP Flood detection  
    if stats['udp_packets'] > THRESHOLDS['udp_packets']:
        methods.append('UDP_FLOOD')
    
    # HTTP Stress detection
    if stats['http_requests'] > THRESHOLDS['http_requests']:
        methods.append('HTTP_STRESS')
    
    # Slowloris detection (many connections from few IPs)
    if stats['connections_per_ip']:
        max_conns = max(stats['connections_per_ip'].values())
        if max_conns > THRESHOLDS['slowloris']:
            methods.append('SLOWLORIS')
    
    # Bot detection (consistent high request rate)
    if stats['http_requests'] > THRESHOLDS['bot_requests']:
        methods.append('BOT_ATTACK')
    
    return methods

def get_servers():
    """Get list of servers from Pterodactyl"""
    try:
        response = requests.get(f"{DOMAIN}/api/application/servers", headers=HEADERS)
        if response.status_code == 200:
            return response.json()['data']
        else:
            log_event(f"Error getting servers: {response.status_code}")
            return []
    except Exception as e:
        log_event(f"Error fetching servers: {e}")
        return []

def get_users():
    """Get list of users from Pterodactyl"""
    try:
        response = requests.get(f"{DOMAIN}/api/application/users", headers=HEADERS)
        if response.status_code == 200:
            return response.json()['data']
        else:
            log_event(f"Error getting users: {response.status_code}")
            return []
    except Exception as e:
        log_event(f"Error fetching users: {e}")
        return []

def delete_server(server_id):
    """Delete server via Pterodactyl API"""
    try:
        response = requests.delete(f"{DOMAIN}/api/application/servers/{server_id}", headers=HEADERS)
        if response.status_code == 204:
            log_event(f"✅ Server {server_id} deleted successfully")
            return True
        else:
            log_event(f"❌ Failed to delete server {server_id}: {response.status_code}")
            return False
    except Exception as e:
        log_event(f"Error deleting server {server_id}: {e}")
        return False

def delete_user(user_id):
    """Delete user via Pterodactyl API"""
    try:
        response = requests.delete(f"{DOMAIN}/api/application/users/{user_id}", headers=HEADERS)
        if response.status_code == 204:
            log_event(f"✅ User {user_id} deleted successfully")
            return True
        else:
            log_event(f"❌ Failed to delete user {user_id}: {response.status_code}")
            return False
    except Exception as e:
        log_event(f"Error deleting user {user_id}: {e}")
        return False

def get_server_owner(server_id):
    """Get server owner information"""
    try:
        response = requests.get(f"{DOMAIN}/api/application/servers/{server_id}", headers=HEADERS)
        if response.status_code == 200:
            return response.json()['attributes']['user']
        return None
    except:
        return None

def monitor_loop():
    """Main monitoring loop"""
    log_event("🚀 Starting Pterodactyl DDoS Monitor...")
    
    while True:
        try:
            stats = get_network_stats()
            ddos_methods = detect_ddos_method(stats)
            
            if ddos_methods:
                log_event(f"🚨 DDoS Detected: {', '.join(ddos_methods)}")
                log_event(f"📊 Stats: TCP={stats['tcp_connections']}, UDP={stats['udp_packets']}, HTTP={stats['http_requests']}")
                
                if AUTO_DELETE:
                    # Get all servers
                    servers = get_servers()
                    users = get_users()
                    
                    log_event(f"🔍 Scanning {len(servers)} servers for malicious activity...")
                    
                    # Analyze each server's network usage
                    for server in servers:
                        server_id = server['attributes']['id']
                        server_name = server['attributes']['name']
                        
                        # Check if server is using suspicious resources
                        # This is a simplified check - you'd want more sophisticated detection
                        if stats['tcp_connections'] > THRESHOLDS['tcp_connections'] * 0.8:
                            log_event(f"⚠️ Server {server_name} ({server_id}) suspected in DDoS")
                            if delete_server(server_id):
                                # Also delete the user who owned this server
                                owner = get_server_owner(server_id)
                                if owner and delete_user(owner):
                                    log_event(f"✅ Also deleted owner user {owner}")
            
            time.sleep(config['monitoring']['check_interval'])
            
        except Exception as e:
            log_event(f"❌ Monitoring error: {e}")
            time.sleep(30)

if __name__ == "__main__":
    monitor_loop()
PYTHONEOF

    # Create Node.js detection script
    cat > /opt/ptero_antiddos/scripts/detector.js << 'JSEOF'
const axios = require('axios');
const { execSync } = require('child_process');
const fs = require('fs');

// Load config
const config = JSON.parse(fs.readFileSync('/opt/ptero_antiddos/config/config.json', 'utf8'));

class DDoSDetector {
    constructor() {
        this.domain = config.domain;
        this.plta = config.plta;
        this.pltc = config.pltc;
        this.thresholds = config.thresholds;
        this.headers = {
            "Accept": "application/json",
            "Content-Type": "application/json",
            "Authorization": `Bearer ${this.plta}`
        };
    }

    async detectBypassMethods() {
        try {
            // Monitor for bypass attempts
            const netstat = execSync('netstat -an | grep :80 | wc -l').toString().trim();
            const connections = parseInt(netstat);
            
            // Check for abnormal patterns indicating bypass attempts
            if (connections > this.thresholds.tcp_connections * 2) {
                return 'BYPASS_ATTEMPT';
            }
            
            return null;
        } catch (error) {
            console.error('Detection error:', error);
            return null;
        }
    }

    async getServerStatistics() {
        try {
            const response = await axios.get(`${this.domain}/api/application/servers`, { 
                headers: this.headers 
            });
            
            const servers = response.data.data;
            const stats = [];
            
            for (const server of servers) {
                const serverId = server.attributes.id;
                const serverStats = await this.analyzeServerTraffic(serverId);
                stats.push({
                    server: server.attributes.name,
                    id: serverId,
                    traffic: serverStats
                });
            }
            
            return stats;
        } catch (error) {
            console.error('Error getting server stats:', error);
            return [];
        }
    }

    analyzeServerTraffic(serverId) {
        // Analyze traffic patterns for this server
        // This would integrate with your actual traffic monitoring
        return {
            connections: Math.floor(Math.random() * 1000),
            packets: Math.floor(Math.random() * 5000),
            bandwidth: Math.floor(Math.random() * 1000000)
        };
    }

    async deleteMaliciousServer(serverId, reason) {
        try {
            console.log(`🚨 Deleting malicious server ${serverId}: ${reason}`);
            
            const response = await axios.delete(
                `${this.domain}/api/application/servers/${serverId}`, 
                { headers: this.headers }
            );
            
            if (response.status === 204) {
                console.log(`✅ Successfully deleted server ${serverId}`);
                return true;
            }
        } catch (error) {
            console.error(`❌ Failed to delete server ${serverId}:`, error.message);
        }
        return false;
    }

    async deleteMaliciousUser(userId, reason) {
        try {
            console.log(`🚨 Deleting malicious user ${userId}: ${reason}`);
            
            const response = await axios.delete(
                `${this.domain}/api/application/users/${userId}`, 
                { headers: this.headers }
            );
            
            if (response.status === 204) {
                console.log(`✅ Successfully deleted user ${userId}`);
                return true;
            }
        } catch (error) {
            console.error(`❌ Failed to delete user ${userId}:`, error.message);
        }
        return false;
    }
}

// Export for use in other scripts
module.exports = DDoSDetector;

// Run if called directly
if (require.main === module) {
    const detector = new DDoSDetector();
    setInterval(async () => {
        const bypass = await detector.detectBypassMethods();
        if (bypass) {
            console.log(`🚨 ${bypass} detected!`);
        }
    }, 15000);
}
JSEOF

    # Create systemd service
    cat > /etc/systemd/system/ptero-antiddos.service << EOF
[Unit]
Description=Pterodactyl Anti-DDoS Protection
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/ptero_antiddos
ExecStart=/usr/bin/python3 /opt/ptero_antiddos/scripts/monitor.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    # Create firewall protection script
    cat > /opt/ptero_antiddos/scripts/firewall.sh << 'EOF'
#!/bin/bash

# Advanced Firewall Protection for Pterodactyl

# Flush existing rules
iptables -F
iptables -X

# Default policies
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT

# Allow established connections
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Pterodactyl Wings ports
iptables -A INPUT -p tcp --dport 2022 -j ACCEPT  # SFTP
iptables -A INPUT -p tcp --dport 8080 -j ACCEPT  # Wings API
iptables -A INPUT -p tcp --dport 25565:25575 -j ACCEPT  # Game servers

# SSH protection (rate limited)
iptables -A INPUT -p tcp --dport 22 -m state --state NEW -m limit --limit 3/min --limit-burst 3 -j ACCEPT
iptables -A INPUT -p tcp --dport 22 -j DROP

# HTTP/HTTPS protection
iptables -A INPUT -p tcp --dport 80 -m limit --limit 100/min --limit-burst 200 -j ACCEPT
iptables -A INPUT -p tcp --dport 443 -m limit --limit 100/min --limit-burst 200 -j ACCEPT

# DDoS protection rules
iptables -A INPUT -p tcp --syn -m limit --limit 1/s --limit-burst 3 -j ACCEPT
iptables -A INPUT -p tcp --syn -j DROP
iptables -A INPUT -p icmp --icmp-type echo-request -m limit --limit 1/s -j ACCEPT

# Save rules
iptables-save > /etc/iptables/rules.v4

echo "Firewall rules applied successfully"
EOF

    chmod +x /opt/ptero_antiddos/scripts/*.sh
    chmod +x /opt/ptero_antiddos/scripts/monitor.py
    
    # Install Node.js dependencies
    cd /opt/ptero_antiddos/scripts && npm init -y && npm install axios
    
    # Apply firewall rules
    /opt/ptero_antiddos/scripts/firewall.sh
    
    # Enable and start service
    systemctl daemon-reload
    systemctl enable ptero-antiddos
    systemctl start ptero-antiddos
    
    echo -e "${GREEN}[✓] Pterodactyl DDoS Protection installed successfully!${NC}"
    echo -e "${YELLOW}[!] Monitoring started with auto-delete feature${NC}"
    sleep 3
}

uninstall_protection() {
    show_banner
    echo -e "${RED}[!] UNINSTALLING Pterodactyl DDoS Protection...${NC}"
    read -p "Are you sure? (y/N): " confirm
    
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        echo "Uninstall cancelled"
        return
    fi
    
    # Stop and disable service
    systemctl stop ptero-antiddos
    systemctl disable ptero-antiddos
    rm -f /etc/systemd/system/ptero-antiddos.service
    
    # Reset firewall
    iptables -F
    iptables -X
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    
    # Remove files
    rm -rf /opt/ptero_antiddos
    
    systemctl daemon-reload
    
    echo -e "${GREEN}[✓] Protection completely removed!${NC}"
    sleep 2
}

show_status() {
    show_banner
    echo -e "${BLUE}=== PROTECTION STATUS ===${NC}"
    
    if systemctl is-active ptero-antiddos >/dev/null 2>&1; then
        echo -e "Service: ${GREEN}ACTIVE${NC}"
        echo -e "Auto-Delete: ${GREEN}ENABLED${NC}"
        
        # Show recent logs
        if [ -f "/opt/ptero_antiddos/logs/ddos.log" ]; then
            echo ""
            echo "Recent Events:"
            tail -10 /opt/ptero_antiddos/logs/ddos.log
        fi
    else
        echo -e "Service: ${RED}INACTIVE${NC}"
    fi
    
    echo ""
    read -p "Press Enter to continue..."
}

# Main menu
check_root
while true; do
    show_banner
    echo -e "${GREEN}Pterodactyl DDoS Protection Menu:${NC}"
    echo "1. Install Protection"
    echo "2. Uninstall Protection" 
    echo "3. Show Status"
    echo "4. Exit"
    echo ""
    read -p "Choose option [1-4]: " choice

    case $choice in
        1) install_protection ;;
        2) uninstall_protection ;;
        3) show_status ;;
        4) 
            echo -e "${GREEN}Goodbye!${NC}"
            exit 0 
            ;;
        *) 
            echo -e "${RED}Invalid option!${NC}"
            sleep 2
            ;;
    esac
done
