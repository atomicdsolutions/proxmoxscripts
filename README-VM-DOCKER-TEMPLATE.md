# Proxmox VM Template for Docker Applications

A standalone template for creating Proxmox VMs optimized for Docker deployments. This follows Proxmox's recommendation to run Docker in VMs rather than LXC containers.

## Why VMs for Docker?

- ✅ **Better Isolation** - Full virtualization provides stronger isolation
- ✅ **Kernel Compatibility** - VMs have their own kernel, avoiding LXC limitations
- ✅ **Official Recommendation** - Proxmox recommends Docker in VMs
- ✅ **Easier Management** - Standard Docker operations work without special configuration
- ✅ **Live Migration** - VMs support live migration features

## Quick Start

### Using the Supabase Example

```bash
# Create a Supabase VM
VMID=200 bash supabase-install-vm.sh

# With network configuration
VMID=200 IP=192.168.1.200/24 GATEWAY=192.168.1.1 bash supabase-install-vm.sh
```

### Using the Template Directly

```bash
#!/usr/bin/env bash
source ./vm-docker-template.sh

APP="MyDockerApp"
VMID=300
CPU_CORES=4
RAM_MB=4096
DISK_SIZE="32G"

install_application() {
    exec_in_vm "apt update && apt install -y docker.io"
    # Your Docker setup here
}

# Template handles VM creation
```

## Prerequisites

### Cloud Images

For automated setup with Cloud-Init, you need a cloud-compatible image:

**Debian:**
```bash
# Download Debian 12 cloud image
wget https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2

# Import to Proxmox
qm disk import 100 debian-12-genericcloud-amd64.qcow2 local-lvm
```

**Ubuntu:**
```bash
# Download Ubuntu 22.04 cloud image
wget https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64.img

# Import to Proxmox
qm disk import 100 ubuntu-22.04-server-cloudimg-amd64.img local-lvm
```

### Cloud Image Storage

Recommended location: `/var/lib/vz/template/qemu/`

```bash
mkdir -p /var/lib/vz/template/qemu
cd /var/lib/vz/template/qemu
# Download images here
```

## Environment Variables

### Required
- `VMID` - VM ID (must be unique, typically 100+)

### VM Configuration
- `APP` - Application name (default: "Application")
- `STORAGE` - Storage pool (default: "local-lvm")
- `ISO_STORAGE` - ISO storage pool (default: "local")
- `TEMPLATE` - Template/ISO name (default: "debian-12-genericcloud-amd64")
- `DISK_SIZE` - Disk size (default: "32G")
- `CPU_CORES` - CPU cores (default: 2)
- `RAM_MB` - RAM in MB (default: 4096)
- `HOSTNAME` - VM hostname (default: "${APP,,}-vm")

### Network Configuration
- `IP` - Static IP address (e.g., "192.168.1.100/24")
- `NETMASK` - Network mask (default: "24")
- `GATEWAY` - Gateway IP (e.g., "192.168.1.1")
- `BRIDGE` - Network bridge (default: "vmbr0")
- `DNS` - DNS server (default: "8.8.8.8")

### Security
- `PASSWORD` - Root password (auto-generated if not set)
- `SSH_KEY` - SSH public key file path

### Advanced
- `OS_TYPE` - OS type (default: "l26" for Linux)
- `BIOS` - BIOS type (default: "seabios")
- `MACHINE` - Machine type (default: "q35")
- `SCSI_CONTROLLER` - SCSI controller (default: "virtio-scsi-pci")
- `CLOUD_INIT` - Enable Cloud-Init (default: 1)
- `TAGS` - VM tags (semicolon-separated)

## VM vs LXC Comparison

| Feature | VM (Docker) | LXC (Native) |
|---------|-------------|--------------|
| **Docker Support** | ✅ Full support | ⚠️ Requires privileged + nesting |
| **Isolation** | ✅ Strong (full virtualization) | ⚠️ Moderate (shared kernel) |
| **Resource Overhead** | Higher | Lower |
| **Boot Time** | Slower | Faster |
| **Memory Usage** | Higher | Lower |
| **Use Case** | Docker applications | Native applications |
| **Proxmox Recommendation** | ✅ Recommended | ❌ Not recommended |

## Common Patterns

### Pattern 1: Basic Docker VM

```bash
VMID=100 \
IP=192.168.1.100/24 \
GATEWAY=192.168.1.1 \
CPU_CORES=2 \
RAM_MB=2048 \
DISK_SIZE="20G" \
bash vm-docker-template.sh
```

### Pattern 2: High-Performance Docker VM

```bash
VMID=200 \
IP=192.168.1.200/24 \
GATEWAY=192.168.1.1 \
CPU_CORES=8 \
RAM_MB=16384 \
DISK_SIZE="100G" \
bash vm-docker-template.sh
```

### Pattern 3: Cloud-Init with SSH Key

```bash
VMID=300 \
IP=192.168.1.300/24 \
GATEWAY=192.168.1.1 \
SSH_KEY=~/.ssh/id_rsa.pub \
bash vm-docker-template.sh
```

## Installation Flow

1. **VM Creation** - Create VM with specified resources
2. **Disk Setup** - Create and attach disk
3. **Cloud-Init Configuration** - Configure networking, SSH, password
4. **VM Start** - Start the VM
5. **IP Detection** - Wait for VM to boot and get IP
6. **SSH Connection** - Connect via SSH
7. **Application Installation** - Install Docker and application
8. **Service Setup** - Configure and start services

## Docker Installation Patterns

### Pattern 1: Official Docker Repository

```bash
exec_in_vm "apt update && apt install -y ca-certificates curl gnupg lsb-release"
exec_in_vm 'install -m 0755 -d /etc/apt/keyrings && curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg'
exec_in_vm 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null'
exec_in_vm "apt update && apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
```

### Pattern 2: Docker from Debian Repo

```bash
exec_in_vm "apt update && apt install -y docker.io docker-compose"
```

### Pattern 3: Docker Script Installation

```bash
exec_in_vm "curl -fsSL https://get.docker.com | sh"
```

## Example: Creating a Docker-Ready VM Script

```bash
#!/usr/bin/env bash
source ./vm-docker-template.sh

APP="MyDockerApp"
VMID=400
CPU_CORES=4
RAM_MB=4096
DISK_SIZE="32G"
TAGS="docker;app"

install_application() {
    msg_info "Installing Docker..."
    exec_in_vm "apt update && apt install -y docker.io docker-compose"
    
    msg_info "Installing application..."
    exec_in_vm "docker pull myapp:latest"
    
    msg_info "Starting application..."
    exec_in_vm "docker run -d --name myapp -p 8080:8080 myapp:latest"
    
    msg_ok "Application installed and running!"
    msg_info "Access at: http://${IP}:8080"
}
```

## Cloud-Init Configuration

The template automatically configures Cloud-Init for:

- **User Setup** - Root user with password
- **SSH Keys** - Public key authentication
- **Network** - Static IP or DHCP
- **Hostname** - VM hostname
- **DNS** - DNS server configuration

### Manual Cloud-Init Configuration

```bash
qm set <VMID> --ciuser root
qm set <VMID> --cipassword "password"
qm set <VMID> --sshkeys ~/.ssh/id_rsa.pub
qm set <VMID> --ipconfig0 ip=192.168.1.100/24,gw=192.168.1.1
qm set <VMID> --nameserver 8.8.8.8
qm set <VMID> --hostname my-vm
```

## VM Management Commands

### Basic Operations

```bash
# Start VM
qm start <VMID>

# Stop VM
qm stop <VMID>

# Shutdown gracefully
qm shutdown <VMID>

# Reset VM
qm reset <VMID>

# Status
qm status <VMID>
```

### Console Access

```bash
# Serial console
qm terminal <VMID>

# VNC console (via web UI)
# Or use: qm monitor <VMID>
```

### Disk Operations

```bash
# Resize disk
qm disk resize <VMID> scsi0 +10G

# Add disk
qm set <VMID> --scsi1 <STORAGE>:<SIZE>

# List disks
qm config <VMID> | grep -i scsi
```

### Network Operations

```bash
# Get network interfaces
qm guest cmd <VMID> network-get-interfaces

# Get IP address
qm guest cmd <VMID> network-get-interfaces | grep ip-address
```

## Troubleshooting

### VM Won't Start

```bash
# Check status
qm status <VMID>

# Check logs
journalctl -u qemu-server@<VMID>

# Check configuration
qm config <VMID>
```

### Cloud-Init Not Working

- Verify cloud image is Cloud-Init compatible
- Check Cloud-Init config: `qm config <VMID> | grep -i ci`
- Verify network configuration
- Check Cloud-Init logs in VM

### SSH Connection Issues

- Verify IP address is correct
- Check firewall rules
- Verify SSH service is running in VM
- Check Cloud-Init completed successfully

### Docker Installation Issues

- Ensure VM has internet access
- Verify package repositories are accessible
- Check disk space: `df -h`
- Review installation logs

## Best Practices

1. **Use Cloud Images** - Use official cloud images for automated setup
2. **SSH Keys** - Prefer SSH keys over passwords
3. **Static IPs** - Use static IPs for production deployments
4. **Resource Planning** - Allocate adequate resources for Docker
5. **Backup Strategy** - Regularly backup VM images
6. **Monitoring** - Monitor VM resource usage
7. **Security** - Keep VM OS and Docker updated
8. **Documentation** - Document your VM configurations

## Integration with Inventory Script

The VM template works with the inventory script:

```bash
# Create VM
VMID=100 bash myapp-install-vm.sh

# Update inventory
./lxc-inventory.sh update
```

Note: The inventory script currently focuses on LXC containers. VM support could be added in the future.

## Resources

- [Proxmox VM Management](https://pve.proxmox.com/wiki/Qemu/KVM_Virtual_Machines)
- [Cloud-Init Documentation](https://cloudinit.readthedocs.io/)
- [Docker Installation Guide](https://docs.docker.com/engine/install/)
- [Proxmox Cloud Images](https://pve.proxmox.com/wiki/Cloud-Init_Support)

## License

MIT License - Use freely for your projects.


