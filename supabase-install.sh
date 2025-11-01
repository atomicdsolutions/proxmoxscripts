#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)
# Copyright (c) 2021-2025 community-scripts
# Author: Your Name
# License: MIT
# Source: https://supabase.com/

APP="Supabase"
var_tags="${var_tags:-database;backend;postgresql}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-32}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-0}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
    header_info
    check_container_storage
    check_container_resources
    if [[ ! -d /opt/supabase ]]; then
        msg_error "No ${APP} Installation Found!"
        exit
    fi
    msg_info "Updating ${APP} LXC"
    $STD apt update
    $STD apt -y upgrade
    
    msg_info "Updating Docker containers"
    cd /opt/supabase
    $STD docker compose pull
    $STD docker compose up -d
    msg_ok "Updated ${APP} services"
    exit
}

start
build_container
description

msg_info "Installing dependencies"
$STD apt update
$STD apt install -y curl git ca-certificates gnupg lsb-release

msg_info "Installing Docker"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | $STD gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
  $(lsb_release -cs) stable" | $STD tee /etc/apt/sources.list.d/docker.list > /dev/null

$STD apt update
$STD apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

msg_info "Starting Docker service"
$STD systemctl enable docker
$STD systemctl start docker

msg_info "Creating Supabase directory"
$STD mkdir -p /opt/supabase
cd /opt/supabase

msg_info "Cloning Supabase repository"
SUPABASE_TEMP="/tmp/supabase-repo"
if [[ -d ${SUPABASE_TEMP} ]]; then
    rm -rf ${SUPABASE_TEMP}
fi
$STD git clone --depth 1 https://github.com/supabase/supabase.git ${SUPABASE_TEMP}

msg_info "Copying Supabase Docker files to /opt/supabase"
$STD cp -rf ${SUPABASE_TEMP}/docker/* /opt/supabase/
if [[ -f ${SUPABASE_TEMP}/docker/.env.example ]]; then
    $STD cp ${SUPABASE_TEMP}/docker/.env.example /opt/supabase/.env.example
fi

# Cleanup temp directory
rm -rf ${SUPABASE_TEMP}

msg_info "Configuring Supabase environment"
cd /opt/supabase

# Generate secure passwords if .env doesn't exist
if [[ ! -f .env ]]; then
    msg_info "Generating secure passwords for Supabase"
    
    # Generate random passwords
    POSTGRES_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
    JWT_SECRET=$(openssl rand -base64 64 | tr -d "=+/" | cut -c1-64)
    
    # Create .env from example if it exists, otherwise create minimal one
    if [[ -f .env.example ]]; then
        $STD cp .env.example .env
        # Update password fields
        sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=${POSTGRES_PASSWORD}/" .env
        sed -i "s/^JWT_SECRET=.*/JWT_SECRET=${JWT_SECRET}/" .env
    else
        # Create minimal .env file
        cat > .env <<EOF
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
JWT_SECRET=${JWT_SECRET}
POSTGRES_HOST=db
POSTGRES_DB=postgres
POSTGRES_PORT=5432
POSTGRES_USER=postgres
EOF
    fi
    
    msg_ok "Generated secure credentials"
fi

# Ensure API and Studio URLs are accessible from host
msg_info "Configuring network settings"
# Note: Supabase services communicate internally, but Studio and API need to be accessible
# The docker-compose.yml should handle port mapping, but we ensure env vars are set
if ! grep -q "API_URL" .env 2>/dev/null; then
    echo "API_URL=http://${IP}:8000" >> .env
fi
if ! grep -q "STUDIO_URL" .env 2>/dev/null; then
    echo "STUDIO_URL=http://${IP}:3000" >> .env
fi

msg_info "Pulling Docker images (this may take a while)"
$STD docker compose pull

msg_info "Starting Supabase services"
$STD docker compose up -d

msg_info "Waiting for services to initialize (this may take 30-60 seconds)"
for i in {1..24}; do
    if docker compose ps 2>/dev/null | grep -q "Up"; then
        # Check if database is ready
        if docker compose exec -T db pg_isready -U postgres >/dev/null 2>&1; then
            break
        fi
    fi
    sleep 5
    echo -n "."
done
echo ""

msg_info "Checking service status"
UP_SERVICES=$(docker compose ps 2>/dev/null | grep -c "Up" || echo "0")
if [[ $UP_SERVICES -gt 0 ]]; then
    msg_ok "Supabase services are running ($UP_SERVICES services up)"
    
    # Wait a bit more for database to be fully ready
    msg_info "Waiting for database to be fully ready"
    sleep 5
    
    # Enable pgvector extension for vector database support
    msg_info "Enabling pgvector extension for vector database support"
    if docker compose exec -T db psql -U postgres -c "CREATE EXTENSION IF NOT EXISTS vector;" 2>/dev/null; then
        msg_ok "pgvector extension enabled"
    else
        msg_warning "Could not enable pgvector immediately. Database may still be initializing."
        msg_info "You can enable it later with: docker compose exec db psql -U postgres -c 'CREATE EXTENSION IF NOT EXISTS vector;'"
    fi
else
    msg_warning "Services may still be starting. Check status with: cd /opt/supabase && docker compose ps"
fi

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo ""
echo -e "${INFO}${YW} Included Services:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}✓ Authentication (GoTrue)${CL} - User sign-up, sign-in, OAuth, JWT tokens"
echo -e "${TAB}${GATEWAY}${BGN}✓ Database (PostgreSQL)${CL} - Full PostgreSQL with extensions"
echo -e "${TAB}${GATEWAY}${BGN}✓ Vector Database (pgvector)${CL} - Vector similarity search for AI/ML"
echo -e "${TAB}${GATEWAY}${BGN}✓ Storage${CL} - S3-compatible object storage with policies"
echo -e "${TAB}${GATEWAY}${BGN}✓ Realtime${CL} - Real-time subscriptions and updates"
echo -e "${TAB}${GATEWAY}${BGN}✓ REST API (PostgREST)${CL} - Auto-generated REST APIs"
echo -e "${TAB}${GATEWAY}${BGN}✓ API Gateway (Kong)${CL} - Routing and API management"
echo -e "${TAB}${GATEWAY}${BGN}✓ Studio (Web UI)${CL} - Admin dashboard and management"
echo -e "${TAB}${GATEWAY}${BGN}✓ Edge Functions${CL} - Serverless functions (Deno runtime)"
echo ""
echo -e "${INFO}${YW} Access Points:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}Supabase Studio (Web UI):${CL} ${GN}http://${IP}:3000${CL}"
echo -e "${TAB}${GATEWAY}${BGN}API Endpoint (Kong Gateway):${CL} ${GN}http://${IP}:8000${CL}"
echo -e "${TAB}${GATEWAY}${BGN}PostgreSQL Database:${CL} ${GN}${IP}:5432${CL}"
echo -e "${TAB}${GATEWAY}${BGN}Storage API:${CL} ${GN}http://${IP}:8000/storage/v1${CL}"
echo ""
echo -e "${INFO}${YW} Management Commands:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}View services:${CL} cd /opt/supabase && docker compose ps"
echo -e "${TAB}${GATEWAY}${BGN}View logs:${CL} cd /opt/supabase && docker compose logs -f [service-name]"
echo -e "${TAB}${GATEWAY}${BGN}Restart services:${CL} cd /opt/supabase && docker compose restart"
echo -e "${TAB}${GATEWAY}${BGN}Stop services:${CL} cd /opt/supabase && docker compose down"
echo -e "${TAB}${GATEWAY}${BGN}Enable extensions:${CL} docker compose exec db psql -U postgres -c 'CREATE EXTENSION vector;'"
echo ""
echo -e "${INFO}${YW} Configuration:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}Environment file:${CL} /opt/supabase/.env"
echo -e "${TAB}${GATEWAY}${BGN}Docker compose file:${CL} /opt/supabase/docker-compose.yml"
echo ""
echo -e "${WARN}${YW} Security Notes:${CL}"
echo -e "${TAB}${YW}• Credentials and secrets are stored in /opt/supabase/.env${CL}"
echo -e "${TAB}${YW}• Secure this file with appropriate permissions${CL}"
echo -e "${TAB}${YW}• Container is set to privileged mode (required for Docker)${CL}"
echo -e "${TAB}${YW}• Ensure firewall rules are configured for ports 3000, 8000, 5432${CL}"
echo ""
echo -e "${INFO}${YW} Next Steps:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}1.${CL} Access Studio at http://${IP}:3000 to complete initial setup"
echo -e "${TAB}${GATEWAY}${BGN}2.${CL} Configure your project name and settings"
echo -e "${TAB}${GATEWAY}${BGN}3.${CL} Get API keys from Studio Settings > API"
echo -e "${TAB}${GATEWAY}${BGN}4.${CL} Start building with Authentication, Database, Storage, and Realtime!"
echo -e "${TAB}${GATEWAY}${BGN}5.${CL} For Edge Functions, deploy using Supabase CLI: supabase functions deploy"

