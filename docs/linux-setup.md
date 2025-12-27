# Linux Setup

Running rpi-netboot-dev on native Linux is simpler than macOS since Docker can directly access the host network.

## Prerequisites

```bash
# Install Docker
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER

# Install Docker Compose (if not included)
sudo apt install docker-compose-plugin
```

## Quick Start

```bash
# Clone and enter the project
cd rpi-netboot-dev

# Sync your rootfs
./scripts/sync-rootfs.sh /path/to/openseastack/output

# Start the server
./run.sh start
```

That's it! No special configuration needed.

## Why Linux is Simpler

| Feature | Linux | macOS (Colima) |
|---------|-------|----------------|
| `--net=host` | Binds to physical LAN | Binds to VM only |
| NFS exports | Works from bind mounts | Requires Docker volumes |
| UDP/TFTP | Native, no issues | May have fragmentation |
| Bridged networking | Automatic | Requires `--network-address` |

## Network Requirements

- Your development machine and Raspberry Pi must be on the **same Layer 2 network** (same switch/VLAN)
- Ports used: 67/udp (DHCP), 69/udp (TFTP), 111 (RPC), 2049 (NFS)

## Firewall Configuration

If you have a firewall enabled, open the required ports:

```bash
# UFW (Ubuntu/Debian)
sudo ufw allow 67/udp   # DHCP
sudo ufw allow 69/udp   # TFTP
sudo ufw allow 111      # RPC
sudo ufw allow 2049     # NFS

# firewalld (RHEL/Fedora)
sudo firewall-cmd --add-service=dhcp --permanent
sudo firewall-cmd --add-service=tftp --permanent
sudo firewall-cmd --add-service=nfs --permanent
sudo firewall-cmd --reload
```

## Using Bind Mounts (Optional)

On Linux, you can optionally use bind mounts instead of Docker volumes, allowing you to edit the rootfs directly:

```bash
# Create local directories
mkdir -p ./rootfs ./tftpboot

# Modify docker-compose.yml to use bind mounts:
# volumes:
#   - ./rootfs:/nfs/rootfs
#   - ./tftpboot:/tftpboot
```

Then sync directly to these directories instead of Docker volumes.

## Troubleshooting

### "Address already in use" on port 67
Another DHCP server is running. Check:
```bash
sudo ss -ulnp | grep :67
# Common culprits: dnsmasq, isc-dhcp-server
sudo systemctl stop dnsmasq
```

### NFS mount fails on Pi
Check NFS server is running:
```bash
docker exec rpi-netboot-dev exportfs -v
docker exec rpi-netboot-dev rpcinfo -p
```

### Pi doesn't receive DHCP offer
Ensure you're on the same network segment:
```bash
# Check your interface
ip addr show

# Verify Pi is visible (after it boots partially)
arp -a | grep -i "dc:a6:32\|b8:27:eb"
```
