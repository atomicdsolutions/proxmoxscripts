#!/usr/bin/env bash
# Standalone Supabase Installation Script for Proxmox VM (Docker-based)
# Completely self-contained - no external dependencies
# Copyright (c) 2025
# License: MIT

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

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

# Configuration
APP="${APP:-Supabase}"
VMID="${VMID:-}"
STORAGE="${STORAGE:-local-lvm}"
ISO_STORAGE="${ISO_STORAGE:-local}"
TEMPLATE="${TEMPLATE:-debian-12-genericcloud-amd64}"
PASSWORD="${PASSWORD:-}"
DISK_SIZE="${DISK_SIZE:-32G}"
CPU_CORES="${CPU_CORES:-4}"
RAM_MB="${RAM_MB:-4096}"
HOSTNAME="${HOSTNAME:-supabase-vm}"
IP="${IP:-}"
NETMASK="${NETMASK:-24}"
GATEWAY="${GATEWAY:-}"
BRIDGE="${BRIDGE:-vmbr0}"
SSH_KEY="${SSH_KEY:-}"
DNS="${DNS:-8.8.8.8}"
TAGS="${TAGS:-database;backend;postgresql}"

# Function to execute commands in VM via SSH
exec_in_vm() {
    local max_attempts=30
    local attempt=0
    
    # Wait for SSH to be available
    while [[ $attempt -lt $max_attempts ]]; do
        if ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@"$IP" "echo 'Connected'" &>/dev/null; then
            ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@"$IP" "$1"
            return $?
        fi
        sleep 2
        ((attempt++))
    done
    
    msg_error "Could not connect to VM via SSH"
    return 1
}

# Installation function
install_application() {
    msg_info "Installing Docker in VM..."
    exec_in_vm "apt update && apt install -y curl ca-certificates gnupg lsb-release"
    
    # Install Docker
    exec_in_vm 'install -m 0755 -d /etc/apt/keyrings && curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg && chmod a+r /etc/apt/keyrings/docker.gpg'
    
    exec_in_vm 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null'
    
    exec_in_vm "apt update && apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
    
    exec_in_vm "systemctl enable docker && systemctl start docker"
    
    msg_info "Creating Supabase directory..."
    exec_in_vm "mkdir -p /opt/supabase && cd /opt/supabase"
    
    msg_info "Cloning Supabase repository..."
    exec_in_vm "apt install -y git && git clone --depth 1 https://github.com/supabase/supabase.git /tmp/supabase-repo"
    
    msg_info "Copying Supabase Docker files..."
    exec_in_vm "cp -rf /tmp/supabase-repo/docker/* /opt/supabase/ && rm -rf /tmp/supabase-repo"
    
    msg_info "Configuring Supabase environment..."
    exec_in_vm 'cd /opt/supabase && if [[ -f .env.example ]]; then cp .env.example .env; fi'
    
    # Generate secure passwords
    POSTGRES_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
    JWT_SECRET=$(openssl rand -base64 64 | tr -d "=+/" | cut -c1-64)
    
    exec_in_vm "cd /opt/supabase && cat > .env <<EOF
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
JWT_SECRET=${JWT_SECRET}
API_URL=http://${IP}:8000
STUDIO_URL=http://${IP}:3000
EOF"
    
    msg_info "Pulling Docker images (this may take a while)..."
    exec_in_vm "cd /opt/supabase && docker compose pull"
    
    msg_info "Starting Supabase services..."
    exec_in_vm "cd /opt/supabase && docker compose up -d"
    
    msg_info "Waiting for services to initialize..."
    sleep 15
    
    # Enable pgvector
    msg_info "Enabling pgvector extension..."
    exec_in_vm "cd /opt/supabase && docker compose exec -T db psql -U postgres -c 'CREATE EXTENSION IF NOT EXISTS vector;' 2>/dev/null || true"
    
    msg_ok "Supabase installation completed!"
    echo ""
    msg_info "========================================="
    msg_info "Supabase Access Information"
    msg_info "========================================="
    msg_info "Studio UI:  http://${IP}:3000"
    msg_info "API:        http://${IP}:8000"
    msg_info "Database:   ${IP}:5432"
    msg_info ""
    msg_info "Credentials saved in: /opt/supabase/.env"
    msg_info "PostgreSQL Password: ${POSTGRES_PASSWORD}"
    echo ""
    msg_info "Management commands (SSH to VM):"
    echo "  View services:  cd /opt/supabase && docker compose ps"
    echo "  View logs:      cd /opt/supabase && docker compose logs -f"
    echo "  Restart:        cd /opt/supabase && docker compose restart"
    echo "  Stop:           cd /opt/supabase && docker compose down"
}

# Main execution
if [[ "${1:-}" == "update" ]]; then
    if [[ -z "$VMID" ]] || [[ -z "$IP" ]]; then
        msg_error "VMID and IP required for update"
        exit 1
    fi
    msg_info "Updating Supabase containers..."
    exec_in_vm "cd /opt/supabase && docker compose pull && docker compose up -d"
    msg_ok "Update completed"
    exit 0
fi

# Check if VMID is set
if [[ -z "$VMID" ]]; then
    msg_error "VMID (VM ID) must be specified"
    echo ""
    echo "Usage:"
    echo "  VMID=100 bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/atomicdsolutions/proxmoxscripts/main/supabase-install-vm.sh)\""
    echo "  VMID=100 IP=192.168.1.100/24 GATEWAY=192.168.1.1 bash -c \"\$(curl -fsSL ...)\""
    echo ""
    echo "Environment variables:"
    echo "  VMID       - VM ID (required)"
    echo "  IP         - Static IP address (e.g., 192.168.1.100/24)"
    echo "  GATEWAY    - Gateway IP (e.g., 192.168.1.1)"
    echo "  PASSWORD   - Root password (auto-generated if not set)"
    echo "  HOSTNAME   - VM hostname (default: supabase-vm)"
    echo "  STORAGE    - Storage pool (default: local-lvm)"
    exit 1
fi

msg_info "Creating Proxmox VM for Supabase..."
msg_info "VM ID: $VMID"
msg_info "This will create a VM and install Docker + Supabase"
echo ""

# Create VM
msg_info "Creating VM $VMID..."

qm create "$VMID" \
    --name "$HOSTNAME" \
    --memory "$RAM_MB" \
    --cores "$CPU_CORES" \
    --net0 virtio,bridge="$BRIDGE" \
    --boot order=scsi0 \
    --scsihw virtio-scsi-pci \
    --ostype l26 \
    --bios seabios \
    --machine q35 \
    --agent enabled=1

if [[ $? -ne 0 ]]; then
    msg_error "Failed to create VM"
    exit 1
fi

# Create disk
qm disk create "$VMID" \
    --storage "$STORAGE" \
    --size "$(echo $DISK_SIZE | sed 's/G//')" \
    --format qcow2

qm set "$VMID" --scsi0 "$STORAGE:$VMID/vm-$VMID-disk-0.qcow2"

# Configure cloud-init
msg_info "Configuring Cloud-Init..."

if [[ -z "$PASSWORD" ]]; then
    PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-20)
fi

qm set "$VMID" --ciuser root --cipassword "$PASSWORD"

if [[ -f ~/.ssh/id_rsa.pub ]]; then
    qm set "$VMID" --sshkeys ~/.ssh/id_rsa.pub
fi

if [[ -n "$IP" ]] && [[ -n "$GATEWAY" ]]; then
    qm set "$VMID" --ipconfig0 "ip=$IP/$NETMASK,gw=$GATEWAY"
fi

qm set "$VMID" --nameserver "$DNS" --hostname "$HOSTNAME"

if [[ -n "$TAGS" ]]; then
    qm set "$VMID" --tags "$TAGS"
fi

# Note: You need to import a cloud image or use ISO
msg_warning "VM created but needs a disk image."
msg_info "Please either:"
msg_info "1. Download and import a Debian/Ubuntu cloud image"
msg_info "2. Or attach an ISO and install manually"
msg_info ""
msg_info "To download Debian cloud image:"
msg_info "  wget https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
msg_info "  qm disk import $VMID debian-12-genericcloud-amd64.qcow2 $STORAGE"
msg_info ""
msg_info "VM Configuration:"
msg_info "  VMID: $VMID"
msg_info "  Password: $PASSWORD"
msg_info "  IP: ${IP:-DHCP}"

# If we have IP set and VM is running, proceed with installation
if [[ -n "$IP" ]]; then
    msg_info "Starting VM..."
    qm start "$VMID"
    
    msg_info "Waiting for VM to boot..."
    sleep 10
    
    # Try to run installation
    if exec_in_vm "echo 'VM is ready'" &>/dev/null; then
        install_application
    else
        msg_warning "VM is not ready for SSH yet."
        msg_info "Please wait for VM to fully boot, then run installation manually."
        msg_info "Or re-run this script after VM is booted."
    fi
fi


