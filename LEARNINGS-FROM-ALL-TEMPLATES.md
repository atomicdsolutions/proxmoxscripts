# Key Learnings from all-templates.sh

This document summarizes the important patterns and practices learned from `all-templates.sh` and how they've been incorporated into our Proxmox scripts.

## Critical Proxmox 9 Syntax Changes

### 1. Option Format: Single Dash, Not Double Dash
**Before (incorrect):**
```bash
--hostname $HOSTNAME
--cores $CPU_CORES
--rootfs-size $SIZE
```

**After (correct Proxmox 9):**
```bash
-hostname $HOSTNAME
-cores $CPU_CORES
-rootfs $STORAGE:$SIZE
```

**Key Learning:** Proxmox uses single dash (`-`) for `pct create` options, not double dash (`--`).

### 2. Rootfs Format Change
**Old (Proxmox 8 and earlier):**
```bash
--rootfs-size 8G
--storage local-lvm
```

**New (Proxmox 9):**
```bash
-rootfs local-lvm:8
```

**Key Learning:** 
- `--rootfs-size` was removed
- Storage is now part of the rootfs option: `storage:size`
- Size is numeric only (no 'G' suffix in the option)

### 3. Command Building: Use Arrays
**Before:**
```bash
PCT_CMD="pct create $CTID $TEMPLATE"
PCT_CMD+=" --hostname $HOSTNAME"
PCT_CMD+=" --cores $CPU_CORES"
eval "$PCT_CMD"
```

**After (from all-templates.sh):**
```bash
PCT_OPTIONS=(
    -arch "$(dpkg --print-architecture)"
    -hostname "$HOSTNAME"
    -cores "$CPU_CORES"
)
pct create $CTID $TEMPLATE "${PCT_OPTIONS[@]}"
```

**Key Learning:** Using arrays is cleaner, safer, and easier to maintain.

## Best Practices Learned

### 1. Architecture Detection
Always include architecture:
```bash
-arch "$(dpkg --print-architecture)"
```
This ensures compatibility across different CPU architectures.

### 2. Template Path Format
**Correct format:**
```bash
local:vztmpl/template-name.tar.zst
```

Or if already in that format:
```bash
local:template-name.tar.zst
```

**Key Learning:** Templates use `vztmpl/` path segment when accessed.

### 3. Features Format
**Correct format (comma-separated):**
```bash
-features keyctl=1,nesting=1
```

Not separate flags:
```bash
# Wrong
--features nesting=1 --features keyctl=1
```

### 4. Storage Detection
Use `pvesm status -content` to detect valid storage:
```bash
# Get storage with container support (rootdir)
STORAGE=$(pvesm status -content rootdir 2>/dev/null | awk 'NR>1 {print $1; exit}')

# Get storage with template support (vztmpl)
TEMPLATE_STORAGE=$(pvesm status -content vztmpl 2>/dev/null | awk 'NR>1 {print $1; exit}')
```

**Key Learning:** Template storage and container storage can be different!

### 5. Auto CTID Detection
```bash
CTID=$(pvesh get /cluster/nextid)
```
Automatically gets the next available container ID.

### 6. Better IP Detection
**Improved method with retries:**
```bash
max_attempts=5
attempt=1
while [[ $attempt -le $max_attempts ]]; do
    IP=$(pct exec $CTID ip a show dev eth0 | grep -oP 'inet \K[^/]+')
    if [[ -n "$IP" ]]; then
        break
    fi
    sleep 3
    ((attempt++))
done
```

**Key Learning:** Use `ip a show dev eth0` with grep pattern for more reliable IP extraction.

### 7. Error Handling Pattern
**Sophisticated error handling:**
```bash
set -eEuo pipefail
trap die ERR
function error_exit() {
    # Cleanup on error
    [ ! -z ${CTID-} ] && cleanup_ctid
    exit $EXIT
}
```

**Key Learning:** Always cleanup containers on error to avoid leaving partial containers.

### 8. Container Cleanup Function
```bash
function cleanup_ctid() {
    if pct status $CTID &>/dev/null; then
        if [ "$(pct status $CTID | awk '{print $2}')" == "running" ]; then
            pct stop $CTID
        fi
        pct destroy $CTID
    fi
}
```

## Improvements Applied to Our Scripts

### ✅ Updated metabase-install-standalone.sh
1. Changed to single-dash options (`-hostname` not `--hostname`)
2. Fixed rootfs format (`-rootfs storage:size`)
3. Using array-based command building
4. Added architecture detection
5. Improved IP detection with retries
6. Auto-detect next CTID
7. Auto-detect storage
8. Proper template path handling

### ✅ Updated lxc-template.sh
1. Same Proxmox 9 syntax updates
2. Array-based command building
3. Better error handling

## Comparison: Before vs After

### Before (Incorrect Proxmox 9 syntax)
```bash
pct create $CTID $TEMPLATE \
  --storage local-lvm \
  --hostname $HOSTNAME \
  --password '$PASSWORD' \
  --rootfs-size 8G \
  --cores 2 \
  --memory 2048
```

### After (Correct Proxmox 9 syntax)
```bash
PCT_OPTIONS=(
    -arch "$(dpkg --print-architecture)"
    -hostname "$HOSTNAME"
    -password "$PASSWORD"
    -rootfs "local-lvm:8"
    -cores 2
    -memory 2048
)
pct create $CTID local:vztmpl/$TEMPLATE "${PCT_OPTIONS[@]}"
```

## Template Storage vs Container Storage

**Important distinction from all-templates.sh:**
- **Template storage**: Where templates are stored (`vztmpl` content type)
- **Container storage**: Where containers run (`rootdir` content type)

These can be different storage pools! The script properly handles both.

## Additional Learnings

### 1. Password Saving
Save passwords for later reference:
```bash
echo "$NAME password: ${PASS}" >>~/$NAME.creds
```

### 2. Template Download
Handle template downloading if not available:
```bash
pveam download $TEMPLATE_STORAGE $TEMPLATE
```

### 3. Service Management
Be aware of other Proxmox services:
```bash
# Stop monitoring service during creation
if systemctl is-active -q ping-instances.service; then
    systemctl stop ping-instances.service
fi
```

## Summary

The `all-templates.sh` script taught us:
1. ✅ **Critical**: Use single-dash options (`-option`)
2. ✅ **Critical**: Rootfs format is `-rootfs storage:size`
3. ✅ **Best Practice**: Use arrays for command building
4. ✅ **Best Practice**: Always include architecture
5. ✅ **Best Practice**: Better error handling and cleanup
6. ✅ **Best Practice**: Improved IP detection with retries
7. ✅ **Best Practice**: Auto-detect storage and CTID
8. ✅ **Best Practice**: Proper template path format

All these improvements have been incorporated into our scripts!

