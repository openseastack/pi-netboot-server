#!/bin/bash
# entrypoint.sh - Netboot Server Startup Script
set -e

echo "=== rpi-netboot-dev Server Starting ==="

# Configuration from environment
DHCP_MODE="${DHCP_MODE:-proxy}"
DHCP_RANGE="${DHCP_RANGE:-}"
SERVER_IP="${SERVER_IP:-}"
SUBNET="${SUBNET:-192.168.1.0}"

# Auto-detect server IP if not provided
if [ -z "$SERVER_IP" ]; then
    # Get all non-loopback IPs
    ALL_IPS=$(ip -4 addr show | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | grep -v '^127\.')
    
    # PRIORITY ORDER: 10.10.200.x (user LAN), then 10.x, then 192.168.64.x (Colima), then others
    for pattern in "^10\.10\.200\." "^10\." "^192\.168\.64\." "^192\.168\." ""; do
        if [ -n "$pattern" ]; then
            SERVER_IP=$(echo "$ALL_IPS" | grep -E "$pattern" | head -1)
        else
            # Last resort: any non-Docker internal IP
            SERVER_IP=$(echo "$ALL_IPS" | grep -v "^192\.168\.5\." | grep -v "^172\." | head -1)
        fi
        [ -n "$SERVER_IP" ] && break
    done
    
    # Last resort fallback
    if [ -z "$SERVER_IP" ]; then
        SERVER_IP=$(echo "$ALL_IPS" | head -1)
    fi
    
    echo "Auto-detected server IP: $SERVER_IP"
fi

# Derive subnet from server IP if not set
if [ "$SUBNET" = "192.168.1.0" ] && [ -n "$SERVER_IP" ]; then
    SUBNET=$(echo "$SERVER_IP" | sed 's/\.[0-9]*$/.0/')
fi

echo "DHCP Mode: $DHCP_MODE"
echo "Server IP: $SERVER_IP"
echo "Subnet: $SUBNET"

# =============================================================================
# Configure DNSMASQ based on mode
# =============================================================================
echo "Configuring dnsmasq..."

# Check for saved DHCP config from Web UI
DHCP_CONFIG_FILE="/tmp/dhcp-mode.conf"
if [ -f "$DHCP_CONFIG_FILE" ]; then
    echo "Found saved DHCP configuration, loading..."
    # Parse JSON config (simple extraction)
    SAVED_MODE=$(grep -o '"mode":"[^"]*"' "$DHCP_CONFIG_FILE" | cut -d'"' -f4)
    SAVED_INTERFACE=$(grep -o '"interface":"[^"]*"' "$DHCP_CONFIG_FILE" | cut -d'"' -f4)
    SAVED_RANGE=$(grep -o '"range":"[^"]*"' "$DHCP_CONFIG_FILE" | cut -d'"' -f4)
    
    if [ -n "$SAVED_MODE" ]; then
        DHCP_MODE="$SAVED_MODE"
        echo "Using saved DHCP mode: $DHCP_MODE"
    fi
    if [ -n "$SAVED_RANGE" ]; then
        DHCP_RANGE="$SAVED_RANGE"
        echo "Using saved DHCP range: $DHCP_RANGE"
    fi
fi

cat > /etc/dnsmasq.conf << EOF
# rpi-netboot-dev dnsmasq configuration
# Generated at startup - mode: $DHCP_MODE

# Logging
log-dhcp
log-facility=/var/log/netboot/dnsmasq.log

# TFTP Settings
enable-tftp
tftp-root=/tftpboot
tftp-no-blocksize

# Only respond to Raspberry Pi devices (MAC OUI)
# Pi 3 and earlier: b8:27:eb
# Pi 4: dc:a6:32  
# Pi 5: d8:3a:dd
dhcp-mac=set:rpi,b8:27:eb:*:*:*
dhcp-mac=set:rpi,dc:a6:32:*:*:*
dhcp-mac=set:rpi,d8:3a:dd:*:*:*
EOF

if [ "$DHCP_MODE" = "proxy" ]; then
    cat >> /etc/dnsmasq.conf << EOF

# ProxyDHCP Mode - Only provide boot info, router handles IPs
port=0
dhcp-range=${SUBNET%.*}.255,proxy
pxe-service=0,"Raspberry Pi Boot"
dhcp-boot=bootcode.bin
EOF

elif [ "$DHCP_MODE" = "full" ]; then
    if [ -z "$DHCP_RANGE" ]; then
        # Default range: .100 to .200
        DHCP_RANGE="${SUBNET%.*}.100,${SUBNET%.*}.200,12h"
    fi
    
    # Build dnsmasq config for full DHCP mode
    cat >> /etc/dnsmasq.conf << EOF

# Full DHCP Mode - Assigns IPs (use with caution!)
port=67
dhcp-range=$DHCP_RANGE
dhcp-option=option:router,$SERVER_IP
dhcp-boot=bootcode.bin
EOF

    # If interface was specified via Web UI, add it
    if [ -n "$SAVED_INTERFACE" ]; then
        echo "interface=$SAVED_INTERFACE" >> /etc/dnsmasq.conf
        echo "bind-interfaces" >> /etc/dnsmasq.conf
        echo "Configured dnsmasq to listen on interface: $SAVED_INTERFACE"
    fi

else
    echo "ERROR: Unknown DHCP_MODE: $DHCP_MODE"
    exit 1
fi

# =============================================================================
# Configure NFS Exports
# =============================================================================
echo "Configuring NFS exports..."

cat > /etc/exports << EOF
# rpi-netboot-dev NFS exports (unfs3 format)
/nfs/rootfs (rw,no_root_squash)
/tftpboot (ro,no_root_squash)
EOF


# =============================================================================
# Configure Boot Files (cmdline.txt)
# =============================================================================
echo "Configuring boot files..."

cat > /tftpboot/cmdline.txt << EOF
console=serial0,115200 console=tty1 root=/dev/nfs nfsroot=${SERVER_IP}:/nfs/rootfs,vers=3,tcp rw ip=dhcp rootwait
EOF
echo "Generated /tftpboot/cmdline.txt (NFS Root: ${SERVER_IP})"

# =============================================================================
# Auto-Inject Netboot-Imager Bootstrap Service
# =============================================================================
echo "Injecting netboot-imager bootstrap service..."

# Only inject if /nfs/rootfs exists and has a valid Linux filesystem
if [ -d "/nfs/rootfs/etc/systemd/system" ]; then
    # Create the bootstrap service that runs on first boot
    cat > /nfs/rootfs/etc/systemd/system/netboot-bootstrap.service <<BOOTSTRAP_EOF
[Unit]
Description=Netboot Image Writer Auto-Bootstrap
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'curl -sf http://${SERVER_IP}:38434/api/bootstrap/install-script | sh'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
BOOTSTRAP_EOF

    # Enable the service if systemd is available
    if [ -f "/nfs/rootfs/bin/systemctl" ] || [ -f "/nfs/rootfs/usr/bin/systemctl" ]; then
        # Don't use chroot, just create the symlink manually
        mkdir -p /nfs/rootfs/etc/systemd/system/multi-user.target.wants
        ln -sf /etc/systemd/system/netboot-bootstrap.service \
               /nfs/rootfs/etc/systemd/system/multi-user.target.wants/netboot-bootstrap.service 2>/dev/null || true
        echo "  Netboot-imager bootstrap service installed and enabled"
    else
        echo "  Warning: systemd not found, skipping service enable"
    fi
else
    echo "  Skipping bootstrap injection (no systemd directory found)"
fi

# =============================================================================
# Start Services
# =============================================================================
echo "Starting services..."

# Start rpcbind (required for NFS)
echo "  Starting rpcbind..."
rpcbind || echo "rpcbind may already be running"

# Export NFS shares (handled by unfsd)
echo "  Exporting NFS shares (via unfsd)..."


# Start NFS server (unfs3)
echo "  Starting unfsd (debug)..."
unfsd -e /etc/exports -i /var/run/unfsd.pid -d > /var/log/netboot/unfsd.log 2>&1 &


# Start mountd (not needed for unfs3)
# rpc.mountd || echo "mountd may already be running"

# Start Web UI (Flask API)
echo "  Starting Web UI on port 38434..."
cd /webui
python3 app.py > /var/log/netboot/webui.log 2>&1 &
cd /


# Start dnsmasq
echo "  Starting dnsmasq..."
dnsmasq --keep-in-foreground --log-queries &
DNSMASQ_PID=$!

echo ""
echo "=== rpi-netboot-dev Server Ready ==="
echo "Server IP: $SERVER_IP"
echo "TFTP Root: /tftpboot"
echo "NFS Root:  /nfs/rootfs"
echo "DHCP Mode: $DHCP_MODE"
echo ""
echo "Connect your Raspberry Pi via ethernet to netboot."
echo ""

# Keep container alive and handle signals
trap "kill $DNSMASQ_PID 2>/dev/null; exit 0" SIGTERM SIGINT

# Tail logs if they exist
touch /var/log/netboot/dnsmasq.log /var/log/netboot/unfsd.log
tail -f /var/log/netboot/dnsmasq.log /var/log/netboot/unfsd.log &

# Wait for dnsmasq
wait $DNSMASQ_PID
