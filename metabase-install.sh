#!/usr/bin/env bash
# Copyright (c) 2021-2025 tteck
# Author: tteck (tteckster)
# License: MIT
# https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE

function header_info {
  clear
  cat <<"EOF"
    __  __      _       _               
   |  \/  |    | |     | |              
   | \  / | ___| |_ ___| |__   __ _ ___ 
   | |\/| |/ _ \ __/ _ \ '_ \ / _` / __|
   | |  | |  __/ ||  __/ |_) | (_| \__ \
   |_|  |_|\___|\__\___|_.__/ \__,_|___/
                                       
EOF
}

set -eEuo pipefail
shopt -s expand_aliases
alias die='EXIT=$? LINE=$LINENO error_exit'
trap die ERR
function error_exit() {
  trap - ERR
  local DEFAULT='Unknown failure occured.'
  local REASON="\e[97m${1:-$DEFAULT}\e[39m"
  local FLAG="\e[91m[ERROR] \e[93m$EXIT@$LINE"
  msg "$FLAG $REASON" 1>&2
  [ ! -z ${CTID-} ] && cleanup_ctid
  exit $EXIT
}
function warn() {
  local REASON="\e[97m$1\e[39m"
  local FLAG="\e[93m[WARNING]\e[39m"
  msg "$FLAG $REASON"
}
function info() {
  local REASON="$1"
  local FLAG="\e[36m[INFO]\e[39m"
  msg "$FLAG $REASON"
}
function msg() {
  local TEXT="$1"
  echo -e "$TEXT"
}
function cleanup_ctid() {
  if pct status $CTID &>/dev/null; then
    if [ "$(pct status $CTID | awk '{print $2}')" == "running" ]; then
      pct stop $CTID
    fi
    pct destroy $CTID
  fi
}

# Stop Proxmox VE Monitor-All if running
if systemctl is-active -q ping-instances.service; then
  systemctl stop ping-instances.service
fi

header_info
echo "Loading..."
pveam update >/dev/null 2>&1

whiptail --backtitle "Proxmox VE Helper Scripts" --title "Metabase LXC" --yesno "This will create a new LXC container with Metabase installed natively. Proceed?" 10 68 || exit

# Setup script environment
NAME="metabase"
PASS="$(openssl rand -base64 8)"
CTID=$(pvesh get /cluster/nextid)
PCT_OPTIONS="
    -features keyctl=1,nesting=1
    -hostname $NAME
    -tags proxmox-helper-scripts
    -onboot 1
    -cores 2
    -memory 2048
    -swap 512
    -password $PASS
    -net0 name=eth0,bridge=vmbr0,ip=dhcp
    -unprivileged 1
  "
DEFAULT_PCT_OPTIONS=(
  -arch $(dpkg --print-architecture)
)

# Set the CONTENT and CONTENT_LABEL variables
function select_storage() {
  local CLASS=$1
  local CONTENT
  local CONTENT_LABEL
  case $CLASS in
  container)
    CONTENT='rootdir'
    CONTENT_LABEL='Container'
    ;;
  template)
    CONTENT='vztmpl'
    CONTENT_LABEL='Container template'
    ;;
  *) false || die "Invalid storage class." ;;
  esac

  # Query all storage locations
  local -a MENU
  while read -r line; do
    local TAG=$(echo $line | awk '{print $1}')
    local TYPE=$(echo $line | awk '{printf "%-10s", $2}')
    local FREE=$(echo $line | numfmt --field 4-6 --from-unit=K --to=iec --format %.2f | awk '{printf( "%9sB", $6)}')
    local ITEM="  Type: $TYPE Free: $FREE "
    local OFFSET=2
    if [[ $((${#ITEM} + $OFFSET)) -gt ${MSG_MAX_LENGTH:-} ]]; then
      local MSG_MAX_LENGTH=$((${#ITEM} + $OFFSET))
    fi
    MENU+=("$TAG" "$ITEM" "OFF")
  done < <(pvesm status -content $CONTENT | awk 'NR>1')

  # Select storage location
  if [ $((${#MENU[@]} / 3)) -eq 0 ]; then
    warn "'$CONTENT_LABEL' needs to be selected for at least one storage location."
    die "Unable to detect valid storage location."
  elif [ $((${#MENU[@]} / 3)) -eq 1 ]; then
    printf ${MENU[0]}
  else
    local STORAGE
    while [ -z "${STORAGE:+x}" ]; do
      STORAGE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Storage Pools" --radiolist \
        "Which storage pool would you like to use for the ${CONTENT_LABEL,,}?\n\n" \
        16 $(($MSG_MAX_LENGTH + 23)) 6 \
        "${MENU[@]}" 3>&1 1>&2 2>&3) || die "Menu aborted."
    done
    printf $STORAGE
  fi
}

header_info
# Get template storage
TEMPLATE_STORAGE=$(select_storage template)
info "Using '$TEMPLATE_STORAGE' for template storage."

# Get container storage
CONTAINER_STORAGE=$(select_storage container)
info "Using '$CONTAINER_STORAGE' for container storage."

# Select template
TEMPLATE_MENU=()
MSG_MAX_LENGTH=0
while read -r TAG ITEM; do
  OFFSET=2
  ((${#ITEM} + OFFSET > MSG_MAX_LENGTH)) && MSG_MAX_LENGTH=${#ITEM}+OFFSET
  TEMPLATE_MENU+=("$ITEM" "$TAG " "OFF")
done < <(pveam available | grep -i debian)

if [ $((${#TEMPLATE_MENU[@]} / 3)) -eq 0 ]; then
  warn "No Debian templates available. Downloading latest Debian 12 template..."
  pveam download $TEMPLATE_STORAGE debian-12-standard >/dev/null || die "Failed to download template"
  TEMPLATE="debian-12-standard"
else
  TEMPLATE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Select Template" --radiolist \
    "\nSelect a Debian template:\n" 16 $((MSG_MAX_LENGTH + 58)) 10 "${TEMPLATE_MENU[@]}" \
    3>&1 1>&2 2>&3 | tr -d '"')
  [ -z "$TEMPLATE" ] && die "No template selected"
fi

# Download template if not already available
if ! pveam list $TEMPLATE_STORAGE | grep -q "$TEMPLATE"; then
  msg "Downloading LXC template (Patience)..."
  pveam download $TEMPLATE_STORAGE $TEMPLATE >/dev/null || die "A problem occured while downloading the LXC template."
fi

# Create variable for 'pct' options
PCT_OPTIONS=(${PCT_OPTIONS[@]:-${DEFAULT_PCT_OPTIONS[@]}})
[[ " ${PCT_OPTIONS[@]} " =~ " -rootfs " ]] || PCT_OPTIONS+=(-rootfs $CONTAINER_STORAGE:${PCT_DISK_SIZE:-8})

# Create LXC
msg "Creating LXC container..."
pct create $CTID ${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE} ${PCT_OPTIONS[@]} >/dev/null ||
  die "A problem occured while trying to create container."

# Save password
echo "$NAME password: ${PASS}" >>~/$NAME.creds

# Start container
msg "Starting LXC Container..."
pct start "$CTID"
sleep 5

# Get container IP
set +eEuo pipefail
max_attempts=5
attempt=1
IP=""
while [[ $attempt -le $max_attempts ]]; do
  IP=$(pct exec $CTID ip a show dev eth0 | grep -oP 'inet \K[^/]+')
  if [[ -n $IP ]]; then
    break
  else
    warn "Attempt $attempt: IP address not found. Pausing for 5 seconds..."
    sleep 5
    ((attempt++))
  fi
done

if [[ -z $IP ]]; then
  warn "Maximum number of attempts reached. IP address not found."
  IP="NOT FOUND"
fi

set -eEuo pipefail

# Install Metabase (following Docker best practices)
msg "Installing Metabase dependencies..."
pct exec $CTID -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get update && apt-get install -y --no-install-recommends curl openjdk-21-jre-headless && apt-get clean && rm -rf /var/lib/apt/lists/*"

msg "Creating Metabase user..."
pct exec $CTID -- bash -c "if ! id -u metabase >/dev/null 2>&1; then useradd -r -s /bin/false -d /opt/metabase -m metabase; fi"

msg "Creating Metabase directories..."
pct exec $CTID -- bash -c "mkdir -p /opt/metabase/data && chown -R metabase:metabase /opt/metabase"

# Get latest Metabase version
msg "Checking for latest Metabase version..."
MB_VERSION=$(curl -s https://api.github.com/repos/metabase/metabase/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
if [[ -z "$MB_VERSION" ]]; then
  warn "Could not determine latest version, using 'latest'"
  MB_VERSION="latest"
fi
MB_VERSION="v${MB_VERSION}"

# JVM Heap size - default 512m (matching Dockerfile)
MB_JAVA_HEAP="${MB_JAVA_HEAP:-512m}"

msg "Downloading Metabase ${MB_VERSION}..."
DOWNLOAD_URL="https://downloads.metabase.com/${MB_VERSION}/metabase.jar"
pct exec $CTID -- bash -c "curl -L -o /opt/metabase/metabase.jar '${DOWNLOAD_URL}' && chown metabase:metabase /opt/metabase/metabase.jar && chmod 644 /opt/metabase/metabase.jar" ||
  die "Failed to download Metabase"

msg "Creating systemd service..."
pct exec $CTID -- bash -c "cat > /etc/systemd/system/metabase.service <<'MBEOF'
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
Environment=\"MB_JAVA_HEAP=${MB_JAVA_HEAP}\"
ExecStart=/usr/bin/java -Xmx${MB_JAVA_HEAP} -jar /opt/metabase/metabase.jar
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
MBEOF"

msg "Enabling and starting Metabase service..."
pct exec $CTID -- bash -c "systemctl daemon-reload && systemctl enable metabase && systemctl start metabase"

msg "Waiting for Metabase to start..."
sleep 5

# Start Proxmox VE Monitor-All if available
if [[ -f /etc/systemd/system/ping-instances.service ]]; then
  systemctl start ping-instances.service
fi

# Success message
header_info
echo
info "LXC container '$CTID' was successfully created!"
echo
info "Container Details:"
info "  Container ID: $CTID"
info "  IP Address: ${IP}"
info "  Hostname: $NAME"
echo
info "Metabase Details:"
info "  Version: ${MB_VERSION}"
info "  JVM Heap: ${MB_JAVA_HEAP}"
info "  Access: http://${IP}:3000"
echo
info "Login to container:"
info "  login: root"
info "  password: $PASS"
echo
info "Credentials saved to: ~/$NAME.creds"
echo
warn "Default Metabase credentials will be set up on first login at http://${IP}:3000"
echo

