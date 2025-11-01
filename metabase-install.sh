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

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access it using the following URL:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:3000${CL}"
echo -e "${INFO}${YW} Default credentials: Set up on first login${CL}"
