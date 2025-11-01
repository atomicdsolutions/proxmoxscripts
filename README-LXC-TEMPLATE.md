# Proxmox LXC Container Creation Template

A standalone template for creating Proxmox LXC containers without dependencies on external scripts.

## Features

- ✅ No external dependencies
- ✅ Configurable via environment variables
- ✅ Reusable for any application
- ✅ Automatic container creation and configuration
- ✅ Network configuration support
- ✅ Template validation

## Quick Start

### Using the Metabase Example

```bash
# Create a new Metabase container
CTID=100 bash metabase-install-standalone.sh

# With network configuration
CTID=100 IP=192.168.1.100/24 GATEWAY=192.168.1.1 bash metabase-install-standalone.sh

# Update existing installation
CTID=100 bash metabase-install-standalone.sh update
```

## Creating Your Own Installation Script

### Template Structure

```bash
#!/usr/bin/env bash
# Your Application Installation Script
set -euo pipefail

# Source the LXC template
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lxc-template.sh"

# Configure your application
APP="YourApp"
CPU_CORES="${CPU_CORES:-2}"
RAM_MB="${RAM_MB:-2048}"
ROOTFS_SIZE="${ROOTFS_SIZE:-10G}"
UNPRIVILEGED="${UNPRIVILEGED:-1}"
TAGS="${TAGS:-your;tags}"

# Define installation function
install_application() {
    msg_info "Installing dependencies..."
    exec_in_ct "apt update && apt install -y package1 package2"
    
    msg_info "Setting up your application..."
    # Your installation steps here
    
    msg_ok "Installation completed!"
}

# Check for CTID
if [[ -z "${CTID:-}" ]]; then
    msg_error "CTID must be specified"
    exit 1
fi

# Template handles the rest
```

## Environment Variables

### Required
- `CTID` - Container ID (must be unique)

### Optional (with defaults)
- `APP` - Application name (default: "Application")
- `STORAGE` - Storage pool (default: "local-lvm")
- `TEMPLATE` - LXC template (default: "debian-12")
- `PASSWORD` - Root password (auto-generated if not set)
- `ROOTFS_SIZE` - Disk size (default: "8G")
- `CPU_CORES` - CPU cores (default: 2)
- `RAM_MB` - RAM in MB (default: 2048)
- `SWAP_MB` - Swap in MB (default: 512)
- `HOSTNAME` - Container hostname (default: "${APP,,}-lxc")
- `IP` - Static IP address (e.g., "192.168.1.100/24")
- `GATEWAY` - Gateway IP (e.g., "192.168.1.1")
- `BRIDGE` - Network bridge (default: "vmbr0")
- `UNPRIVILEGED` - Unprivileged container (default: 1)
- `NESTING` - Enable nesting (default: 0, set to 1 for Docker)
- `TAGS` - Container tags (semicolon-separated)

## Available Functions

### Inside your install_application() function:

- `exec_in_ct "command"` - Execute a command in the container
- `msg_info "message"` - Print info message
- `msg_ok "message"` - Print success message
- `msg_error "message"` - Print error message
- `msg_warning "message"` - Print warning message

## Examples

### Example 1: Simple Application

```bash
#!/usr/bin/env bash
source ./lxc-template.sh

APP="MyApp"
CPU_CORES=1
RAM_MB=1024

install_application() {
    exec_in_ct "apt update && apt install -y nginx"
    msg_ok "Nginx installed!"
}

CTID=200 bash myapp-install.sh
```

### Example 2: Application with Custom Configuration

```bash
#!/usr/bin/env bash
source ./lxc-template.sh

APP="CustomApp"
CPU_CORES=4
RAM_MB=4096
ROOTFS_SIZE="20G"
NESTING=1  # For Docker support

install_application() {
    exec_in_ct "apt update"
    exec_in_ct "apt install -y docker.io"
    # ... more setup
}

CTID=300 bash customapp-install.sh
```

### Example 3: Application with Network Configuration

```bash
CTID=400 \
IP=192.168.10.50/24 \
GATEWAY=192.168.10.1 \
HOSTNAME=myserver \
bash myapp-install.sh
```

## Container Management

After creation, you can manage the container with:

```bash
# Enter container console
pct enter <CTID>

# Execute command in container
pct exec <CTID> -- <command>

# Start/Stop container
pct start <CTID>
pct stop <CTID>

# View container status
pct status <CTID>

# Destroy container
pct destroy <CTID>
```

## Troubleshooting

### Template file not found
- Check available templates: `ls /var/lib/vz/template/cache/`
- Download templates via Proxmox web UI or use existing ones

### Container creation fails
- Check if CTID already exists: `pct list`
- Verify storage pool exists: `pvesm status`
- Check template path is correct

### Network issues
- If IP is not set, container uses DHCP
- Verify bridge exists: `ip link show vmbr0`
- Check gateway is on same network as IP

## Comparison with Community Scripts

| Feature | This Template | Community Scripts |
|---------|--------------|-------------------|
| Dependencies | None | Requires build.func |
| External URLs | None | Downloads from GitHub |
| Customization | Full control | Limited |
| Error handling | Transparent | Can hide errors |
| Portability | Self-contained | Network dependent |

## License

MIT License - Use freely for your projects.

