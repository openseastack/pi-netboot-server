#!/bin/bash
# commit-to-drive.sh - Flash the current netboot image to local NVMe/SD
#
# This script runs ON THE RASPBERRY PI during a netboot session.
# It downloads and writes the OS image to permanent storage.
#
# Usage (on the Pi):
#   sudo /home/scripts/commit-to-drive.sh
#   sudo /home/scripts/commit-to-drive.sh --target /dev/mmcblk0
#   sudo /home/scripts/commit-to-drive.sh --url http://server:8000/image.img

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Defaults
TARGET_DRIVE=""
IMAGE_URL=""
SKIP_CONFIRM=false
REBOOT_AFTER=true

print_banner() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║     OpenSeaStack Commit to Drive         ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo ""
}

print_usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --target <device>   Target drive (default: auto-detect NVMe or SD)"
    echo "  --url <url>         Image URL (default: fetch from netboot server)"
    echo "  --no-reboot         Don't reboot after flashing"
    echo "  -y, --yes           Skip confirmation prompts"
    echo ""
    echo "Examples:"
    echo "  $0                                    # Auto-detect everything"
    echo "  $0 --target /dev/nvme0n1              # Flash to NVMe"
    echo "  $0 --target /dev/mmcblk0              # Flash to SD card"
    echo "  $0 --url http://192.168.1.100:8000/image.img"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --target)
            TARGET_DRIVE="$2"
            shift 2
            ;;
        --url)
            IMAGE_URL="$2"
            shift 2
            ;;
        --no-reboot)
            REBOOT_AFTER=false
            shift
            ;;
        -y|--yes)
            SKIP_CONFIRM=true
            shift
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            print_usage
            exit 1
            ;;
    esac
done

print_banner

# =============================================================================
# Safety Check: Are we running from NFS?
# =============================================================================
echo "Checking boot environment..."

if grep -q "nfs" /proc/mounts | grep " / "; then
    echo -e "${GREEN}✓ Running from NFS (netboot)${NC}"
elif grep -q "nfs" /proc/cmdline; then
    echo -e "${GREEN}✓ Booted via netboot (NFS root)${NC}"
else
    echo -e "${YELLOW}⚠ WARNING: It looks like you are NOT running from netboot.${NC}"
    echo "This script is designed to run during a netboot session."
    echo ""
    if [ "$SKIP_CONFIRM" != true ]; then
        read -p "Continue anyway? This may overwrite your running system! [y/N] " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Cancelled."
            exit 1
        fi
    fi
fi

# =============================================================================
# Auto-detect Target Drive
# =============================================================================
if [ -z "$TARGET_DRIVE" ]; then
    echo "Detecting target drive..."
    
    # Prefer NVMe if available
    if [ -b /dev/nvme0n1 ]; then
        TARGET_DRIVE="/dev/nvme0n1"
        echo -e "${GREEN}✓ Found NVMe: $TARGET_DRIVE${NC}"
    elif [ -b /dev/mmcblk0 ]; then
        TARGET_DRIVE="/dev/mmcblk0"
        echo -e "${GREEN}✓ Found SD card: $TARGET_DRIVE${NC}"
    elif [ -b /dev/sda ]; then
        TARGET_DRIVE="/dev/sda"
        echo -e "${YELLOW}⚠ Found USB/SATA: $TARGET_DRIVE${NC}"
    else
        echo -e "${RED}Error: No suitable target drive found.${NC}"
        echo "Available block devices:"
        lsblk -d -o NAME,SIZE,TYPE,MODEL
        exit 1
    fi
fi

# Verify target exists
if [ ! -b "$TARGET_DRIVE" ]; then
    echo -e "${RED}Error: Target drive not found: $TARGET_DRIVE${NC}"
    exit 1
fi

# =============================================================================
# Auto-detect Image URL
# =============================================================================
if [ -z "$IMAGE_URL" ]; then
    echo "Detecting netboot server..."
    
    # Get the NFS server IP from mount
    NFS_SERVER=$(mount | grep "nfs" | head -1 | awk -F: '{print $1}')
    
    if [ -z "$NFS_SERVER" ]; then
        # Try to get from default gateway
        NFS_SERVER=$(ip route show default | awk '{print $3}')
    fi
    
    if [ -z "$NFS_SERVER" ]; then
        echo -e "${RED}Error: Could not detect netboot server.${NC}"
        echo "Please specify with: --url http://SERVER:8000/image.img"
        exit 1
    fi
    
    # Check common image locations
    for url in \
        "http://${NFS_SERVER}:8000/openseastack.img" \
        "http://${NFS_SERVER}:8000/sdcard.img" \
        "http://${NFS_SERVER}:8000/image.img"; do
        if curl -sI "$url" | grep -q "200 OK"; then
            IMAGE_URL="$url"
            break
        fi
    done
    
    if [ -z "$IMAGE_URL" ]; then
        echo -e "${YELLOW}⚠ No image found on server. Will use live rootfs.${NC}"
        USE_LIVE_ROOTFS=true
    else
        echo -e "${GREEN}✓ Found image: $IMAGE_URL${NC}"
    fi
fi

# =============================================================================
# Show Summary and Confirm
# =============================================================================
echo ""
echo "=== Commit Summary ==="
echo "Target Drive: $TARGET_DRIVE"
if [ "$USE_LIVE_ROOTFS" = true ]; then
    echo "Source: Live NFS rootfs (will create image)"
else
    echo "Source: $IMAGE_URL"
fi
echo "Reboot After: $REBOOT_AFTER"
echo ""

# Get target drive info
echo "Target drive info:"
lsblk -o NAME,SIZE,TYPE,MODEL "$TARGET_DRIVE" 2>/dev/null || true
echo ""

if [ "$SKIP_CONFIRM" != true ]; then
    echo -e "${YELLOW}WARNING: All data on $TARGET_DRIVE will be ERASED!${NC}"
    read -p "Proceed with flashing? [y/N] " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Cancelled."
        exit 1
    fi
fi

# =============================================================================
# Perform the Flash
# =============================================================================
echo ""
echo "=== Flashing to $TARGET_DRIVE ==="
echo "This may take several minutes..."
echo ""

if [ "$USE_LIVE_ROOTFS" = true ]; then
    # Create image from live rootfs
    echo "Creating image from live NFS rootfs..."
    echo "(This is a simplified approach - in production, use a pre-built image)"
    
    # This would need more sophisticated partitioning
    # For now, just use rsync to copy the rootfs
    
    # Create partitions
    echo "Creating partitions..."
    parted -s "$TARGET_DRIVE" mklabel msdos
    parted -s "$TARGET_DRIVE" mkpart primary fat32 1MiB 256MiB
    parted -s "$TARGET_DRIVE" mkpart primary ext4 256MiB 100%
    parted -s "$TARGET_DRIVE" set 1 boot on
    
    # Determine partition names
    if [[ "$TARGET_DRIVE" == *"nvme"* ]] || [[ "$TARGET_DRIVE" == *"mmcblk"* ]]; then
        BOOT_PART="${TARGET_DRIVE}p1"
        ROOT_PART="${TARGET_DRIVE}p2"
    else
        BOOT_PART="${TARGET_DRIVE}1"
        ROOT_PART="${TARGET_DRIVE}2"
    fi
    
    # Wait for partitions
    sleep 2
    partprobe "$TARGET_DRIVE" 2>/dev/null || true
    
    # Format
    echo "Formatting partitions..."
    mkfs.vfat -F 32 -n BOOT "$BOOT_PART"
    mkfs.ext4 -L rootfs "$ROOT_PART"
    
    # Mount
    mkdir -p /mnt/target-boot /mnt/target-root
    mount "$BOOT_PART" /mnt/target-boot
    mount "$ROOT_PART" /mnt/target-root
    
    # Copy boot files
    echo "Copying boot files..."
    # Get boot files from TFTP or local /boot
    if [ -d /boot ]; then
        cp -a /boot/* /mnt/target-boot/ 2>/dev/null || true
    fi
    
    # Update cmdline.txt for local boot
    cat > /mnt/target-boot/cmdline.txt << EOF
console=serial0,115200 console=tty1 root=/dev/mmcblk0p2 rootfstype=ext4 elevator=deadline fsck.repair=yes rootwait
EOF
    
    # Copy rootfs
    echo "Copying rootfs (this takes a while)..."
    rsync -aAXv --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' \
        --exclude='/tmp/*' --exclude='/run/*' --exclude='/mnt/*' \
        / /mnt/target-root/
    
    # Create required directories
    mkdir -p /mnt/target-root/{proc,sys,dev,tmp,run,mnt}
    
    # Update fstab
    cat > /mnt/target-root/etc/fstab << EOF
# Generated by commit-to-drive.sh
/dev/mmcblk0p1  /boot  vfat  defaults  0  2
/dev/mmcblk0p2  /      ext4  defaults,noatime  0  1
EOF
    
    # Cleanup
    sync
    umount /mnt/target-boot /mnt/target-root
    rmdir /mnt/target-boot /mnt/target-root 2>/dev/null || true
    
else
    # Stream image directly from URL
    echo "Downloading and writing image..."
    curl -L --progress-bar "$IMAGE_URL" | dd of="$TARGET_DRIVE" bs=4M status=progress conv=fsync
fi

sync

echo ""
echo -e "${GREEN}=== Flash Complete ===${NC}"
echo ""

# =============================================================================
# Update EEPROM Boot Order (Optional)
# =============================================================================
echo "Updating boot order to prefer local storage..."

if command -v rpi-eeprom-config &> /dev/null; then
    # Get current config
    CURRENT_ORDER=$(rpi-eeprom-config --get BOOT_ORDER 2>/dev/null || echo "unknown")
    echo "Current boot order: $CURRENT_ORDER"
    
    # Set to prefer NVMe/SD over network
    # 0xf461 = NVMe -> SD -> USB -> Network -> Loop
    # rpi-eeprom-config --set BOOT_ORDER=0xf461
    echo "(Boot order update skipped - configure manually if needed)"
else
    echo "(rpi-eeprom-config not available)"
fi

# =============================================================================
# Reboot
# =============================================================================
if [ "$REBOOT_AFTER" = true ]; then
    echo ""
    echo "Rebooting in 5 seconds..."
    echo "(Press Ctrl+C to cancel)"
    sleep 5
    reboot
else
    echo ""
    echo "Flash complete. Reboot when ready:"
    echo "  sudo reboot"
fi
