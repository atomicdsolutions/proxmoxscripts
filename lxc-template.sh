#!/usr/bin/env bash
# Standalone Proxmox LXC Container Creation Template
# No dependencies on external scripts - works independently
# Copyright (c) 2025
# License: MIT

set -euo pipefail

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

# Default configuration (can be overridden by environment variables)
APP="${APP:-Application}"
CTID="${CTID:-}"
STORAGE="${STORAGE:-local-lvm}"
TEMPLATE="${TEMPLATE:-local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst}"
PASSWORD="${PASSWORD:-}"
ROOTFS_SIZE="${ROOTFS_SIZE:-8G}"
CPU_CORES="${CPU_CORES:-2}"
RAM_MB="${RAM_MB:-2048}"
SWAP_MB="${SWAP_MB:-512}"
HOSTNAME="${HOSTNAME:-}"
IP="${IP:-}"
GATEWAY="${GATEWAY:-}"
BRIDGE="${BRIDGE:-vmbr0}"
UNPRIVILEGED="${UNPRIVILEGED:-1}"
NESTING="${NESTING:-0}"
TAGS="${TAGS:-}"

# Validate required parameters
if [[ -z "$CTID" ]]; then
    msg_error "CTID (Container ID) must be specified. Set it with: export CTID=100"
    exit 1
fi

if [[ -z "$PASSWORD" ]]; then
    msg_warning "PASSWORD not set. You will need to set it manually or via SSH key."
    PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-20)
    msg_info "Generated random password: $PASSWORD"
fi

if [[ -z "$HOSTNAME" ]]; then
    HOSTNAME="${APP,,}-lxc"
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
if [[ ! -f "/var/lib/vz/template/cache/$(basename $TEMPLATE | cut -d: -f2)" ]] && [[ "$TEMPLATE" == local:* ]]; then
    msg_warning "Template file not found: $TEMPLATE"
    msg_info "Available templates:"
    ls -1 /var/lib/vz/template/cache/*.tar.zst 2>/dev/null | sed 's|/var/lib/vz/template/cache/|local:|' || echo "  None found"
    exit 1
fi

msg_info "========================================="
msg_info "Proxmox LXC Container Setup"
msg_info "========================================="
msg_info "Application: $APP"
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
for i in {1..30}; do
    if pct exec "$CTID" -- ping -c 1 127.0.0.1 &>/dev/null; then
        break
    fi
    sleep 1
done

# Get container IP if not set
if [[ -z "$IP" ]]; then
    IP=$(pct exec "$CTID" -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || echo "")
    if [[ -n "$IP" ]]; then
        msg_info "Detected container IP: $IP"
    fi
fi

# Function to execute commands in container
exec_in_ct() {
    pct exec "$CTID" -- bash -c "$1"
}

msg_ok "Container $CTID is ready"
msg_info "Container IP: ${IP:-DHCP}"
msg_info "Root Password: $PASSWORD"
echo ""

# This function should be overridden by the calling script
# or commands can be added after sourcing this template
if declare -f install_application &> /dev/null; then
    msg_info "Running application installation..."
    install_application
else
    msg_info "No install_application() function defined."
    msg_info "You can now execute commands in the container using:"
    msg_info "  pct exec $CTID -- <command>"
    msg_info "Or add your installation steps here."
fi

msg_ok "Setup completed!"
echo ""
msg_info "Useful commands:"
echo "  Start container:   pct start $CTID"
echo "  Stop container:    pct stop $CTID"
echo "  Console:           pct enter $CTID"
echo "  Execute command:   pct exec $CTID -- <command>"
echo "  Destroy container: pct destroy $CTID"

