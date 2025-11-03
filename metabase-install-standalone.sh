#!/usr/bin/env bash
# Standalone Metabase Installation Script for Proxmox LXC
# Completely self-contained - no external dependencies
# Copyright (c) 2025
# License: MIT

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
msg_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

msg_ok() {
    echo -e "${GREEN}[OK]${NC} $1"
}

msg_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

msg_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Configuration (can be overridden by environment variables)
APP="${APP:-Metabase}"
CTID="${CTID:-}"
STORAGE="${STORAGE:-local-lvm}"
TEMPLATE="${TEMPLATE:-local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst}"
PASSWORD="${PASSWORD:-}"
ROOTFS_SIZE="${ROOTFS_SIZE:-8G}"
CPU_CORES="${CPU_CORES:-2}"
RAM_MB="${RAM_MB:-2048}"
SWAP_MB="${SWAP_MB:-512}"
HOSTNAME="${HOSTNAME:-metabase-lxc}"
IP="${IP:-}"
GATEWAY="${GATEWAY:-}"
BRIDGE="${BRIDGE:-vmbr0}"
UNPRIVILEGED="${UNPRIVILEGED:-1}"
NESTING="${NESTING:-0}"
TAGS="${TAGS:-analytics;business-intelligence}"

# Function to execute commands in container
exec_in_ct() {
    pct exec "$CTID" -- bash -c "$1"
}

# Update function
update_metabase() {
    if [[ -z "$CTID" ]]; then
        msg_error "CTID must be specified for update"
        exit 1
    fi
    
    if ! pct status "$CTID" &>/dev/null; then
        msg_error "Container $CTID not found"
        exit 1
    fi
    
    msg_info "Checking for Metabase updates..."
    CURRENT_VERSION=$(exec_in_ct "java -jar /opt/metabase/metabase.jar version 2>/dev/null | head -n1 | grep -oP 'v\d+\.\d+\.\d+' | sed 's/v//' || echo 'unknown'")
    LATEST_VERSION=$(curl -s https://api.github.com/repos/metabase/metabase/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
    
    if [[ "$CURRENT_VERSION" != "$LATEST_VERSION" ]] && [[ "$LATEST_VERSION" != "" ]]; then
        msg_info "Updating Metabase from $CURRENT_VERSION to $LATEST_VERSION"
        exec_in_ct "systemctl stop metabase"
        exec_in_ct "wget -q -O /opt/metabase/metabase.jar 'https://downloads.metabase.com/v${LATEST_VERSION}/metabase.jar'"
        exec_in_ct "chown metabase:metabase /opt/metabase/metabase.jar"
        exec_in_ct "systemctl start metabase"
        msg_ok "Updated to version $LATEST_VERSION"
    else
        msg_ok "Already on latest version ($CURRENT_VERSION)"
    fi
    exit 0
}

# Handle update command
if [[ "${1:-}" == "update" ]]; then
    update_metabase
fi

# Validate required parameters - prompt if interactive
if [[ -z "$CTID" ]]; then
    # Check if running interactively (TTY available)
    if [[ -t 0 ]] && [[ -t 1 ]]; then
        echo ""
        msg_info "Interactive Mode - Please provide the following information:"
        echo ""
        read -p "Container ID (CTID) [required]: " CTID
        if [[ -z "$CTID" ]]; then
            msg_error "CTID is required"
            exit 1
        fi

        read -p "Static IP address (e.g., 192.168.1.100/24) [optional, press Enter for DHCP]: " IP_INPUT
        if [[ -n "$IP_INPUT" ]]; then
            IP="$IP_INPUT"
        fi

        if [[ -n "$IP" ]]; then
            read -p "Gateway IP (e.g., 192.168.1.1) [optional]: " GATEWAY_INPUT
            if [[ -n "$GATEWAY_INPUT" ]]; then
                GATEWAY="$GATEWAY_INPUT"
            fi
        fi

        read -p "Hostname [default: metabase-lxc, press Enter for default]: " HOSTNAME_INPUT
        if [[ -n "$HOSTNAME_INPUT" ]]; then
            HOSTNAME="$HOSTNAME_INPUT"
        fi

        read -p "Root password [press Enter to auto-generate]: " PASSWORD_INPUT
        if [[ -n "$PASSWORD_INPUT" ]]; then
            PASSWORD="$PASSWORD_INPUT"
        fi

        echo ""
    else
        # Non-interactive mode - show usage
        msg_error "CTID (Container ID) must be specified"
        echo ""
        echo "Usage:"
        echo "  CTID=100 bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/atomicdsolutions/proxmoxscripts/main/metabase-install-standalone.sh)\""
        echo "  CTID=100 IP=192.168.1.100/24 GATEWAY=192.168.1.1 bash -c \"\$(curl -fsSL ...)\""
        echo "  CTID=100 bash -c \"\$(curl -fsSL ...)\" update"
        echo ""
        echo "Or download and run locally for interactive mode:"
        echo "  curl -fsSL https://raw.githubusercontent.com/atomicdsolutions/proxmoxscripts/main/metabase-install-standalone.sh -o metabase-install.sh"
        echo "  chmod +x metabase-install.sh"
        echo "  ./metabase-install.sh"
        echo ""
        echo "Environment variables:"
        echo "  CTID       - Container ID (required)"
        echo "  IP         - Static IP address (e.g., 192.168.1.100/24)"
        echo "  GATEWAY    - Gateway IP (e.g., 192.168.1.1)"
        echo "  PASSWORD   - Root password (auto-generated if not set)"
        echo "  HOSTNAME   - Container hostname (default: metabase-lxc)"
        echo "  STORAGE    - Storage pool (default: local-lvm)"
        echo "  TEMPLATE   - LXC template (default: debian-12)"
        exit 1
    fi
fi

# Generate password if not set
if [[ -z "$PASSWORD" ]]; then
    PASSWORD=$(openssl rand -base64 32 2>/dev/null | tr -d "=+/" | cut -c1-20 || echo "changeme123")
    msg_info "Generated random password: $PASSWORD"
fi

# Check if container ID already exists
if pct status "$CTID" &>/dev/null; then
    msg_warning "Container $CTID already exists"
    read -p "Do you want to use the existing container? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        msg_error "Aborted. Please choose a different CTID."
        exit 1
    fi
    msg_info "Using existing container $CTID"
    EXISTING_CONTAINER=1
else
    EXISTING_CONTAINER=0
fi

# Check if template exists
if [[ "$TEMPLATE" == local:* ]]; then
    TEMPLATE_FILE=$(basename "$TEMPLATE" | cut -d: -f2)
    if [[ ! -f "/var/lib/vz/template/cache/$TEMPLATE_FILE" ]]; then
        msg_warning "Template file not found: $TEMPLATE"
        msg_info "Available templates:"
        ls -1 /var/lib/vz/template/cache/*.tar.zst 2>/dev/null | sed 's|/var/lib/vz/template/cache/|local:|' || echo "  None found"
        exit 1
    fi
fi

msg_info "========================================="
msg_info "Proxmox LXC Container Setup - $APP"
msg_info "========================================="
msg_info "Container ID: $CTID"
msg_info "Hostname: $HOSTNAME"
msg_info "Template: $TEMPLATE"
msg_info "CPU Cores: $CPU_CORES"
msg_info "RAM: ${RAM_MB}MB"
msg_info "Disk: $ROOTFS_SIZE"
msg_info "Unprivileged: $UNPRIVILEGED"
msg_info "========================================="

# Create container if it doesn't exist
if [[ $EXISTING_CONTAINER -eq 0 ]]; then
    msg_info "Creating LXC container $CTID..."
    
    # Build pct create command
    PCT_CMD="pct create $CTID $TEMPLATE"
    PCT_CMD+=" --storage $STORAGE"
    PCT_CMD+=" --hostname $HOSTNAME"
    PCT_CMD+=" --password '$PASSWORD'"
    PCT_CMD+=" --rootfs-size $ROOTFS_SIZE"
    PCT_CMD+=" --cores $CPU_CORES"
    PCT_CMD+=" --memory $RAM_MB"
    PCT_CMD+=" --swap $SWAP_MB"
    
    # Network configuration
    if [[ -n "$IP" ]] && [[ -n "$GATEWAY" ]]; then
        PCT_CMD+=" --net0 name=eth0,bridge=$BRIDGE,ip=$IP,gw=$GATEWAY"
    else
        PCT_CMD+=" --net0 name=eth0,bridge=$BRIDGE"
        msg_warning "IP and Gateway not set. Container will use DHCP."
    fi
    
    # Features
    if [[ $UNPRIVILEGED -eq 1 ]]; then
        PCT_CMD+=" --unprivileged 1"
    fi
    
    if [[ $NESTING -eq 1 ]]; then
        PCT_CMD+=" --features nesting=1"
    fi
    
    # Tags
    if [[ -n "$TAGS" ]]; then
        PCT_CMD+=" --tags $TAGS"
    fi
    
    # Execute container creation
    eval "$PCT_CMD"
    
    if [[ $? -eq 0 ]]; then
        msg_ok "Container $CTID created successfully"
    else
        msg_error "Failed to create container"
        exit 1
    fi
else
    msg_info "Using existing container $CTID"
fi

# Start container
msg_info "Starting container $CTID..."
pct start "$CTID"
sleep 3

# Wait for container to be ready
msg_info "Waiting for container to be ready..."
for _ in {1..30}; do
    if pct exec "$CTID" -- ping -c 1 127.0.0.1 &>/dev/null; then
        break
    fi
    sleep 1
done

# Get container IP if not set
if [[ -z "$IP" ]]; then
    IP=$(pct exec "$CTID" -- ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || echo "")
    if [[ -n "$IP" ]]; then
        msg_info "Detected container IP: $IP"
    fi
fi

msg_ok "Container $CTID is ready"
msg_info "Container IP: ${IP:-DHCP}"
msg_info "Root Password: $PASSWORD"
echo ""

# Install Metabase
msg_info "Installing Metabase dependencies..."
exec_in_ct "apt update && apt install -y curl wget openjdk-17-jre-headless"

msg_info "Creating Metabase user..."
exec_in_ct "if ! id -u metabase >/dev/null 2>&1; then useradd -r -s /bin/false -d /opt/metabase -m metabase; fi"

msg_info "Creating Metabase directories..."
exec_in_ct "mkdir -p /opt/metabase/data && chown -R metabase:metabase /opt/metabase"

msg_info "Downloading latest Metabase..."
LATEST_VERSION=$(curl -s https://api.github.com/repos/metabase/metabase/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
if [[ -z "$LATEST_VERSION" ]]; then
    LATEST_VERSION="latest"
    DOWNLOAD_URL="https://downloads.metabase.com/${LATEST_VERSION}/metabase.jar"
else
    DOWNLOAD_URL="https://downloads.metabase.com/v${LATEST_VERSION}/metabase.jar"
fi

msg_info "Downloading Metabase v${LATEST_VERSION}..."
exec_in_ct "wget -q -O /opt/metabase/metabase.jar '${DOWNLOAD_URL}' && chown metabase:metabase /opt/metabase/metabase.jar && chmod 755 /opt/metabase/metabase.jar"

msg_info "Creating systemd service..."
exec_in_ct 'cat > /etc/systemd/system/metabase.service <<EOF
[Unit]
Description=Metabase Server
Documentation=https://www.metabase.com/docs/latest/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=metabase
Group=metabase
WorkingDirectory=/opt/metabase
ExecStart=/usr/bin/java -Xmx2g -jar /opt/metabase/metabase.jar
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=metabase

NoNewPrivileges=true
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/opt/metabase/data
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF'

msg_info "Enabling and starting Metabase service..."
exec_in_ct "systemctl daemon-reload && systemctl enable metabase && systemctl start metabase"

msg_info "Waiting for Metabase to start..."
sleep 5

if exec_in_ct "systemctl is-active --quiet metabase"; then
    msg_ok "Metabase service is running"
else
    msg_warning "Metabase service may still be starting. Check logs with: journalctl -u metabase -f"
fi

msg_ok "Metabase installation completed!"
echo ""
msg_info "========================================="
msg_info "Access Metabase at: http://${IP:-<CONTAINER_IP>}:3000"
msg_info "Default credentials: Set up on first login"
msg_info "========================================="
echo ""
msg_info "Management commands:"
echo "  Status:  pct exec $CTID -- systemctl status metabase"
echo "  Start:   pct exec $CTID -- systemctl start metabase"
echo "  Stop:    pct exec $CTID -- systemctl stop metabase"
echo "  Restart: pct exec $CTID -- systemctl restart metabase"
echo "  Logs:    pct exec $CTID -- journalctl -u metabase -f"
echo ""
msg_info "Container management:"
echo "  Console:           pct enter $CTID"
echo "  Start container:   pct start $CTID"
echo "  Stop container:    pct stop $CTID"
echo "  Destroy container: pct destroy $CTID"
