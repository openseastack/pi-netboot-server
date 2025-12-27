# pi-netboot-server

**Zero-configuration PXE netboot server for Raspberry Pi development and deployment**

A comprehensive Docker-based solution that enables Raspberry Pis to boot over the network (PXE/netboot) and provides automatic image writing to local storage - perfect for development, testing, and fleet deployment scenarios.

## What Does This Do?

This netboot server allows you to:

1. **Boot Raspberry Pis over the network** - No SD card needed for initial setup
2. **Test images instantly** - Boot different OS images without swapping SD cards
3. **Write images remotely** - Automatic "write-to-disk" from the netbooted environment
4. **Zero manual configuration** - Auto-bootstrap service installer runs on first boot
5. **Monitor device activity** - Web UI shows connected devices, boot history, and live logs

### How It Works

```
┌─────────────────┐
│  Raspberry Pi   │  1. Powers on, requests network boot (PXE)
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Netboot Server │  2. Serves bootloader, kernel, and root filesystem via TFTP/NFS
│   (Docker)      │  3. Auto-installs write-to-disk service on first boot
└────────┬────────┘  4. Enables remote image writing via Web UI
         │
         ▼
┌─────────────────┐
│    Web UI       │  5. Monitor devices, manage images, trigger writes
│ localhost:38434 │
└─────────────────┘
```

**Key Features:**
- **Dual DHCP Modes**: Proxy mode (works with existing DHCP) or full DHCP server
- **NFS Root Filesystem**: Pi boots from network-mounted rootfs
- **HTTP-Based Write**: Zero-dependency Python service writes images to SD/NVMe
- **Auto-Bootstrap**: Service installs automatically, no manual Pi configuration
- **Real-Time Progress**: Web UI shows live progress during image writes
- **Buildroot Compatible**: Works with minimal Linux environments 

---

## Prerequisites

### macOS

- **Docker Desktop** OR **Colima** (lightweight Docker alternative)
- **RAM**: 2GB minimum, 4GB recommended (8GB+ for multiple Pis or large images)
- **Disk**: 10GB+ free (for container + OS images)

**Installing Colima** (recommended for Mac):
```bash
brew install colima docker
colima start --cpu 4 --memory 4 --disk 50
```

### Linux

- **Docker** and **Docker Compose**
- **Host network access** (for DHCP/TFTP/NFS)
- **RAM**: 2GB minimum, 4GB recommended

**Installing Docker** (Ubuntu/Debian):
```bash
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
sudo usermod -aG docker $USER
# Log out and back in for group changes to take effect

# Install Docker Compose
sudo apt-get install docker-compose-plugin
```

### Network Requirements

- **Same LAN as Raspberry Pi** - Server must be on the same network segment
- **UDP ports open**: 67 (DHCP), 69 (TFTP)
- **TCP ports open**: 38434 (Web UI), 2049 (NFS)
- **Raspberry Pi with netboot enabled** - [Enable netboot on Pi](https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#network-boot-your-raspberry-pi)

---

## Quick Start

### 1. Clone and Configure

```bash
git clone <repository-url>
cd pi-netboot-server

# Set your server IP (must be reachable by Raspberry Pi)
export SERVER_IP=10.10.200.75  # Change to your IP
```

### 2. Prepare Root Filesystem

Place a Raspberry Pi OS image in the `images/` directory:

```bash
# Example: Download and extract Raspberry Pi OS
wget https://downloads.raspberrypi.org/raspios_lite_arm64/images/...
unzip raspios_lite_arm64.zip
mkdir -p images/my-image
mv 2024-01-01-raspios-bullseye-arm64-lite.img images/my-image/
```

**OR** mount a prepared rootfs:

```bash
# Mount existing rootfs directory
mkdir -p nfs/rootfs
# Copy or mount your rootfs here
```

### 3. Build and Run (Mac with Colima)

```bash
# Start Colima with host network
colima start --network-address --cpu 4 --memory 8

# Build and run
docker compose build
docker compose up -d

# Check logs
docker compose logs -f
```

### 4. Build and Run (Linux)

```bash
# Build and run
docker compose build
docker compose up -d

# Check logs
docker compose logs -f
```

### 5. Access Web UI

Open browser: **http://localhost:38434**

You should see:
- Network configuration settings
- Connected devices (once Pi boots)
- Image manager
- Live server logs

---

## Configuration

### Environment Variables

Set in Docker Compose or shell before running:

```bash
# Server IP (Required - must match your network interface)
export SERVER_IP=10.10.200.75

# DHCP Mode (Optional)
export DHCP_MODE=proxy       # or "full" for full DHCP server
export DHCP_RANGE_START=10.10.200.100
export DHCP_RANGE_END=10.10.200.200
```

### DHCP Modes

**Proxy Mode** (Default):
- Works alongside existing DHCP server
- Only provides PXE boot information
- Recommended for most networks

**Full DHCP Server Mode**:
- Provides IP addresses + PXE boot info
- Use when no DHCP server exists on network
- Configure IP range in Web UI

---

## Using Write-to-Disk

### Automatic Setup

1. **Pi boots via netboot** - Automatically downloads and installs write service
2. **Service runs on port 8888** - HTTP service for remote image writing
3. **Web UI shows "Write to Disk" button** - Click to write active image to SD/NVMe

### Manual Write Process

1. Access Web UI: http://localhost:38434
2. Under "Connected Devices", find your Pi
3. Click **"Write to Disk"**
4. Confirm device path (e.g., `/dev/mmcblk0`)
5. Click **"I Understand - Write Now"**
6. Watch progress modal (wiping → writing → syncing → complete)
7. Pi automatically reboots from written disk

### Progress Tracking

The write operation shows real-time progress:
- 🧹 **Wiping Partition Table** (0-10%)
- 📝 **Writing Image** (10-95%)
- 🔄 **Synchronizing** (95-100%)
- ✅ **Complete** - Pi reboots from local storage

---

## Architecture

### Components

```
pi-netboot-server/
├── docker/
│   ├── Dockerfile          # Multi-stage build (Debian slim + unfs3)
│   ├── entrypoint.sh       # Server startup + auto-bootstrap injection
│   └── configs/            # dnsmasq, NFS configs
├── webui/
│   ├── app.py              # Flask API + Web UI server
│   └── static/
│       └── index.html      # Single-page web interface
├── pi-service/
│   ├── netboot-imager-service.py   # HTTP write service (Python stdlib only)
│   ├── netboot-imager.service      # Systemd unit file
│   └── config.json                 # Service configuration template
├── images/                 # OS images directory
├── nfs/rootfs/            # NFS mount point for Pi
└── docker-compose.yml     # Container orchestration
```

### Services Running in Container

- **dnsmasq** - DHCP + TFTP server (ports 67/udp, 69/udp)
- **unfs3** - Userspace NFS server (port 2049)
- **Flask Web UI** - Management interface (port 38434)

### Auto-Bootstrap System

On first Pi boot:
1. `entrypoint.sh` injects `netboot-bootstrap.service` into NFS rootfs
2. Service runs on Pi boot, downloads installer from `/api/bootstrap/install-script`
3. Installer downloads Python service, config, and systemd unit
4. Service starts on port 8888, ready for write requests
5. On subsequent boots, service auto-updates (always downloads fresh files)

---

## Troubleshooting

### Pi Not Booting

**Check network connectivity:**
```bash
# View dnsmasq logs
docker exec pi-netboot-server tail -f /var/log/dnsmasq.log

# Check TFTP requests
docker exec pi-netboot-server tail -f /var/log/netboot/webui.log | grep TFTP
```

**Verify DHCP mode:**
- Check Web UI "Network Status" card
- Ensure DHCP mode matches your network (proxy vs full)

**Enable netboot on Pi:**
```bash
# On a working Pi with SD card:
sudo raspi-config
# Navigate to: Advanced Options → Boot Order → Network Boot
```

### Write-to-Disk Fails

**Service not installed:**
```bash
# On Pi (via SSH or console)
systemctl status netboot-imager

# If not running, check bootstrap logs
journalctl -u netboot-bootstrap -n 50
```

**Partition table errors:**
- Ensure Pi has latest service (reboots download fresh version)
- Check for stale partition table: `sudo partprobe /dev/mmcblk0`

**Network connectivity:**
```bash
# Test from Pi
curl http://<server-ip>:38434/api/bootstrap/install-script
```

### Container Issues (Mac)

**Colima network problems:**
```bash
# Restart with host network access
colima stop
colima start --network-address --cpu 4 --memory 8
```

**Port conflicts:**
```bash
# Check if ports are in use
lsof -i :38434
lsof -i :69
```

### Container Issues (Linux)

**Host network not working:**
```bash
# Verify host network mode
docker inspect pi-netboot-server | grep NetworkMode

# Should show "host"
```

**Permission denied on NFS:**
```bash
# Check NFS exports
docker exec pi-netboot-server cat /etc/exports

# Restart container
docker compose restart
```

---

## Advanced Usage

### Using Custom Images

Place your custom `.img` file in a subdirectory under `images/`:

```bash
mkdir -p images/custom-build
cp my-custom-image.img images/custom-build/
```

The Web UI will auto-detect and list it in the Image Manager.

### Persistent Boot History

Device boot history is stored in `/var/log/netboot/boot_history.json` inside the container. To persist across container restarts, mount a volume:

```yaml
# In docker-compose.yml
volumes:
  - ./data:/var/log/netboot
```

### Multiple Pi Deployment

The server supports multiple Pis simultaneously:
- Each Pi gets tracked in "Connected Devices"
- Write-to-disk works independently per device
- All Pis share the same NFS rootfs (read-only)

---

## Security Considerations

### Network Trust Model

This system assumes a **trusted local network** (e.g., home lab, private network). Security features:

- **IP Whitelist** - Write service only accepts requests from server IP + subnet
- **Shared Secret** - Token authentication (`openseastack-netboot-2024`)
- **Netboot-Only Service** - Service auto-removes when Pi boots from disk
- **No External Dependencies** - Reduces attack surface (stdlib-only Python)

### Production Recommendations

For production deployments:
1. **Isolate network** - Use dedicated VLAN for netboot
2. **Change shared secret** - Update in `pi-service/config.json` and `webui/app.py`
3. **Enable firewall** - Restrict access to ports 38434, 2049, 67, 69
4. **Use HTTPS** - Add reverse proxy (nginx) with SSL for Web UI
5. **Audit logs** - Monitor `/var/log/netboot/` for suspicious activity

---

## Development

### Building from Source

```bash
# Build container
docker compose build

# Run with live reload (dev mode)
docker compose up
```

### Modifying Pi Service

Edit `pi-service/netboot-imager-service.py`, then:
1. Restart container: `docker compose restart`
2. Reboot Pi (will download updated service automatically)

### Contributing

Contributions welcome! Please:
1. Fork the repository
2. Create feature branch
3. Test with real Raspberry Pi hardware
4. Submit pull request with detailed description

---

## FAQ

**Q: Which Raspberry Pi models are supported?**  
A: Pi 3B+, Pi 4, Pi 400, Pi Zero 2 W, Pi 5 (any model with network boot capability)

**Q: Can I use with WiFi?**  
A: No, netboot requires Ethernet connection. Once written to disk, WiFi works normally.

**Q: How large can images be?**  
A: Tested with 8.3GB images successfully. Limit is your disk space + network bandwidth.

**Q: Does it work with custom Linux distributions?**  
A: Yes, any ARM64 image that supports NFS root and systemd.

**Q: Can I use this in production?**  
A: It's designed for development/testing. For production, add additional security (VLAN, HTTPS, auth).

**Q: Why does progress modal get stuck?**  
A: If write completes very quickly, browser may not poll in time. Refresh browser and check LED - solid green = success!

**Q: Do I need to disable my existing DHCP server?**  
A: No! Use "Proxy Mode" (default) to work alongside existing DHCP.

---

## License

Apache License 2.0

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for version history and detailed changes.

## Acknowledgments

- Built with [dnsmasq](https://thekelleys.org.uk/dnsmasq/doc.html) for DHCP/TFTP
- Uses [unfs3](https://github.com/unfs3/unfs3) for userspace NFS
- Web UI powered by [Flask](https://flask.palletsprojects.com/)
- Inspired by the Raspberry Pi community's netboot work
