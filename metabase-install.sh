#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)
# Copyright (c) 2021-2025 community-scripts
# Author: Your Name
# License: MIT
# Source: https://www.metabase.com/

APP="Metabase"
var_tags="${var_tags:-analytics;business-intelligence}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-2048}"
var_disk="${var_disk:-8}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-1}"
# Prevent build_container from trying to download install script
var_install=""

header_info "$APP"
variables
color
catch_errors

function update_script() {
    header_info
    check_container_storage
    check_container_resources
    if [[ ! -f /opt/metabase/metabase.jar ]]; then
        msg_error "No ${APP} Installation Found!"
        exit
    fi
    msg_info "Updating ${APP} LXC"
    $STD apt update
    $STD apt -y upgrade
    
    msg_info "Checking for ${APP} updates"
    CURRENT_VERSION=$(java -jar /opt/metabase/metabase.jar version 2>/dev/null || echo "unknown")
    LATEST_VERSION=$(curl -s https://api.github.com/repos/metabase/metabase/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
    
    if [[ "$CURRENT_VERSION" != "$LATEST_VERSION" ]]; then
        msg_info "Updating Metabase from $CURRENT_VERSION to $LATEST_VERSION"
        systemctl stop metabase
        wget -q -O /opt/metabase/metabase.jar "https://downloads.metabase.com/v${LATEST_VERSION}/metabase.jar"
        systemctl start metabase
        msg_ok "Updated to version $LATEST_VERSION"
    else
        msg_ok "Already on latest version"
    fi
    exit
}

start
build_container
description

msg_info "Installing dependencies"
$STD bash -c "apt update && apt install -y curl wget openjdk-17-jre-headless"

msg_info "Creating Metabase user"
$STD bash -c "if ! id -u metabase >/dev/null 2>&1; then useradd -r -s /bin/false -d /opt/metabase -m metabase; fi"

msg_info "Creating Metabase directory"
$STD bash -c "mkdir -p /opt/metabase/data && chown -R metabase:metabase /opt/metabase"

msg_info "Downloading latest Metabase"
LATEST_VERSION=$(curl -s https://api.github.com/repos/metabase/metabase/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
if [[ -z "$LATEST_VERSION" ]]; then
    LATEST_VERSION="latest"
    DOWNLOAD_URL="https://downloads.metabase.com/${LATEST_VERSION}/metabase.jar"
else
    DOWNLOAD_URL="https://downloads.metabase.com/v${LATEST_VERSION}/metabase.jar"
fi

$STD bash -c "wget -q -O /opt/metabase/metabase.jar '${DOWNLOAD_URL}' && chown metabase:metabase /opt/metabase/metabase.jar && chmod 755 /opt/metabase/metabase.jar"

msg_info "Creating systemd service"
$STD bash -c 'cat > /etc/systemd/system/metabase.service <<EOF
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

msg_info "Enabling and starting Metabase service"
$STD bash -c "systemctl daemon-reload && systemctl enable metabase && systemctl start metabase"

msg_info "Waiting for Metabase to start"
sleep 5

msg_info "Checking Metabase status"
if $STD bash -c "systemctl is-active --quiet metabase"; then
    msg_ok "Metabase service is running"
else
    msg_warning "Metabase service may still be starting. Check logs with: journalctl -u metabase -f"
fi

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access it using the following URL:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:3000${CL}"
echo -e "${INFO}${YW} Default credentials: Set up on first login${CL}"
echo ""
echo -e "${INFO}${YW} Management Commands:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}Status:${CL} systemctl status metabase"
echo -e "${TAB}${GATEWAY}${BGN}Start:${CL} systemctl start metabase"
echo -e "${TAB}${GATEWAY}${BGN}Stop:${CL} systemctl stop metabase"
echo -e "${TAB}${GATEWAY}${BGN}Restart:${CL} systemctl restart metabase"
echo -e "${TAB}${GATEWAY}${BGN}Logs:${CL} journalctl -u metabase -f"
echo ""
echo -e "${INFO}${YW} File Locations:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}JAR file:${CL} /opt/metabase/metabase.jar"
echo -e "${TAB}${GATEWAY}${BGN}Data directory:${CL} /opt/metabase/data"
