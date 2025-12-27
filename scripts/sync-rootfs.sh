#!/bin/bash
# sync-rootfs.sh - Copy rootfs into Docker volume for NFS serving
#
# Usage:
#   ./scripts/sync-rootfs.sh                                    # Auto-detect from OpenSeaStack build
#   ./scripts/sync-rootfs.sh --from-buildroot                   # Use OpenSeaStack Docker build volume
#   ./scripts/sync-rootfs.sh /path/to/buildroot/output          # Buildroot output directory
#   ./scripts/sync-rootfs.sh /path/to/rootfs.tar.gz             # Tarball
#   ./scripts/sync-rootfs.sh /path/to/sdcard.img --linux        # SD image (Linux only)
#
# Options:
#   --ssh-key <path>    Install SSH public key for root access
#   --from-buildroot    Pull from OpenSeaStack oss-build-rpi Docker volume
#   --linux             Force Linux-style image mounting (for .img files)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OPENSEASTACK_DIR="${PROJECT_DIR}/../openseastack"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Detect platform
PLATFORM="$(uname -s)"
echo ""
echo "=== OpenSeaStack Netboot Sync ==="
echo "Platform: ${PLATFORM}"

# Parse arguments
SOURCE_PATH=""
SSH_KEY_PATH=""
FROM_BUILDROOT=false
FORCE_LINUX=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --ssh-key)
            SSH_KEY_PATH="$2"
            shift 2
            ;;
        --from-buildroot)
            FROM_BUILDROOT=true
            shift
            ;;
        --linux)
            FORCE_LINUX=true
            shift
            ;;
        *)
            if [ -z "$SOURCE_PATH" ]; then
                SOURCE_PATH="$1"
            fi
            shift
            ;;
    esac
done

# Check for default SSH key location if not specified
if [ -z "$SSH_KEY_PATH" ]; then
    for key_path in \
        "$PROJECT_DIR/keys/authorized_keys" \
        "$OPENSEASTACK_DIR/keys/openseastack_dev.pub" \
        "$HOME/.ssh/id_ed25519.pub" \
        "$HOME/.ssh/id_rsa.pub"; do
        if [ -f "$key_path" ]; then
            SSH_KEY_PATH="$key_path"
            echo -e "${GREEN}Using SSH key: $SSH_KEY_PATH${NC}"
            break
        fi
    done
fi

# =============================================================================
# Auto-detect source if not specified
# =============================================================================
if [ -z "$SOURCE_PATH" ] && [ "$FROM_BUILDROOT" = false ]; then
    # Check if OpenSeaStack build volume exists
    if docker volume inspect oss-build-rpi &>/dev/null; then
        echo -e "${GREEN}Auto-detected: OpenSeaStack build volume (oss-build-rpi)${NC}"
        FROM_BUILDROOT=true
    elif [ -d "$OPENSEASTACK_DIR/output/target" ]; then
        SOURCE_PATH="$OPENSEASTACK_DIR/output/target"
        echo -e "${GREEN}Auto-detected: $SOURCE_PATH${NC}"
    else
        echo -e "${RED}Error: No source specified and couldn't auto-detect.${NC}"
        echo ""
        echo "Usage:"
        echo "  $0                           # Auto-detect from OpenSeaStack build"
        echo "  $0 --from-buildroot          # Use oss-build-rpi Docker volume"
        echo "  $0 /path/to/output/target    # Buildroot output directory"
        echo "  $0 /path/to/rootfs.tar.gz    # Tarball"
        exit 1
    fi
fi

echo ""

# =============================================================================
# Sync from OpenSeaStack build volume (fastest on macOS)
# =============================================================================
if [ "$FROM_BUILDROOT" = true ]; then
    echo "Syncing from OpenSeaStack build volume..."
    echo ""
    
    # Create target volumes if needed
    docker volume create rpi-rootfs >/dev/null 2>&1 || true
    docker volume create rpi-tftpboot >/dev/null 2>&1 || true
    
    # Copy rootfs
    echo "Copying rootfs..."
    docker run --rm \
        -v oss-build-rpi:/build:ro \
        -v rpi-rootfs:/rootfs \
        alpine sh -c "
            rm -rf /rootfs/* 2>/dev/null || true
            cp -a /build/output/target/* /rootfs/
            echo '  ✓ Rootfs copied'
        "
    
    # Copy boot files
    echo "Copying boot/TFTP files..."
    docker run --rm \
        -v oss-build-rpi:/build:ro \
        -v rpi-tftpboot:/tftpboot \
        alpine sh -c "
            rm -rf /tftpboot/* 2>/dev/null || true
            cp /build/output/images/Image /tftpboot/
            cp /build/output/images/*.dtb /tftpboot/ 2>/dev/null || true
            cp /build/output/images/rpi-firmware/* /tftpboot/ 2>/dev/null || true
            rm -f /tftpboot/cmdline.txt 2>/dev/null || true
            echo '  ✓ Boot files copied'
            
            # Copy full image for download
            if [ -f /build/output/images/*.img ]; then
                cp /build/output/images/*.img /tftpboot/openseastack.img
                echo '  ✓ Full image copied to /tftpboot/openseastack.img (for commit-to-drive)'
            fi
        "
    
    # Install SSH key if available
    if [ -n "$SSH_KEY_PATH" ] && [ -f "$SSH_KEY_PATH" ]; then
        echo "Installing SSH key..."
        docker run --rm \
            -v "$(realpath "$SSH_KEY_PATH"):/ssh_key:ro" \
            -v rpi-rootfs:/rootfs \
            alpine sh -c "
                mkdir -p /rootfs/root/.ssh
                chmod 700 /rootfs/root/.ssh
                cat /ssh_key >> /rootfs/root/.ssh/authorized_keys
                chmod 600 /rootfs/root/.ssh/authorized_keys
                echo '  ✓ SSH key installed'
            "
    fi
    
    echo ""
    echo -e "${GREEN}=== Sync Complete ===${NC}"
    echo ""
    echo "Start the netboot server with:"
    echo "  ./run.sh start"
    exit 0
fi

# =============================================================================
# Sync from directory
# =============================================================================
if [ -d "$SOURCE_PATH" ]; then
    echo "Source type: Directory"
    
    # Check if it's a Buildroot output directory or direct rootfs
    if [ -d "${SOURCE_PATH}/target" ]; then
        ROOTFS_PATH="${SOURCE_PATH}/target"
        IMAGES_PATH="${SOURCE_PATH}/images"
    else
        ROOTFS_PATH="${SOURCE_PATH}"
        IMAGES_PATH=""
    fi
    
    echo "Rootfs: $ROOTFS_PATH"
    
    docker volume create rpi-rootfs >/dev/null 2>&1 || true
    docker volume create rpi-tftpboot >/dev/null 2>&1 || true
    
    echo "Copying rootfs..."
    docker run --rm \
        -v "${ROOTFS_PATH}:/source:ro" \
        -v rpi-rootfs:/rootfs \
        alpine sh -c "cp -a /source/* /rootfs/ && echo '  ✓ Done'"
    
    if [ -n "$IMAGES_PATH" ] && [ -d "$IMAGES_PATH" ]; then
        echo "Copying boot files..."
        docker run --rm \
            -v "${IMAGES_PATH}:/images:ro" \
            -v rpi-tftpboot:/tftpboot \
            alpine sh -c "
                cp /images/Image /tftpboot/ 2>/dev/null || true
                cp /images/*.dtb /tftpboot/ 2>/dev/null || true
                cp -r /images/rpi-firmware/* /tftpboot/ 2>/dev/null || true
                echo '  ✓ Done'
            "
    fi
    
    echo -e "${GREEN}=== Sync Complete ===${NC}"
    exit 0
fi

# =============================================================================
# Sync from tarball
# =============================================================================
if [[ "$SOURCE_PATH" == *.tar.gz ]] || [[ "$SOURCE_PATH" == *.tgz ]]; then
    echo "Source type: Tarball"
    
    docker volume create rpi-rootfs >/dev/null 2>&1 || true
    
    echo "Extracting tarball..."
    docker run --rm \
        -v "$(realpath "$SOURCE_PATH"):/source.tar.gz:ro" \
        -v rpi-rootfs:/rootfs \
        alpine sh -c "tar xzf /source.tar.gz -C /rootfs && echo '  ✓ Done'"
    
    echo -e "${GREEN}=== Sync Complete ===${NC}"
    exit 0
fi

# =============================================================================
# Sync from SD card image (Linux preferred)
# =============================================================================
if [[ "$SOURCE_PATH" == *.img ]]; then
    echo "Source type: SD Card Image"
    
    if [ "$PLATFORM" = "Darwin" ] && [ "$FORCE_LINUX" = false ]; then
        echo ""
        echo -e "${YELLOW}Warning: Extracting .img files on macOS is slow and complex.${NC}"
        echo ""
        echo "Recommended alternatives:"
        echo "  1. Use --from-buildroot to sync from Docker build volume (fastest)"
        echo "  2. Use a .tar.gz tarball instead of .img"
        echo "  3. Run on Linux with --linux flag"
        echo ""
        echo "Attempting Docker-based extraction (may take a while)..."
    fi
    
    docker volume create rpi-rootfs >/dev/null 2>&1 || true
    docker volume create rpi-tftpboot >/dev/null 2>&1 || true
    
    echo "Mounting and extracting image..."
    docker run --rm --privileged \
        -v "$(realpath "$SOURCE_PATH"):/sdcard.img:ro" \
        -v rpi-rootfs:/rootfs \
        -v rpi-tftpboot:/tftpboot \
        ubuntu:22.04 bash -c "
            apt-get update -qq && apt-get install -y -qq kpartx rsync >/dev/null
            
            # Setup loop device
            losetup -fP /sdcard.img
            LOOP=\$(losetup -j /sdcard.img | cut -d: -f1)
            
            # Mount partitions
            mkdir -p /mnt/boot /mnt/root
            mount \${LOOP}p1 /mnt/boot || true
            mount \${LOOP}p2 /mnt/root || true
            
            # Copy files
            if [ -d /mnt/root/bin ] || [ -L /mnt/root/bin ]; then
                echo 'Copying rootfs...'
                rsync -a /mnt/root/ /rootfs/
                echo '  ✓ Rootfs copied'
            fi
            
            if [ -d /mnt/boot ]; then
                echo 'Copying boot files...'
                cp -a /mnt/boot/* /tftpboot/ 2>/dev/null || true
                echo '  ✓ Boot files copied'
            fi
            
            # Cleanup
            umount /mnt/boot /mnt/root 2>/dev/null || true
            losetup -d \$LOOP 2>/dev/null || true
        "
    
    echo -e "${GREEN}=== Sync Complete ===${NC}"
    exit 0
fi

echo -e "${RED}Error: Unsupported source type: $SOURCE_PATH${NC}"
exit 1
