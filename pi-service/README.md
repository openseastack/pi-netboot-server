# Netboot Image Writer Service

This service runs on the Raspberry Pi to enable write-to-disk functionality from the netboot server.

## Features

- HTTP service listens on port 8888
- IP whitelist for security (only accepts requests from netboot server)
- Shared secret token authentication
- Downloads image from netboot server and writes to local disk
- Supports both compressed (.img.gz) and uncompressed (.img) images

## Installation

### 1. Copy files to Pi

```bash
# On netboot server, copy to Pi
scp pi-service/* pi@<pi-ip>:/tmp/
```

### 2. Install on Pi

```bash
# SSH into Pi
ssh pi@<pi-ip>

# Create service directory
sudo mkdir -p /opt/netboot-imager
sudo cp /tmp/netboot-imager-service.py /opt/netboot-imager/
sudo cp /tmp/config.json /opt/netboot-imager/
sudo chmod +x /opt/netboot-imager/netboot-imager-service.py

# Install systemd service
sudo cp /tmp/netboot-imager.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable netboot-imager
sudo systemctl start netboot-imager
```

### 3. Verify service is running

```bash
sudo systemctl status netboot-imager

# Test health endpoint
curl http://localhost:8888/health
# Should return: {"service":"netboot-imager","status":"ok"}
```

## Configuration

Edit `/opt/netboot-imager/config.json` to customize:

```json
{
  "allowed_ips": [
    "10.10.200.75",      # Specific netboot server IP
    "10.10.200.0/24"     # Or entire subnet
  ],
  "shared_secret": "openseastack-netboot-2024",
  "port": 8888
}
```

**Important**: The `shared_secret` must match the value in the netboot server's `webui/app.py`.

After changing config:
```bash
sudo systemctl restart netboot-imager
```

## Security

- **IP Whitelist**: Only configured IPs can access the service
- **Shared Secret**: Requests must include `X-Netboot-Token` header
- **Root Required**: Service runs as root to write to disk devices
- **Trusted Network**: Assumes local network is secure (no HTTPS)

## Usage

Once installed, you can use the "Write to Disk" button in the netboot Web UI. The service will:

1. Receive write request from netboot server
2. Validate IP and token
3. Download image from server
4. Write to specified device (`/dev/mmcblk0` or `/dev/nvme0n1`)
5. Sync filesystems
6. Return success/error response

## Troubleshooting

### Service won't start
```bash
# Check logs
sudo journalctl -u netboot-imager -f

# Check Python dependencies
python3 -c "import flask, requests"
```

### Write fails
```bash
# Check permissions
ls -l /dev/mmcblk0

# Test manual write
curl -X POST http://localhost:8888/write-image \
  -H "X-Netboot-Token: openseastack-netboot-2024" \
  -H "Content-Type: application/json" \
  -d '{
    "device": "/dev/mmcblk0",
    "image_url": "http://10.10.200.75:38434/api/images/download/test-image",
    "netboot_ip": "10.10.200.75"
  }'
```

### Can't connect from netboot server
```bash
# Check firewall
sudo ufw status
sudo ufw allow 8888/tcp  # If needed

# Verify service is listening
sudo netstat -tlnp | grep 8888
```

## Dependencies

- Python 3
- Flask (`pip3 install flask`)
- requests (`pip3 install requests`)
- curl (for downloading images)
- dd (standard on Linux)

## Integration with Image

To include this service in your custom Pi image, add to your build process:

1. Copy files to `/opt/netboot-imager/`
2. Install systemd unit
3. Enable service: `systemctl enable netboot-imager`
4. Ensure Flask and requests are installed
