#!/usr/bin/env bash
# Standalone Proxmox VM Creation Template for Docker Applications
# No dependencies on external scripts - works independently
# Copyright (c) 2025
# License: MIT

set -e

# Color codes for output
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

# Default configuration (can be overridden by environment variables)
APP="${APP:-Application}"
VMID="${VMID:-}"
STORAGE="${STORAGE:-local-lvm}"
ISO_STORAGE="${ISO_STORAGE:-local}"
TEMPLATE="${TEMPLATE:-debian-12-genericcloud-amd64}"
PASSWORD="${PASSWORD:-}"
DISK_SIZE="${DISK_SIZE:-32G}"
CPU_CORES="${CPU_CORES:-2}"
RAM_MB="${RAM_MB:-4096}"
HOSTNAME="${HOSTNAME:-}"
IP="${IP:-}"
NETMASK="${NETMASK:-24}"
GATEWAY="${GATEWAY:-}"
BRIDGE="${BRIDGE:-vmbr0}"
SSH_KEY="${SSH_KEY:-}"
DNS="${DNS:-8.8.8.8}"
CLOUD_INIT="${CLOUD_INIT:-1}"
TAGS="${TAGS:-}"
OS_TYPE="${OS_TYPE:-l26}"
BIOS="${BIOS:-seabios}"
MACHINE="${MACHINE:-q35}"
SCSI_CONTROLLER="${SCSI_CONTROLLER:-virtio-scsi-pci}"

# Validate required parameters
if [[ -z "$VMID" ]]; then
    msg_error "VMID (VM ID) must be specified. Set it with: export VMID=100"
    exit 1
fi

# Generate password if not set
if [[ -z "$PASSWORD" ]]; then
    PASSWORD=$(openssl rand -base64 32 2>/dev/null | tr -d "=+/" | cut -c1-20 || echo "changeme123")
    msg_info "Generated random password: $PASSWORD"
fi

if [[ -z "$HOSTNAME" ]]; then
    HOSTNAME="${APP,,}-vm"
fi

# Validate network configuration if IP is provided
if [[ -n "$IP" ]] && [[ -z "$GATEWAY" ]]; then
    msg_warning "IP provided but no gateway. VM may have network issues."
    msg_info "Please set GATEWAY environment variable"
fi

# Check if VM ID already exists
if qm status "$VMID" &>/dev/null; then
    msg_warning "VM $VMID already exists"
    read -p "Do you want to use the existing VM? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        msg_error "Aborted. Please choose a different VMID."
        exit 1
    fi
    msg_info "Using existing VM $VMID"
    EXISTING_VM=1
else
    EXISTING_VM=0
fi

# Check if template/ISO exists
if [[ -n "$TEMPLATE" ]]; then
    # Check for cloud image templates
    if ! qm template list 2>/dev/null | grep -q "$TEMPLATE"; then
        # Check if it's an ISO file
        if [[ "$TEMPLATE" == *.iso ]] || [[ "$TEMPLATE" == *.img ]]; then
            if [[ ! -f "$TEMPLATE" ]] && [[ ! -f "/var/lib/vz/template/iso/$TEMPLATE" ]]; then
                msg_warning "ISO/Template file not found: $TEMPLATE"
                msg_info "Available ISOs in $ISO_STORAGE:"
                qm template list 2>/dev/null || echo "  No templates found"
                ls -1 /var/lib/vz/template/iso/*.iso 2>/dev/null | head -5 || echo "  No ISOs found"
                exit 1
            fi
        else
            msg_warning "Template not found. Will try to download or use ISO."
        fi
    fi
fi

msg_info "========================================="
msg_info "Proxmox VM Setup - $APP"
msg_info "========================================="
msg_info "VM ID: $VMID"
msg_info "Hostname: $HOSTNAME"
msg_info "Template/ISO: $TEMPLATE"
msg_info "CPU Cores: $CPU_CORES"
msg_info "RAM: ${RAM_MB}MB"
msg_info "Disk: $DISK_SIZE"
msg_info "OS Type: $OS_TYPE"
msg_info "Cloud-Init: $CLOUD_INIT"
msg_info "========================================="

# Create VM if it doesn't exist
if [[ $EXISTING_VM -eq 0 ]]; then
    msg_info "Creating VM $VMID..."
    
    # Create VM
    qm create "$VMID" \
        --name "$HOSTNAME" \
        --memory "$RAM_MB" \
        --cores "$CPU_CORES" \
        --net0 virtio,bridge="$BRIDGE" \
        --boot order=scsi0 \
        --scsihw "$SCSI_CONTROLLER" \
        --ostype "$OS_TYPE" \
        --bios "$BIOS" \
        --machine "$MACHINE" \
        --agent enabled=1
    
    if [[ $? -ne 0 ]]; then
        msg_error "Failed to create VM"
        exit 1
    fi
    
    msg_ok "VM $VMID created"
    
    # Import disk/image
    if [[ "$TEMPLATE" == *.iso ]]; then
        msg_info "Attaching ISO: $TEMPLATE"
        qm set "$VMID" --cdrom "$ISO_STORAGE:iso/$TEMPLATE"
        msg_info "Note: This is an ISO. You'll need to install the OS manually or use cloud-init compatible image."
    elif [[ -f "/var/lib/vz/template/qemu/$TEMPLATE.tar.gz" ]] || [[ -f "/var/lib/vz/template/qemu/$TEMPLATE.qcow2" ]]; then
        msg_info "Importing template: $TEMPLATE"
        qm disk import "$VMID" "/var/lib/vz/template/qemu/$TEMPLATE" "$STORAGE" --format qcow2
    elif qm template list 2>/dev/null | grep -q "$TEMPLATE"; then
        msg_info "Cloning from template: $TEMPLATE"
        # This would require template VM ID
        msg_warning "Template cloning requires template VMID. Using manual import instead."
        msg_info "Please download cloud image manually or use ISO installation."
    else
        # Create empty disk for manual installation
        msg_info "Creating empty disk (manual installation required)"
        qm disk create "$VMID" \
            --storage "$STORAGE" \
            --size "$DISK_SIZE" \
            --format qcow2 \
            --scsi0 "$STORAGE:$VMID/vm-$VMID-disk-0.qcow2"
    fi
    
    # Set disk
    qm set "$VMID" --scsi0 "$STORAGE:$VMID/vm-$VMID-disk-0.qcow2,size=$(echo $DISK_SIZE | sed 's/G//')"
    
    # Configure cloud-init if enabled
    if [[ "$CLOUD_INIT" == "1" ]]; then
        msg_info "Configuring Cloud-Init..."
        
        qm set "$VMID" --ciuser root
        
        if [[ -n "$PASSWORD" ]]; then
            qm set "$VMID" --cipassword "$PASSWORD"
        fi
        
        if [[ -n "$SSH_KEY" ]]; then
            qm set "$VMID" --sshkeys "$SSH_KEY"
        elif [[ -f ~/.ssh/id_rsa.pub ]]; then
            msg_info "Using default SSH key: ~/.ssh/id_rsa.pub"
            qm set "$VMID" --sshkeys ~/.ssh/id_rsa.pub
        fi
        
        # Network configuration
        if [[ -n "$IP" ]] && [[ -n "$GATEWAY" ]]; then
            qm set "$VMID" --ipconfig0 "ip=$IP/$NETMASK,gw=$GATEWAY"
        fi
        
        # DNS
        qm set "$VMID" --nameserver "$DNS"
        
        # Hostname
        qm set "$VMID" --hostname "$HOSTNAME"
    fi
    
    # Tags
    if [[ -n "$TAGS" ]]; then
        qm set "$VMID" --tags "$TAGS"
    fi
    
    msg_ok "VM $VMID configured"
else
    msg_info "Using existing VM $VMID"
fi

# Function to execute commands in VM via SSH (after VM is running)
exec_in_vm() {
    local max_attempts=30
    local attempt=0
    
    # Wait for SSH to be available
    while [[ $attempt -lt $max_attempts ]]; do
        if ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no root@"$IP" "echo 'Connected'" &>/dev/null; then
            ssh -o StrictHostKeyChecking=no root@"$IP" "$1"
            return $?
        fi
        sleep 2
        ((attempt++))
    done
    
    msg_error "Could not connect to VM via SSH"
    return 1
}

# Start VM
msg_info "Starting VM $VMID..."
qm start "$VMID"

if [[ $? -eq 0 ]]; then
    msg_ok "VM $VMID started"
else
    msg_error "Failed to start VM"
    exit 1
fi

# Wait for VM to boot and get IP
msg_info "Waiting for VM to boot and get IP address..."
sleep 5

# Get VM IP if not set
if [[ -z "$IP" ]]; then
    msg_info "Detecting VM IP address..."
    for i in {1..60}; do
        IP=$(qm guest cmd "$VMID" network-get-interfaces 2>/dev/null | grep -oP '"ip-addresses":\s*\[\s*\{\s*"ip-address":\s*"\K[^"]+' | head -1 || echo "")
        if [[ -n "$IP" ]] && [[ "$IP" != "127.0.0.1" ]]; then
            break
        fi
        sleep 2
    done
    
    if [[ -z "$IP" ]]; then
        msg_warning "Could not automatically detect IP. You may need to check manually."
        msg_info "Check VM IP in Proxmox web interface or with: qm guest cmd $VMID network-get-interfaces"
    else
        msg_info "Detected VM IP: $IP"
    fi
fi

msg_ok "VM $VMID is ready"
msg_info "VM IP: ${IP:-<check manually>}"
msg_info "Root Password: $PASSWORD"
if [[ -n "$SSH_KEY" ]] || [[ -f ~/.ssh/id_rsa.pub ]]; then
    msg_info "SSH Key: Configured"
fi
echo ""

# This function should be overridden by the calling script
# or commands can be added after sourcing this template
if declare -f install_application &> /dev/null; then
    if [[ -n "$IP" ]]; then
        msg_info "Waiting for SSH to be ready..."
        sleep 10
        msg_info "Running application installation..."
        install_application
    else
        msg_warning "IP not available. Cannot run automated installation."
        msg_info "Please configure the VM manually or set IP environment variable."
    fi
else
    msg_info "No install_application() function defined."
    msg_info "VM is ready for manual configuration or Docker setup."
fi

msg_ok "Setup completed!"
echo ""
msg_info "Useful commands:"
echo "  Start VM:      qm start $VMID"
echo "  Stop VM:       qm stop $VMID"
echo "  Console:       qm terminal $VMID"
echo "  VNC:           qm monitor $VMID"
echo "  SSH:           ssh root@${IP:-<VM_IP>}"
echo "  Status:        qm status $VMID"
echo "  Destroy VM:    qm destroy $VMID"


