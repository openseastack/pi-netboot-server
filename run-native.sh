#!/bin/bash
# run-native.sh - Run netboot server natively on macOS
#
# This bypasses Docker and runs dnsmasq directly on macOS for proper
# network access to your Pi.
#
# Prerequisites:
#   brew install dnsmasq
#   brew install nfs-utils  (or use macOS built-in NFS)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Detect network interface and IP
get_server_ip() {
    # Find interface with 10.10.200.x
    for iface in $(ifconfig -l); do
        ip=$(ifconfig $iface 2>/dev/null | grep "inet 10\." | awk '{print $2}')
        if [ -n "$ip" ]; then
            echo "$ip"
            return 0
        fi
    done
    # Fallback
    ifconfig en0 2>/dev/null | grep "inet " | awk '{print $2}'
}

SERVER_IP=$(get_server_ip)
TFTP_ROOT="$SCRIPT_DIR/tftpboot"
NFS_ROOT="$SCRIPT_DIR/nfsroot"

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   Native macOS Netboot Server            ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""
echo "Server IP: $SERVER_IP"
echo ""

# Check for dnsmasq
if ! command -v dnsmasq &>/dev/null; then
    echo -e "${RED}Error: dnsmasq not found. Install with:${NC}"
    echo "  brew install dnsmasq"
    exit 1
fi

# Create directories
mkdir -p "$TFTP_ROOT" "$NFS_ROOT"

# Copy files from Docker volumes to local directories
echo "Copying files from Docker volumes..."
docker run --rm -v rpi-tftpboot:/src -v "$TFTP_ROOT:/dst" alpine cp -a /src/. /dst/
docker run --rm -v rpi-rootfs:/src -v "$NFS_ROOT:/dst" alpine cp -a /src/. /dst/
echo -e "${GREEN}✓ Files copied${NC}"

# Create dnsmasq config
cat > /tmp/dnsmasq-netboot.conf << EOF
# Netboot dnsmasq config
port=0
log-dhcp
enable-tftp
tftp-root=$TFTP_ROOT

# ProxyDHCP mode
dhcp-range=$SERVER_IP,proxy

# RPi-specific options
pxe-service=0,"Raspberry Pi Boot",

# Boot file for ARM64
dhcp-boot=start4.elf

# Vendor class for RPi
dhcp-vendorclass=set:rpi,PXEClient:Arch:00011

# Log
log-facility=/tmp/dnsmasq-netboot.log
EOF

echo "Starting dnsmasq (requires sudo)..."
echo ""
echo "Dnsmasq config:"
cat /tmp/dnsmasq-netboot.conf
echo ""

# Start dnsmasq
sudo dnsmasq -C /tmp/dnsmasq-netboot.conf -d &
DNSMASQ_PID=$!

# Setup NFS export
echo ""
echo "Setting up NFS export..."
echo "$NFS_ROOT -alldirs -maproot=root:wheel -network 10.10.200.0 -mask 255.255.255.0" | sudo tee /etc/exports.netboot
sudo nfsd restart

echo ""
echo -e "${GREEN}=== Netboot Server Running ===${NC}"
echo "Server IP: $SERVER_IP"
echo "TFTP Root: $TFTP_ROOT"
echo "NFS Root:  $NFS_ROOT"
echo ""
echo "Press Ctrl+C to stop"
echo ""

# Wait
trap "sudo kill $DNSMASQ_PID 2>/dev/null; sudo nfsd stop; exit" SIGINT SIGTERM
wait $DNSMASQ_PID
