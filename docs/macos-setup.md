# macOS Setup (Colima)

Running rpi-netboot-dev on macOS requires Colima with **true bridged networking** to your physical LAN.

## Prerequisites

### 1. Install Dependencies

```bash
# Install Homebrew if not present: https://brew.sh

# Install Colima and Docker
brew install colima docker docker-compose

# CRITICAL: Install socket_vmnet for bridged networking
brew install socket_vmnet
brew tap homebrew/services
sudo brew services start socket_vmnet
```

> **⚠️ Important:** `socket_vmnet` is required for bridged networking. Without it, Docker containers are isolated on a virtual network.

### 2. Configure True Bridged Networking

**Find your physical Ethernet interface:**
```bash
# Find interface with your LAN IP (e.g., 10.10.200.x or 192.168.1.x)
ifconfig | grep -B 1 "inet 10.10"   # Adjust IP pattern as needed
```
Note the interface name (usually `en0`, `en8`, etc.)

**Configure Colima for bridged mode:**
```bash
colima stop
colima start --edit
```

Find the `network:` block and change it to:
```yaml
network:
  address: true
  dns: []
  driver: bridged        # <-- CRITICAL: Change from 'slirp' to 'bridged'
  interface: en8         # <-- Your physical interface from step above
```

Save and exit (`:wq` in vim).

**Verify Colima got a LAN IP:**
```bash
colima list
# Should show an IP on your LAN (e.g., 10.10.200.x), not 192.168.64.x
```

### 3. Start the Netboot Server

```bash
cd rpi-netboot-dev

# Sync rootfs from OpenSeaStack build
./scripts/sync-rootfs.sh --from-buildroot

# Start server
./run.sh start
```

The server should now report a LAN IP that your Pi can reach!

---

## Troubleshooting

### "No route to host" from Pi
Colima is not truly bridged. Edit config (`colima start --edit`) and set `driver: bridged`.

### Server shows 192.168.64.x instead of LAN IP
The `interface` setting is wrong or missing. Use `ifconfig` to find your actual ethernet interface.

### NFS export fails  
NFS kernel support isn't available in Docker on macOS. The netboot uses TFTP for boot files; the rootfs is still shared. For full NFS, use Linux.

### TFTP hangs at "Loading kernel..."
UDP fragmentation issue. The `tftp-no-blocksize` option in dnsmasq.conf should help.

---

## Why Docker Volumes are Required

On macOS, the rootfs **cannot** be a bind mount from your Mac filesystem.

**Why?** NFS cannot "re-export" a virtiofs mount. The chain is:
```
Mac (APFS) → virtiofs → Colima VM → Container → NFS export
```

**Solution:** Docker named volumes, which are stored inside the Colima VM's disk (native ext4).

## Editing Files in Docker Volumes

Options:

1. **Re-sync after changes:**
   ```bash
   ./scripts/sync-rootfs.sh --from-buildroot
   ```

2. **Shell into container:**
   ```bash
   ./run.sh shell
   vi /nfs/rootfs/etc/hostname
   ```

3. **Use a helper container:**
   ```bash
   docker run -it -v rpi-rootfs:/data alpine sh
   ```
