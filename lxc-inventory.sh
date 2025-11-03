#!/usr/bin/env bash
# Proxmox LXC Container Inventory Script
# Tracks all LXC containers and their IP addresses locally
# Copyright (c) 2025
# License: MIT

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
INVENTORY_DIR="${INVENTORY_DIR:-/root/lxc-inventory}"
INVENTORY_FILE="${INVENTORY_FILE:-$INVENTORY_DIR/inventory.json}"
INVENTORY_CSV="${INVENTORY_CSV:-$INVENTORY_DIR/inventory.csv}"
INVENTORY_LOG="${INVENTORY_LOG:-$INVENTORY_DIR/inventory.log}"

# Helper functions
msg_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

msg_ok() {
    echo -e "${GREEN}[OK]${NC} $1"
}

msg_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

msg_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Create inventory directory if it doesn't exist
mkdir -p "$INVENTORY_DIR"

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$INVENTORY_LOG"
}

# Get container information
get_container_info() {
    local ctid=$1
    local info=()
    
    # Get basic info from pct config
    local config=$(pct config "$ctid" 2>/dev/null || echo "")
    if [[ -z "$config" ]]; then
        return 1
    fi
    
    # Extract hostname
    local hostname=$(echo "$config" | grep "^hostname:" | cut -d' ' -f2 | tr -d '"' || echo "unknown")
    
    # Extract IP from network config
    local ip=$(echo "$config" | grep -E "^net[0-9]+:" | grep -oP 'ip=\K[^,/\s]+' | head -1 || echo "")
    
    # If no IP in config, try to get it from running container
    if [[ -z "$ip" ]]; then
        if pct status "$ctid" | grep -q "running"; then
            ip=$(pct exec "$ctid" -- ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || echo "")
        fi
    fi
    
    # Get status
    local status=$(pct status "$ctid" 2>/dev/null | awk '{print $2}' || echo "unknown")
    
    # Get memory
    local memory=$(echo "$config" | grep "^memory:" | cut -d' ' -f2 || echo "unknown")
    
    # Get cores
    local cores=$(echo "$config" | grep "^cores:" | cut -d' ' -f2 || echo "unknown")
    
    # Get storage
    local storage=$(echo "$config" | grep "^rootfs:" | cut -d' ' -f2 | cut -d',' -f1 || echo "unknown")
    
    # Get tags
    local tags=$(echo "$config" | grep "^tags:" | cut -d' ' -f2- | tr -d '"' || echo "")
    
    # Get unprivileged status
    local unprivileged=$(echo "$config" | grep "^unprivileged:" | cut -d' ' -f2 || echo "1")
    
    info=("$ctid" "$hostname" "$ip" "$status" "$memory" "$cores" "$storage" "$tags" "$unprivileged")
    echo "${info[@]}"
}

# Generate inventory
generate_inventory() {
    msg_info "Scanning Proxmox LXC containers..."
    log "Starting inventory scan"
    
    # Get all container IDs
    local container_ids=$(pct list | tail -n +2 | awk '{print $1}')
    
    if [[ -z "$container_ids" ]]; then
        msg_warning "No LXC containers found"
        log "No containers found"
        return 1
    fi
    
    # Initialize JSON structure
    local json_output="{"
    json_output+="\"generated_at\":\"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\","
    json_output+="\"generated_by\":\"$(whoami)@$(hostname)\","
    json_output+="\"total_containers\":$(echo "$container_ids" | wc -l),"
    json_output+="\"containers\":["
    
    # Initialize CSV
    echo "CTID,Hostname,IP Address,Status,Memory (MB),CPU Cores,Storage,Tags,Unprivileged,Last Updated" > "$INVENTORY_CSV"
    
    local first=true
    local running_count=0
    local stopped_count=0
    
    while IFS= read -r ctid; do
        if [[ -z "$ctid" ]]; then
            continue
        fi
        
        msg_info "Scanning container $ctid..."
        local info=($(get_container_info "$ctid"))
        
        if [[ ${#info[@]} -eq 0 ]]; then
            msg_warning "Could not get info for container $ctid"
            continue
        fi
        
        local ctid_val="${info[0]}"
        local hostname="${info[1]}"
        local ip="${info[2]}"
        local status="${info[3]}"
        local memory="${info[4]}"
        local cores="${info[5]}"
        local storage="${info[6]}"
        local tags="${info[7]}"
        local unprivileged="${info[8]}"
        
        # Count status
        if [[ "$status" == "running" ]]; then
            ((running_count++))
        else
            ((stopped_count++))
        fi
        
        # Add comma separator for JSON
        if [[ "$first" == true ]]; then
            first=false
        else
            json_output+=","
        fi
        
        # Add to JSON
        json_output+="{"
        json_output+="\"ctid\":$ctid_val,"
        json_output+="\"hostname\":\"$hostname\","
        json_output+="\"ip_address\":\"$ip\","
        json_output+="\"status\":\"$status\","
        json_output+="\"memory_mb\":\"$memory\","
        json_output+="\"cpu_cores\":\"$cores\","
        json_output+="\"storage\":\"$storage\","
        json_output+="\"tags\":\"$tags\","
        json_output+="\"unprivileged\":\"$unprivileged\","
        json_output+="\"last_updated\":\"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\""
        json_output+="}"
        
        # Add to CSV
        echo "$ctid_val,$hostname,$ip,$status,$memory,$cores,$storage,$tags,$unprivileged,$(date -u +"%Y-%m-%d %H:%M:%S")" >> "$INVENTORY_CSV"
        
        # Display
        printf "  ${CYAN}%4s${NC} | ${GREEN}%-30s${NC} | ${YELLOW}%-15s${NC} | %s\n" "$ctid_val" "$hostname" "$ip" "$status"
        
    done <<< "$container_ids"
    
    json_output+="],"
    json_output+="\"summary\":{"
    json_output+="\"running\":$running_count,"
    json_output+="\"stopped\":$stopped_count"
    json_output+="}"
    json_output+="}"
    
    # Write JSON file
    echo "$json_output" | python3 -m json.tool 2>/dev/null > "$INVENTORY_FILE" || echo "$json_output" > "$INVENTORY_FILE"
    
    log "Inventory scan completed: $running_count running, $stopped_count stopped"
    
    msg_ok "Inventory generated successfully"
    echo ""
    msg_info "Summary:"
    echo "  Total containers: $(echo "$container_ids" | wc -l)"
    echo "  Running: $running_count"
    echo "  Stopped: $stopped_count"
    echo ""
    msg_info "Files saved:"
    echo "  JSON: $INVENTORY_FILE"
    echo "  CSV:  $INVENTORY_CSV"
    echo "  Log:  $INVENTORY_LOG"
}

# Display inventory
display_inventory() {
    if [[ ! -f "$INVENTORY_FILE" ]]; then
        msg_error "Inventory file not found. Run with 'update' first."
        exit 1
    fi
    
    msg_info "Current LXC Container Inventory"
    echo "=========================================="
    
    if command -v python3 &>/dev/null && python3 -c "import json" 2>/dev/null; then
        python3 <<PYTHON
import json
import sys
from datetime import datetime

try:
    with open('$INVENTORY_FILE', 'r') as f:
        data = json.load(f)
    
    print(f"Generated: {data.get('generated_at', 'unknown')}")
    print(f"Total: {data.get('total_containers', 0)} containers")
    print(f"Running: {data.get('summary', {}).get('running', 0)} | Stopped: {data.get('summary', {}).get('stopped', 0)}")
    print()
    print(f"{'CTID':<6} {'Hostname':<30} {'IP Address':<18} {'Status':<10} {'Memory':<10} {'Cores':<6}")
    print("-" * 90)
    
    for container in data.get('containers', []):
        ctid = container.get('ctid', 'N/A')
        hostname = container.get('hostname', 'unknown')[:28]
        ip = container.get('ip_address', 'N/A')[:16]
        status = container.get('status', 'unknown')
        memory = container.get('memory_mb', 'N/A')
        cores = container.get('cpu_cores', 'N/A')
        print(f"{ctid:<6} {hostname:<30} {ip:<18} {status:<10} {memory:<10} {cores:<6}")
except Exception as e:
    print(f"Error reading inventory: {e}", file=sys.stderr)
    sys.exit(1)
PYTHON
    else
        # Fallback to CSV display
        if [[ -f "$INVENTORY_CSV" ]]; then
            column -t -s',' "$INVENTORY_CSV" 2>/dev/null || cat "$INVENTORY_CSV"
        else
            msg_error "Cannot display inventory - JSON parser and CSV not available"
            exit 1
        fi
    fi
}

# Find container by IP or hostname
find_container() {
    local search_term=$1
    
    if [[ -z "$search_term" ]]; then
        msg_error "Please provide an IP address or hostname to search for"
        exit 1
    fi
    
    if [[ ! -f "$INVENTORY_FILE" ]]; then
        msg_error "Inventory file not found. Run with 'update' first."
        exit 1
    fi
    
    msg_info "Searching for: $search_term"
    
    if command -v python3 &>/dev/null && python3 -c "import json" 2>/dev/null; then
        python3 <<PYTHON
import json
import sys

try:
    with open('$INVENTORY_FILE', 'r') as f:
        data = json.load(f)
    
    search = '$search_term'.lower()
    found = False
    
    for container in data.get('containers', []):
        ctid = str(container.get('ctid', ''))
        hostname = container.get('hostname', '').lower()
        ip = container.get('ip_address', '').lower()
        
        if search in ctid or search in hostname or search in ip:
            found = True
            print(f"CTID: {container.get('ctid')}")
            print(f"Hostname: {container.get('hostname')}")
            print(f"IP Address: {container.get('ip_address')}")
            print(f"Status: {container.get('status')}")
            print(f"Memory: {container.get('memory_mb')} MB")
            print(f"CPU Cores: {container.get('cpu_cores')}")
            print(f"Storage: {container.get('storage')}")
            print(f"Tags: {container.get('tags')}")
            print(f"Unprivileged: {container.get('unprivileged')}")
            print()
    
    if not found:
        print(f"No container found matching: $search_term", file=sys.stderr)
        sys.exit(1)
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
PYTHON
    else
        # Fallback to grep
        if [[ -f "$INVENTORY_CSV" ]]; then
            grep -i "$search_term" "$INVENTORY_CSV" || {
                msg_error "No container found matching: $search_term"
                exit 1
            }
        fi
    fi
}

# Show help
show_help() {
    cat <<EOF
Proxmox LXC Container Inventory Script

Usage: $0 [command] [options]

Commands:
  update              Generate/update inventory (default)
  show                Display current inventory
  find <term>         Find container by IP, hostname, or CTID
  help                Show this help message

Options:
  INVENTORY_DIR       Directory to store inventory files (default: /root/lxc-inventory)
  INVENTORY_FILE      JSON inventory file (default: \$INVENTORY_DIR/inventory.json)
  INVENTORY_CSV       CSV inventory file (default: \$INVENTORY_DIR/inventory.csv)
  INVENTORY_LOG       Log file (default: \$INVENTORY_DIR/inventory.log)

Examples:
  $0 update                              # Update inventory
  $0 show                                # Display inventory
  $0 find 192.168.1.100                  # Find by IP
  $0 find metabase                       # Find by hostname
  $0 find 100                            # Find by CTID
  INVENTORY_DIR=/opt/inventory $0 update # Custom directory

Files created:
  inventory.json  - Machine-readable JSON format
  inventory.csv   - Human-readable CSV format
  inventory.log   - Activity log

EOF
}

# Main execution
case "${1:-update}" in
    update)
        generate_inventory
        ;;
    show)
        display_inventory
        ;;
    find)
        if [[ -z "${2:-}" ]]; then
            msg_error "Please provide a search term"
            echo "Usage: $0 find <ip|hostname|ctid>"
            exit 1
        fi
        find_container "$2"
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        msg_error "Unknown command: $1"
        show_help
        exit 1
        ;;
esac

