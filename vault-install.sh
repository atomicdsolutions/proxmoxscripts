#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)
# Copyright (c) 2021-2025 community-scripts
# Author: Your Name
# License: MIT
# Source: https://www.vaultproject.io/

APP="Vault"
var_tags="${var_tags:-security;secrets-management}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-2048}"
var_disk="${var_disk:-10}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
    header_info
    check_container_storage
    check_container_resources
    if [[ ! -f /usr/bin/vault ]]; then
        msg_error "No ${APP} Installation Found!"
        exit
    fi
    msg_info "Updating ${APP} LXC"
    $STD apt update
    $STD apt -y upgrade
    
    msg_info "Checking for ${APP} updates"
    CURRENT_VERSION=$(vault version 2>/dev/null | head -n1 | sed -E 's/.*v([0-9]+\.[0-9]+\.[0-9]+).*/\1/' || echo "unknown")
    LATEST_VERSION=$(curl -s https://api.github.com/repos/hashicorp/vault/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
    
    if [[ "$CURRENT_VERSION" != "$LATEST_VERSION" ]] && [[ "$LATEST_VERSION" != "" ]]; then
        msg_info "Updating Vault from $CURRENT_VERSION to $LATEST_VERSION"
        systemctl stop vault
        
        # Update HashiCorp repository
        $STD apt update
        $STD apt install -y vault=${LATEST_VERSION}
        
        systemctl start vault
        msg_ok "Updated to version $LATEST_VERSION"
    else
        msg_ok "Already on latest version ($CURRENT_VERSION)"
    fi
    exit
}

start
build_container
description

msg_info "Installing dependencies"
$STD apt update
$STD apt install -y curl gnupg lsb-release ca-certificates

msg_info "Installing HashiCorp GPG key"
curl -fsSL https://apt.releases.hashicorp.com/gpg | $STD gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg

msg_info "Adding HashiCorp repository"
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | $STD tee /etc/apt/sources.list.d/hashicorp.list

msg_info "Installing Vault"
$STD apt update
$STD apt install -y vault

msg_info "Creating Vault directories"
$STD mkdir -p /opt/vault/data
$STD mkdir -p /etc/vault.d

msg_info "Creating Vault user"
if ! id -u vault >/dev/null 2>&1; then
    $STD useradd --system --home /etc/vault.d --shell /bin/false vault
fi

msg_info "Configuring Vault"
cat > /etc/vault.d/vault.hcl <<EOF
ui = true
disable_mlock = true

storage "file" {
  path = "/opt/vault/data"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1
}

api_addr = "http://${IP}:8200"
cluster_addr = "http://${IP}:8201"
EOF

msg_info "Setting permissions"
$STD chown -R vault:vault /opt/vault
$STD chown -R vault:vault /etc/vault.d
$STD chmod 700 /opt/vault/data

msg_info "Creating systemd service"
cat > /etc/systemd/system/vault.service <<EOF
[Unit]
Description=HashiCorp Vault - A tool for managing secrets
Documentation=https://www.vaultproject.io/docs/
Requires=network-online.target
After=network-online.target
ConditionFileNotEmpty=/etc/vault.d/vault.hcl
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=notify
User=vault
Group=vault
ProtectSystem=full
ProtectHome=read-only
PrivateTmp=yes
PrivateDevices=yes
SecureBits=keep-caps
AmbientCapabilities=CAP_IPC_LOCK
CapabilityBoundingSet=CAP_SYSLOG CAP_IPC_LOCK
NoNewPrivileges=yes
ExecStart=/usr/bin/vault server -config=/etc/vault.d/vault.hcl
ExecReload=/bin/kill --signal HUP \$MAINPID
KillMode=process
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
LimitNOFILE=65536
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
EOF

msg_info "Enabling and starting Vault service"
$STD systemctl daemon-reload
$STD systemctl enable vault
$STD systemctl start vault

msg_info "Waiting for Vault to start"
sleep 5

msg_info "Checking Vault status"
if systemctl is-active --quiet vault; then
    msg_ok "Vault service is running"
    VAULT_STATUS=$(vault status 2>&1 || echo "sealed")
    if echo "$VAULT_STATUS" | grep -q "sealed"; then
        msg_warning "Vault is sealed and needs initialization"
    fi
else
    msg_error "Vault service failed to start"
    systemctl status vault --no-pager -l
    exit 1
fi

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo ""
echo -e "${INFO}${YW} Access Points:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}Vault UI:${CL} ${GN}http://${IP}:8200/ui${CL}"
echo -e "${TAB}${GATEWAY}${BGN}Vault API:${CL} ${GN}http://${IP}:8200${CL}"
echo ""
echo -e "${INFO}${YW} Next Steps:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}1.${CL} Initialize Vault: ${GN}vault operator init${CL}"
echo -e "${TAB}${GATEWAY}${BGN}2.${CL} Save the unseal keys and root token securely"
echo -e "${TAB}${GATEWAY}${BGN}3.${CL} Unseal Vault: ${GN}vault operator unseal <key>${CL} (repeat 3 times)"
echo -e "${TAB}${GATEWAY}${BGN}4.${CL} Login: ${GN}vault login <root-token>${CL}"
echo -e "${TAB}${GATEWAY}${BGN}5.${CL} Access the UI at http://${IP}:8200/ui"
echo ""
echo -e "${INFO}${YW} Management Commands:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}Status:${CL} vault status"
echo -e "${TAB}${GATEWAY}${BGN}Start:${CL} systemctl start vault"
echo -e "${TAB}${GATEWAY}${BGN}Stop:${CL} systemctl stop vault"
echo -e "${TAB}${GATEWAY}${BGN}Restart:${CL} systemctl restart vault"
echo -e "${TAB}${GATEWAY}${BGN}Logs:${CL} journalctl -u vault -f"
echo ""
echo -e "${WARN}${YW} Security Notes:${CL}"
echo -e "${TAB}${YW}• Vault is currently configured with TLS disabled (tls_disable = 1)${CL}"
echo -e "${TAB}${YW}• For production, enable TLS and configure certificates${CL}"
echo -e "${TAB}${YW}• Store unseal keys and root token in a secure location${CL}"
echo -e "${TAB}${YW}• Consider using auto-unseal or integrated storage for production${CL}"
echo -e "${TAB}${YW}• Configuration file: /etc/vault.d/vault.hcl${CL}"
echo -e "${TAB}${YW}• Data directory: /opt/vault/data${CL}"

