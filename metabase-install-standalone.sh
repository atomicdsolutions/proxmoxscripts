#!/usr/bin/env bash
# Standalone Metabase Installation Script for Proxmox LXC
# No dependencies on community-scripts
# Copyright (c) 2025
# License: MIT

set -euo pipefail

# Source the LXC template
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lxc-template.sh"

# Metabase-specific configuration
APP="Metabase"
CPU_CORES="${CPU_CORES:-2}"
RAM_MB="${RAM_MB:-2048}"
ROOTFS_SIZE="${ROOTFS_SIZE:-8G}"
UNPRIVILEGED="${UNPRIVILEGED:-1}"
TAGS="${TAGS:-analytics;business-intelligence}"

# Installation function
install_application() {
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
    msg_info "Access Metabase at: http://${IP}:3000"
    msg_info "Default credentials: Set up on first login"
    echo ""
    msg_info "Management commands (run inside container):"
    echo "  Status:  systemctl status metabase"
    echo "  Start:   systemctl start metabase"
    echo "  Stop:    systemctl stop metabase"
    echo "  Restart: systemctl restart metabase"
    echo "  Logs:    journalctl -u metabase -f"
}

# Update function
update_metabase() {
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
}

# Main execution
if [[ "${1:-}" == "update" ]]; then
    update_metabase
    exit 0
fi

# Check if CTID is set
if [[ -z "${CTID:-}" ]]; then
    msg_error "CTID (Container ID) must be specified"
    echo ""
    echo "Usage:"
    echo "  CTID=100 $0                    # Create new container with ID 100"
    echo "  CTID=100 IP=192.168.1.100 GATEWAY=192.168.1.1 $0  # With network config"
    echo "  CTID=100 $0 update             # Update existing Metabase installation"
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

# The template script will handle container creation and call install_application()

