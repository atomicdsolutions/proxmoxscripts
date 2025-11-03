#!/usr/bin/env bash
# Copyright (c) 2021-2025 tteck
# Author: tteck (tteckster)
# License: MIT
# https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE

function header_info {
  clear
  cat <<"EOF"
   _____                              _        
  / ____|                            | |       
 | (___  _   _  ___ ___ ___  ___ ___ | |_ __ _ 
  \___ \| | | |/ _ / __/ __|/ _ / __| __/ _` |
  ____) | |_| |  __\__ \__ \  __\__ | || (_| |
 |_____/ \__,_|\___|___/___/\___|___/\__\__,_|
                                               
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
  if pct status $CTID &>/dev/null 2>&1; then
    if [ "$(pct status $CTID 2>/dev/null | awk '{print $2}')" == "running" ]; then
      pct stop $CTID 2>/dev/null || true
    fi
    pct destroy $CTID 2>/dev/null || true
  fi
}

# Stop Proxmox VE Monitor-All if running
if systemctl is-active -q ping-instances.service; then
  systemctl stop ping-instances.service
fi

header_info
echo "Loading..."
pveam update >/dev/null 2>&1

whiptail --backtitle "Proxmox VE Helper Scripts" --title "Supabase LXC" --yesno "This will create a new LXC container with Supabase (PostgreSQL, Auth, API, Storage, Realtime, Edge Functions) installed via Docker. Requires at least 4GB RAM and 32GB disk. Proceed?" 12 68 || exit

# Setup script environment
NAME="supabase"
PASS="$(openssl rand -base64 8)"
CTID=$(pvesh get /cluster/nextid)
# Supabase requires more resources than Metabase
PCT_OPTIONS="
    -features keyctl=1,nesting=1
    -hostname $NAME
    -tags proxmox-helper-scripts
    -onboot 1
    -cores 4
    -memory 4096
    -swap 1024
    -password $PASS
    -net0 name=eth0,bridge=vmbr0,ip=dhcp
    -unprivileged 0
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
[[ " ${PCT_OPTIONS[@]} " =~ " -rootfs " ]] || PCT_OPTIONS+=(-rootfs $CONTAINER_STORAGE:${PCT_DISK_SIZE:-32})

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

# Install Docker and dependencies
msg "Installing Docker and dependencies..."
# Get Debian codename (fallback methods)
pct exec $CTID -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get update && apt-get install -y --no-install-recommends ca-certificates curl gnupg lsb-release"
DEBIAN_CODENAME=$(pct exec $CTID -- bash -c "lsb_release -cs 2>/dev/null || grep VERSION_CODENAME /etc/os-release | cut -d= -f2 | tr -d '\"' || echo 'bookworm'")
pct exec $CTID -- bash -c "install -m 0755 -d /etc/apt/keyrings && curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg && chmod a+r /etc/apt/keyrings/docker.gpg && echo \"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${DEBIAN_CODENAME} stable\" | tee /etc/apt/sources.list.d/docker.list > /dev/null && apt-get update && apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin && apt-get clean && rm -rf /var/lib/apt/lists/*"

msg "Starting Docker service..."
pct exec $CTID -- bash -c "systemctl enable docker && systemctl start docker"

# Install Docker Compose standalone (if docker compose plugin not available)
msg "Verifying Docker Compose..."
pct exec $CTID -- bash -c "if ! docker compose version &>/dev/null; then curl -L \"https://github.com/docker/compose/releases/latest/download/docker-compose-\$(uname -s)-\$(uname -m)\" -o /usr/local/bin/docker-compose && chmod +x /usr/local/bin/docker-compose && ln -sf /usr/local/bin/docker-compose /usr/local/bin/docker-compose-v1; fi"

# Create Supabase directory structure
msg "Creating Supabase directory structure..."
pct exec $CTID -- bash -c "mkdir -p /opt/supabase/{volumes/postgres,volumes/storage,volumes/db,volumes/kong,volumes/logs} && chmod -R 755 /opt/supabase"

# Generate secure passwords and keys
msg "Generating secure passwords and API keys..."
DB_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-24)
JWT_SECRET=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-32)
ANON_KEY=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-32)
SERVICE_ROLE_KEY=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-32)
ENCRYPTION_KEY=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-32)

# Install Supabase CLI
msg "Installing Supabase CLI..."
pct exec $CTID -- bash -c "curl -fsSL https://github.com/supabase/cli/releases/latest/download/supabase_linux_amd64.tar.gz -o /tmp/supabase.tar.gz && tar -xzf /tmp/supabase.tar.gz -C /usr/local/bin && chmod +x /usr/local/bin/supabase && rm -f /tmp/supabase.tar.gz"

# Initialize Supabase project
msg "Initializing Supabase project..."
pct exec $CTID -- bash -c "cd /opt && supabase init --name $NAME || true"

# Create .env file with all required configuration
msg "Creating Supabase configuration (.env)..."
pct exec $CTID -- bash -c "cat > /opt/supabase/.env <<'ENVEOF'
POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
POSTGRES_HOST=db
POSTGRES_DB=postgres
POSTGRES_PORT=5432
POSTGRES_USER=postgres

# API Configuration
API_URL=http://${IP}:8000
GOTRUE_API_HOST=0.0.0.0
GOTRUE_API_PORT=9999
GOTRUE_API_EXTERNAL_URL=http://${IP}:8000

# JWT Configuration
JWT_SECRET=\${JWT_SECRET}
JWT_EXP=3600
JWT_DEFAULT_GROUP_NAME=authenticated

# GoTrue (Auth Service)
GOTRUE_SITE_URL=http://${IP}:8000
GOTRUE_URI_ALLOW_LIST=http://${IP}:8000
GOTRUE_DISABLE_SIGNUP=false
GOTRUE_JWT_SECRET=\${JWT_SECRET}
GOTRUE_JWT_EXP=3600
GOTRUE_JWT_DEFAULT_GROUP_NAME=authenticated
GOTRUE_DB_DRIVER=postgres
GOTRUE_DB_URI=postgres://supabase_auth_admin:\${POSTGRES_PASSWORD}@db:5432/postgres

# PostgREST (API Service)
PGRST_DB_URI=postgres://authenticator:\${POSTGRES_PASSWORD}@db:5432/postgres
PGRST_DB_SCHEMAS=public,storage,graphql_public
PGRST_DB_EXTRA_SEARCH_PATH=public,extensions
PGRST_DB_ANON_ROLE=anon
PGRST_JWT_SECRET=\${JWT_SECRET}

# Storage Service
STORAGE_BACKEND=file
STORAGE_FILE_SIZE_LIMIT=52428800
STORAGE_S3_BUCKET=supabase
STORAGE_S3_REGION=us-east-1
FILE_STORAGE_BACKEND_PATH=/var/lib/storage
STORAGE_DB_URI=postgres://supabase_storage_admin:\${POSTGRES_PASSWORD}@db:5432/postgres

# Realtime Service
REALTIME_DB_HOST=db
REALTIME_DB_PORT=5432
REALTIME_DB_USER=supabase_realtime_admin
REALTIME_DB_PASSWORD=\${POSTGRES_PASSWORD}
REALTIME_DB_NAME=postgres
REALTIME_DB_URI=postgres://supabase_realtime_admin:\${POSTGRES_PASSWORD}@db:5432/postgres

# Studio (Dashboard)
STUDIO_PORT=3000
STUDIO_API_URL=http://${IP}:8000

# Kong API Gateway
KONG_DATABASE=off
KONG_DECLARATIVE_CONFIG=/var/lib/kong/kong.yml
KONG_DNS_ORDER=LAST,A,CNAME

# Edge Functions
ENABLE_EDGE_RUNTIME=true
FUNCTIONS_PATH=/var/lib/supabase/functions

# Database Extensions
ENABLE_PGVECTOR=true

# Additional required variables
SECRET_KEY_BASE=\${SECRET_KEY_BASE}
POOLER_DB_POOL_SIZE=20
POOLER_DB_MAX_CLIENT_CONN=100

# Logging
LOG_LEVEL=info
ENVEOF"

# Generate SECRET_KEY_BASE if not set
SECRET_KEY_BASE="${SECRET_KEY_BASE:-$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-32)}"

# Set actual values in .env
pct exec $CTID -- bash -c "cd /opt/supabase && sed -i \"s|\\\${POSTGRES_PASSWORD}|$DB_PASSWORD|g\" .env && sed -i \"s|\\\${JWT_SECRET}|$JWT_SECRET|g\" .env && sed -i \"s|\\\${SECRET_KEY_BASE}|$SECRET_KEY_BASE|g\" .env"

# Use Supabase CLI to start services (it handles docker-compose automatically)
msg "Starting Supabase with CLI (this will download and configure everything)..."
pct exec $CTID -- bash -c "cd /opt/supabase && export SUPABASE_DB_PASSWORD='$DB_PASSWORD' && export SUPABASE_JWT_SECRET='$JWT_SECRET' && supabase start --ignore-health-check 2>&1 || true"

# If Supabase CLI didn't work, try using official docker-compose.yml
if ! pct exec $CTID -- test -f /opt/supabase/docker-compose.yml; then
  msg "Downloading official Supabase docker-compose.yml..."
  pct exec $CTID -- bash -c "curl -fsSL https://raw.githubusercontent.com/supabase/supabase/master/docker/docker-compose.yml -o /opt/supabase/docker-compose.yml"
fi

# Create a backup docker-compose.yml if the official one has issues
if ! pct exec $CTID -- test -f /opt/supabase/docker-compose.yml; then
  msg "Creating docker-compose.yml..."
  pct exec $CTID -- bash -c "cat > /opt/supabase/docker-compose.yml <<'COMPOSEEOF'
version: '3.8'

services:
  db:
    container_name: supabase_db_${CTID}
    image: supabase/postgres:latest
    restart: unless-stopped
    ports:
      - '54322:5432'
    environment:
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
      POSTGRES_DB: \${POSTGRES_DB:-postgres}
      POSTGRES_HOST: \${POSTGRES_HOST:-db}
    volumes:
      - ./volumes/db:/var/lib/postgresql/data
    healthcheck:
      test: pg_isready -U postgres
      interval: 5s
      timeout: 5s
      retries: 10

  studio:
    container_name: supabase_studio_${CTID}
    image: supabase/studio:latest
    restart: unless-stopped
    ports:
      - '3000:3000'
    environment:
      SUPABASE_URL: \${API_URL}
      STUDIO_PG_META_URL: http://meta:8080
      DEFAULT_ORGANIZATION_NAME: Default Organization
      DEFAULT_PROJECT_NAME: Default Project
      SUPABASE_ANON_KEY: \${ANON_KEY}
      SUPABASE_SERVICE_KEY: \${SERVICE_ROLE_KEY}
    depends_on:
      - meta

  kong:
    container_name: supabase_kong_${CTID}
    image: kong:latest
    restart: unless-stopped
    ports:
      - '8000:8000/tcp'
      - '8443:8443/tcp'
    environment:
      KONG_DATABASE: \${KONG_DATABASE:-off}
      KONG_DECLARATIVE_CONFIG: \${KONG_DECLARATIVE_CONFIG:-/var/lib/kong/kong.yml}
      KONG_DNS_ORDER: \${KONG_DNS_ORDER:-LAST,A,CNAME}
      KONG_PLUGINS: cors,request-id,key-auth,acl,basic-auth
    volumes:
      - ./volumes/kong:/var/lib/kong
    depends_on:
      - auth
      - rest
      - storage
      - realtime

  auth:
    container_name: supabase_auth_${CTID}
    image: supabase/gotrue:latest
    restart: unless-stopped
    environment:
      GOTRUE_API_HOST: \${GOTRUE_API_HOST:-0.0.0.0}
      GOTRUE_API_PORT: \${GOTRUE_API_PORT:-9999}
      GOTRUE_DB_DRIVER: \${GOTRUE_DB_DRIVER:-postgres}
      GOTRUE_DB_DATABASE_URL: \${GOTRUE_DB_URI}
      GOTRUE_SITE_URL: \${GOTRUE_SITE_URL}
      GOTRUE_URI_ALLOW_LIST: \${GOTRUE_URI_ALLOW_LIST}
      GOTRUE_DISABLE_SIGNUP: \${GOTRUE_DISABLE_SIGNUP:-false}
      GOTRUE_JWT_SECRET: \${JWT_SECRET}
      GOTRUE_JWT_EXP: \${JWT_EXP:-3600}
      GOTRUE_JWT_DEFAULT_GROUP_NAME: \${JWT_DEFAULT_GROUP_NAME:-authenticated}
    depends_on:
      db:
        condition: service_healthy
    healthcheck:
      test: ['CMD', 'wget', '--no-verbose', '--tries=1', '--spider', 'http://localhost:9999/health']
      interval: 5s
      timeout: 5s
      retries: 10

  rest:
    container_name: supabase_rest_${CTID}
    image: postgrest/postgrest:latest
    restart: unless-stopped
    environment:
      PGRST_DB_URI: \${PGRST_DB_URI}
      PGRST_DB_SCHEMAS: \${PGRST_DB_SCHEMAS:-public}
      PGRST_DB_ANON_ROLE: \${PGRST_DB_ANON_ROLE:-anon}
      PGRST_JWT_SECRET: \${JWT_SECRET}
    depends_on:
      db:
        condition: service_healthy
    healthcheck:
      test: ['CMD', 'wget', '--no-verbose', '--tries=1', '--spider', 'http://localhost:3000/health']
      interval: 5s
      timeout: 5s
      retries: 10

  storage:
    container_name: supabase_storage_${CTID}
    image: supabase/storage-api:latest
    restart: unless-stopped
    ports:
      - '5000:5000'
    environment:
      ANON_KEY: \${ANON_KEY}
      SERVICE_KEY: \${SERVICE_ROLE_KEY}
      POSTGREST_URL: http://rest:3000
      PGRST_JWT_SECRET: \${JWT_SECRET}
      DATABASE_URL: \${STORAGE_DB_URI}
      FILE_STORAGE_BACKEND_PATH: \${FILE_STORAGE_BACKEND_PATH:-/var/lib/storage}
      FILE_SIZE_LIMIT: \${STORAGE_FILE_SIZE_LIMIT:-52428800}
      STORAGE_BACKEND: \${STORAGE_BACKEND:-file}
    volumes:
      - ./volumes/storage:/var/lib/storage
    depends_on:
      db:
        condition: service_healthy
      rest:
        condition: service_healthy

  realtime:
    container_name: supabase_realtime_${CTID}
    image: supabase/realtime:latest
    restart: unless-stopped
    environment:
      PORT: 4000
      DB_HOST: \${REALTIME_DB_HOST}
      DB_PORT: \${REALTIME_DB_PORT:-5432}
      DB_USER: \${REALTIME_DB_USER}
      DB_PASSWORD: \${REALTIME_DB_PASSWORD}
      DB_NAME: \${REALTIME_DB_NAME:-postgres}
      DB_URI: \${REALTIME_DB_URI}
      JWT_SECRET: \${JWT_SECRET}
      API_JWT_SECRET: \${JWT_SECRET}
    depends_on:
      db:
        condition: service_healthy

  meta:
    container_name: supabase_meta_${CTID}
    image: supabase/postgres-meta:latest
    restart: unless-stopped
    environment:
      PG_META_PORT: 8080
      PG_META_DB_HOST: \${POSTGRES_HOST}
      PG_META_DB_PORT: \${POSTGRES_PORT:-5432}
      PG_META_DB_NAME: \${POSTGRES_DB}
      PG_META_DB_USER: \${POSTGRES_USER:-postgres}
      PG_META_DB_PASSWORD: \${POSTGRES_PASSWORD}

  functions:
    container_name: supabase_functions_${CTID}
    image: supabase/edge-runtime:latest
    restart: unless-stopped
    ports:
      - '9000:9000'
    environment:
      JWT_SECRET: \${JWT_SECRET}
      SUPABASE_URL: \${API_URL}
      SUPABASE_ANON_KEY: \${ANON_KEY}
      SUPABASE_SERVICE_ROLE_KEY: \${SERVICE_ROLE_KEY}
    volumes:
      - ./volumes/functions:/home/deno/functions
    depends_on:
      db:
        condition: service_healthy

  vector:
    container_name: supabase_vector_${CTID}
    image: supabase/postgres:latest
    restart: unless-stopped
    command: >
      postgres
      -c shared_preload_libraries=vector
      -c max_connections=200
      -c shared_buffers=256MB
      -c effective_cache_size=1GB
      -c maintenance_work_mem=64MB
      -c checkpoint_completion_target=0.9
      -c wal_buffers=16MB
      -c default_statistics_target=100
      -c random_page_cost=1.1
      -c effective_io_concurrency=200
      -c work_mem=4MB
      -c min_wal_size=1GB
      -c max_wal_size=4GB
      -c max_worker_processes=4
      -c max_parallel_workers_per_gather=2
      -c max_parallel_workers=4
      -c max_parallel_maintenance_workers=2
    environment:
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
      POSTGRES_DB: \${POSTGRES_DB}
    volumes:
      - ./volumes/db:/var/lib/postgresql/data
    healthcheck:
      test: pg_isready -U postgres
      interval: 5s
      timeout: 5s
      retries: 10
COMPOSEEOF"

# Create volumes directory for functions
msg "Creating volumes directory..."
pct exec $CTID -- bash -c "mkdir -p /opt/supabase/volumes/functions && chmod -R 755 /opt/supabase/volumes"

# Pull Docker images and start services
msg "Pulling Supabase Docker images (this may take a while)..."
pct exec $CTID -- bash -c "cd /opt/supabase && (docker compose pull 2>/dev/null || docker-compose pull 2>/dev/null || true)"

# Start Supabase services using Supabase CLI (preferred) or docker compose
msg "Starting Supabase services..."
if pct exec $CTID -- command -v supabase &> /dev/null; then
  pct exec $CTID -- bash -c "cd /opt/supabase && export SUPABASE_DB_PASSWORD='$DB_PASSWORD' && supabase start --ignore-health-check 2>&1 || (docker compose up -d 2>/dev/null || docker-compose up -d 2>/dev/null || true)"
else
  pct exec $CTID -- bash -c "cd /opt/supabase && (docker compose up -d 2>/dev/null || docker-compose up -d 2>/dev/null || true)"
fi

msg "Waiting for services to be ready..."
sleep 10

# Check service status
msg "Checking service status..."
pct exec $CTID -- bash -c "cd /opt/supabase && (supabase status 2>/dev/null || docker compose ps 2>/dev/null || docker-compose ps 2>/dev/null || docker ps --format 'table {{.Names}}\t{{.Status}}') 2>/dev/null | head -20 || true"

# Start Proxmox VE Monitor-All if available
if [[ -f /etc/systemd/system/ping-instances.service ]]; then
  systemctl start ping-instances.service
fi

# Save credentials to file
echo "=== Supabase Installation Credentials ===" >>~/$NAME.creds
echo "Container ID: $CTID" >>~/$NAME.creds
echo "Root Password: ${PASS}" >>~/$NAME.creds
echo "Database Password: ${DB_PASSWORD}" >>~/$NAME.creds
echo "JWT Secret: ${JWT_SECRET}" >>~/$NAME.creds
echo "Anon Key: ${ANON_KEY}" >>~/$NAME.creds
echo "Service Role Key: ${SERVICE_ROLE_KEY}" >>~/$NAME.creds
echo "=======================================" >>~/$NAME.creds

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
info "Supabase Services:"
info "  Studio (Dashboard): http://${IP}:3000"
info "  API URL: http://${IP}:8000"
info "  Database: ${IP}:54322"
info "  Storage API: http://${IP}:5000"
info "  Edge Functions: http://${IP}:9000"
echo
info "Login to container:"
info "  login: root"
info "  password: $PASS"
echo
info "Manage Supabase:"
info "  cd /opt/supabase"
info "  docker compose ps       # Check status"
info "  docker compose logs     # View logs"
info "  docker compose restart  # Restart services"
info "  docker compose down     # Stop services"
echo
info "Credentials saved to: ~/$NAME.creds"
echo
warn "Default credentials:"
warn "  Database User: postgres"
warn "  Database Password: Check ~/$NAME.creds"
echo

