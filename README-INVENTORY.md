# LXC Container Inventory Script

Automatically tracks all LXC containers on your Proxmox host, including their IP addresses, status, and configuration.

## Features

- ✅ Scans all LXC containers automatically
- ✅ Extracts IP addresses (from config or running containers)
- ✅ Stores data in JSON and CSV formats
- ✅ Tracks container status, resources, and configuration
- ✅ Search functionality by IP, hostname, or CTID
- ✅ Activity logging
- ✅ Human-readable display

## Quick Start

### Basic Usage

```bash
# Update inventory (scan all containers)
./lxc-inventory.sh update

# Display current inventory
./lxc-inventory.sh show

# Find a specific container
./lxc-inventory.sh find 192.168.1.100
./lxc-inventory.sh find metabase
./lxc-inventory.sh find 100
```

### Installation on PVE Host

```bash
# Copy to Proxmox host
scp lxc-inventory.sh root@pve-host:/usr/local/bin/

# Make executable
ssh root@pve-host "chmod +x /usr/local/bin/lxc-inventory.sh"

# Create inventory directory
ssh root@pve-host "mkdir -p /root/lxc-inventory"
```

## Commands

### `update` (default)
Generate or update the inventory by scanning all containers.

```bash
lxc-inventory.sh update
```

### `show`
Display the current inventory in a formatted table.

```bash
lxc-inventory.sh show
```

Output example:
```
Generated: 2025-01-15T10:30:00Z
Total: 5 containers
Running: 4 | Stopped: 1

CTID   Hostname                       IP Address         Status     Memory     Cores  
--------------------------------------------------------------------------------------------
100    metabase-lxc                   192.168.1.100      running    2048       2      
101    vault-lxc                      192.168.1.101      running    2048       2      
102    supabase-lxc                   192.168.1.102      running    4096       4      
103    web-server                     192.168.1.103      running    1024       1      
104    test-container                 192.168.1.104      stopped    512        1      
```

### `find <term>`
Search for containers by IP address, hostname, or CTID.

```bash
# Find by IP
lxc-inventory.sh find 192.168.1.100

# Find by hostname (partial match)
lxc-inventory.sh find metabase

# Find by CTID
lxc-inventory.sh find 100
```

## Output Files

All files are stored in `/root/lxc-inventory/` by default.

### `inventory.json`
Machine-readable JSON format with full container details.

```json
{
  "generated_at": "2025-01-15T10:30:00Z",
  "generated_by": "root@pve",
  "total_containers": 5,
  "containers": [
    {
      "ctid": 100,
      "hostname": "metabase-lxc",
      "ip_address": "192.168.1.100",
      "status": "running",
      "memory_mb": "2048",
      "cpu_cores": "2",
      "storage": "local-lvm",
      "tags": "analytics;business-intelligence",
      "unprivileged": "1",
      "last_updated": "2025-01-15T10:30:00Z"
    }
  ],
  "summary": {
    "running": 4,
    "stopped": 1
  }
}
```

### `inventory.csv`
Human-readable CSV format for spreadsheets or quick viewing.

```csv
CTID,Hostname,IP Address,Status,Memory (MB),CPU Cores,Storage,Tags,Unprivileged,Last Updated
100,metabase-lxc,192.168.1.100,running,2048,2,local-lvm,analytics;business-intelligence,1,2025-01-15 10:30:00
```

### `inventory.log`
Activity log with timestamps.

```
[2025-01-15 10:30:00] Starting inventory scan
[2025-01-15 10:30:05] Inventory scan completed: 4 running, 1 stopped
```

## Configuration

Set environment variables to customize:

```bash
# Custom inventory directory
INVENTORY_DIR=/opt/inventory ./lxc-inventory.sh update

# Custom file names
INVENTORY_FILE=/path/to/inventory.json \
INVENTORY_CSV=/path/to/inventory.csv \
./lxc-inventory.sh update
```

## Automation

### Cron Job (Auto-Update)

Add to crontab to auto-update inventory:

```bash
# Edit crontab
crontab -e

# Update inventory every hour
0 * * * * /usr/local/bin/lxc-inventory.sh update >/dev/null 2>&1

# Or every 30 minutes
*/30 * * * * /usr/local/bin/lxc-inventory.sh update >/dev/null 2>&1

# Or daily at 2 AM
0 2 * * * /usr/local/bin/lxc-inventory.sh update >/dev/null 2>&1
```

### Systemd Timer (Alternative)

Create a systemd timer for more control:

```bash
# Create service file
cat > /etc/systemd/system/lxc-inventory.service <<EOF
[Unit]
Description=Update LXC Container Inventory
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/lxc-inventory.sh update
EOF

# Create timer file
cat > /etc/systemd/system/lxc-inventory.timer <<EOF
[Unit]
Description=Update LXC Container Inventory Timer
Requires=lxc-inventory.service

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Enable and start timer
systemctl daemon-reload
systemctl enable lxc-inventory.timer
systemctl start lxc-inventory.timer
```

## Integration Examples

### Get IP by Hostname

```bash
./lxc-inventory.sh find metabase | grep "IP Address" | awk '{print $3}'
```

### List All Running Containers

```bash
./lxc-inventory.sh show | grep running
```

### Export to Script Variable

```bash
# Get IP address as variable
IP=$(./lxc-inventory.sh find metabase | grep "IP Address" | awk '{print $3}')
echo "Metabase is at: http://$IP:3000"
```

### Generate Hosts File

```bash
# Generate /etc/hosts entries from inventory
./lxc-inventory.sh show | awk '/running/ {print $3, $2}' >> /etc/hosts
```

## Troubleshooting

### No containers found
- Verify containers exist: `pct list`
- Check you're running on Proxmox host
- Verify `pct` command is available

### IP addresses missing
- Container might not be running
- Network configuration might not be set
- Check container config: `pct config <CTID>`

### Permission errors
- Ensure script is executable: `chmod +x lxc-inventory.sh`
- Check directory permissions: `ls -ld /root/lxc-inventory`
- Run as root or user with `pct` access

## Use Cases

1. **Infrastructure Documentation** - Keep track of all containers
2. **Network Management** - Quick IP lookup
3. **Monitoring** - Track container status changes
4. **Backup Planning** - Know which containers to backup
5. **Security Audits** - Inventory all running services
6. **Capacity Planning** - View resource allocation

## Advanced Usage

### Combine with Other Scripts

```bash
# Update inventory before running installation
./lxc-inventory.sh update && ./metabase-install-standalone.sh
```

### API Integration

Parse JSON output for API/automation:

```bash
# Get all container IPs
cat /root/lxc-inventory/inventory.json | python3 -c "import json,sys; [print(c['ip_address']) for c in json.load(sys.stdin)['containers'] if c['status']=='running']"
```

### Monitoring Script

```bash
#!/bin/bash
# Check if any containers changed status
./lxc-inventory.sh update
PREV_RUNNING=$(./lxc-inventory.sh show | grep "Running:" | awk '{print $2}')
echo "Currently running: $PREV_RUNNING containers"
```

