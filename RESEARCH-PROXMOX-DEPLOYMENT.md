# Research: Proxmox LXC Container Deployment Patterns (Non-Docker)

## Overview

This document summarizes research findings on deploying applications in Proxmox LXC containers natively (without Docker), similar to community-scripts patterns but fully self-contained.

## Key Findings

### 1. Container Architecture Decisions

#### Unprivileged vs Privileged Containers

**Unprivileged Containers (Recommended)**
- **Security**: Root user in container mapped to non-root user on host
- **Isolation**: Better isolation from host system
- **Default**: Proxmox creates unprivileged containers by default
- **Use Case**: Most applications work fine in unprivileged containers
- **Setting**: `--unprivileged 1` in `pct create`

**Privileged Containers**
- **Security**: Container root = host root (less secure)
- **Use Case**: Required for applications needing kernel features, Docker, or specific hardware access
- **Setting**: `--unprivileged 0` in `pct create`
- **Note**: Proxmox recommends running Docker in VMs, not LXC containers

#### Nesting Support
- Required for Docker inside LXC (not recommended)
- Setting: `--features nesting=1`
- Most native applications don't need nesting

### 2. Container Creation Patterns

#### Standard Creation Command Structure

```bash
pct create <CTID> <TEMPLATE> \
  --storage <STORAGE_POOL> \
  --hostname <HOSTNAME> \
  --password '<PASSWORD>' \
  --rootfs-size <SIZE> \
  --cores <CPU_CORES> \
  --memory <RAM_MB> \
  --swap <SWAP_MB> \
  --net0 name=eth0,bridge=<BRIDGE>,ip=<IP>,gw=<GATEWAY> \
  --unprivileged <0|1> \
  --features nesting=<0|1> \
  --tags <TAG1;TAG2>
```

#### Common Patterns

**Pattern 1: DHCP Network**
```bash
--net0 name=eth0,bridge=vmbr0
```

**Pattern 2: Static IP**
```bash
--net0 name=eth0,bridge=vmbr0,ip=192.168.1.100/24,gw=192.168.1.1
```

**Pattern 3: Minimal Resource**
```bash
--cores 1 --memory 512 --swap 256 --rootfs-size 4G
```

**Pattern 4: High Resource**
```bash
--cores 4 --memory 4096 --swap 1024 --rootfs-size 32G
```

### 3. Application Installation Patterns

#### Standard Installation Flow

1. **Container Creation** - Create and start container
2. **Wait for Readiness** - Wait for container to be fully initialized
3. **Update System** - `apt update && apt upgrade`
4. **Install Dependencies** - Install required packages
5. **Download Application** - Download application files/binaries
6. **Create User/Group** - Create dedicated user for application
7. **Configure Directories** - Set up data/config directories
8. **Set Permissions** - Configure proper ownership/permissions
9. **Create Systemd Service** - Create service file for management
10. **Enable & Start** - Enable and start the service
11. **Verify** - Check service status and logs

#### Command Execution Patterns

**Pattern 1: Single Command**
```bash
pct exec <CTID> -- <command>
```

**Pattern 2: Multiple Commands**
```bash
pct exec <CTID> -- bash -c "command1 && command2 && command3"
```

**Pattern 3: Heredoc (Complex Configuration)**
```bash
pct exec <CTID> -- bash -c 'cat > /path/to/file <<EOF
content here
EOF'
```

**Pattern 4: Script Execution**
```bash
pct push <CTID> /local/script.sh /tmp/script.sh
pct exec <CTID> -- bash /tmp/script.sh
```

### 4. Systemd Service Patterns

#### Standard Service Template

```ini
[Unit]
Description=<App Description>
Documentation=<App Documentation URL>
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=<app-user>
Group=<app-group>
WorkingDirectory=/opt/<app>
ExecStart=/usr/bin/<command> <args>
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=<app-name>

# Security hardening
NoNewPrivileges=true
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/opt/<app>/data

# Resource limits
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
```

#### Service Types

**Type=simple** - Most common for applications
- Application runs as main process
- Good for: Java apps, Node.js, Python apps

**Type=forking** - For daemonizing apps
- Application forks and exits
- Good for: Traditional Unix daemons

**Type=oneshot** - One-time tasks
- Executes and exits
- Good for: Setup scripts, migrations

### 5. Security Best Practices

#### Container Security

1. **Use Unprivileged Containers** - Always prefer unprivileged unless necessary
2. **Minimal Permissions** - Run applications as non-root users
3. **Read-Only System** - Use `ProtectSystem=strict` in systemd
4. **Isolated Temp** - Use `PrivateTmp=yes` in systemd
5. **Resource Limits** - Set appropriate limits (CPU, memory, disk)

#### File Permissions

1. **Ownership** - Application files owned by app user, not root
2. **Directory Permissions** - Data directories: 700, config: 644
3. **Executable Permissions** - Binaries: 755, scripts: 750

#### Network Security

1. **Firewall Rules** - Configure firewall in container
2. **Exposed Ports** - Only expose necessary ports
3. **Internal Networks** - Use private networks when possible

### 6. Common Deployment Patterns

#### Pattern 1: Java Applications (like Metabase)

```bash
# Install Java
apt install -y openjdk-17-jre-headless

# Download JAR
wget -O /opt/app/app.jar <URL>

# Create user
useradd -r -s /bin/false -d /opt/app appuser

# Systemd service
# ExecStart=/usr/bin/java -Xmx2g -jar /opt/app/app.jar
```

#### Pattern 2: Web Applications (Node.js/Python)

```bash
# Install runtime
apt install -y nodejs python3

# Download/clone application
git clone <repo> /opt/app

# Install dependencies
cd /opt/app && npm install

# Systemd service
# ExecStart=/usr/bin/node /opt/app/index.js
```

#### Pattern 3: Database Applications

```bash
# Install from repo
apt install -y postgresql mysql-server

# Configure
# Create data directories
# Set permissions

# Systemd uses package's default service
systemctl enable postgresql
```

#### Pattern 4: Go/Compiled Applications

```bash
# Download binary
wget -O /usr/local/bin/app <URL>

# Make executable
chmod +x /usr/local/bin/app

# Systemd service
# ExecStart=/usr/local/bin/app
```

### 7. Automation Patterns

#### Pattern 1: Environment Variables

```bash
APP="Application"
CTID=100
IP="192.168.1.100/24"
GATEWAY="192.168.1.1"
PASSWORD="$(openssl rand -base64 32)"
```

#### Pattern 2: Configuration Validation

```bash
# Validate required variables
if [[ -z "$CTID" ]]; then
    echo "Error: CTID required"
    exit 1
fi

# Check if container exists
if pct status "$CTID" &>/dev/null; then
    echo "Container $CTID already exists"
fi

# Validate template exists
if [[ ! -f "/var/lib/vz/template/cache/$TEMPLATE" ]]; then
    echo "Template not found"
fi
```

#### Pattern 3: Error Handling

```bash
# Use set -e for exit on error
set -e

# Or check return codes
if ! pct create ...; then
    echo "Creation failed"
    exit 1
fi
```

#### Pattern 4: Wait for Container Readiness

```bash
# Wait for container to start
pct start "$CTID"
sleep 3

# Wait for network
for i in {1..30}; do
    if pct exec "$CTID" -- ping -c 1 127.0.0.1 &>/dev/null; then
        break
    fi
    sleep 1
done

# Wait for systemd
for i in {1..30}; do
    if pct exec "$CTID" -- systemctl is-system-running &>/dev/null; then
        break
    fi
    sleep 1
done
```

### 8. Resource Allocation Guidelines

#### Lightweight Applications
- CPU: 1 core
- RAM: 512MB-1GB
- Disk: 4-8GB
- Examples: Static web servers, small APIs

#### Medium Applications
- CPU: 2 cores
- RAM: 2-4GB
- Disk: 8-16GB
- Examples: Metabase, Vault, databases

#### Heavy Applications
- CPU: 4+ cores
- RAM: 4-8GB+
- Disk: 16-32GB+
- Examples: Full stacks, analytics platforms

### 9. Container Lifecycle Management

#### Creation
```bash
pct create <CTID> <TEMPLATE> [options]
```

#### Starting
```bash
pct start <CTID>
```

#### Stopping
```bash
pct stop <CTID>
```

#### Entering (Console)
```bash
pct enter <CTID>
```

#### Executing Commands
```bash
pct exec <CTID> -- <command>
```

#### Destroying
```bash
pct destroy <CTID>
```

#### Backup
```bash
vzdump <CTID> --compress gzip
```

### 10. Common Issues and Solutions

#### Issue: Container won't start
- Check: `pct status <CTID>`
- Check logs: `journalctl -u pve-container@<CTID>`
- Common causes: Template issues, resource limits, network config

#### Issue: Can't install packages
- Check: Network connectivity
- Check: `apt update` works
- Check: Unprivileged container permissions

#### Issue: Service won't start
- Check: `systemctl status <service>`
- Check: Logs with `journalctl -u <service>`
- Check: Permissions on files/directories
- Check: User exists and has proper permissions

#### Issue: Port not accessible
- Check: Service is listening: `ss -tlnp`
- Check: Firewall rules
- Check: Network bridge configuration

### 11. Script Structure Best Practices

#### Recommended Script Structure

1. **Header & Configuration**
   - Shebang, metadata
   - Color codes/helper functions
   - Default configuration variables

2. **Validation**
   - Check required variables
   - Validate environment
   - Check prerequisites

3. **Container Creation**
   - Check if exists
   - Create container
   - Configure networking

4. **Container Initialization**
   - Start container
   - Wait for readiness
   - Get IP address

5. **Application Installation**
   - Install dependencies
   - Download application
   - Configure application

6. **Service Setup**
   - Create systemd service
   - Enable and start service
   - Verify service status

7. **Finalization**
   - Display access information
   - Show management commands
   - Provide next steps

### 12. Comparison: Native vs Docker in LXC

| Aspect | Native Installation | Docker in LXC |
|--------|-------------------|---------------|
| Performance | Better (no Docker overhead) | Slight overhead |
| Security | Good with unprivileged | More complex |
| Resource Usage | Lower | Higher |
| Management | systemd | Docker commands |
| Complexity | Lower | Higher |
| Proxmox Recommendation | ✅ Recommended | ❌ Use VMs instead |
| Isolation | Container-level | Container + Docker |
| Updates | Package manager | Container updates |

### 13. Key Takeaways

1. **Prefer Unprivileged Containers** - Better security by default
2. **Use Native Installation** - Better performance, simpler management
3. **Systemd for Services** - Standard Linux service management
4. **Proper User Isolation** - Run apps as non-root users
5. **Resource Planning** - Allocate resources based on app requirements
6. **Automation** - Script everything for repeatability
7. **Error Handling** - Validate and handle errors gracefully
8. **Documentation** - Document configuration and management

## Conclusion

Native deployment in Proxmox LXC containers provides:
- Better performance than Docker-in-LXC
- Simpler management with systemd
- Better security with unprivileged containers
- Full control over the environment
- No dependency on external scripts

The patterns and practices outlined above provide a solid foundation for creating reliable, maintainable container deployment scripts.

