#!/bin/bash
# Netboot Image Writer - First Boot Setup
# Add this to your Pi image's first-boot or rc.local

# This script only runs during netboot (NFS root)
# When booting from SD/NVMe, it will disable the service

NETBOOT_SERVER="10.10.200.75"

# Check if we're netbooted (root is NFS)
if mount | grep -q "/ type nfs"; then
    echo "Netboot detected - setting up imager service..."
    
    # Download and run the installation script
    curl -sf http://$NETBOOT_SERVER:38434/api/bootstrap/install-script | bash
    
else
    echo "Local disk boot - netboot imager not needed"
    
    # Disable service if it exists
    if systemctl list-unit-files | grep -q netboot-imager; then
        systemctl disable netboot-imager 2>/dev/null || true
        systemctl stop netboot-imager 2>/dev/null || true
    fi
fi
