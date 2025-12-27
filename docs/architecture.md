# Architecture

Technical deep-dive into rpi-netboot-dev.

## Components

### 1. ProxyDHCP (dnsmasq)

The Pi needs two things to netboot:
1. **IP Address** — provided by your existing router
2. **Boot server location** — provided by our ProxyDHCP

ProxyDHCP listens for DHCP requests but only responds with PXE boot information, letting your router handle IP assignment. This means no network reconfiguration required.

**MAC OUI Detection**: Only responds to Raspberry Pi devices:
- `b8:27:eb:*` — Pi 3 and earlier
- `dc:a6:32:*` — Pi 4
- `d8:3a:dd:*` — Pi 5

### 2. TFTP Server

Serves the initial boot files:
- `bootcode.bin` — First-stage bootloader (Pi 3)
- `start4.elf` — GPU firmware (Pi 4/5)
- `kernel8.img` / `Image` — Linux kernel
- `*.dtb` — Device tree blobs
- `cmdline.txt` — Boot parameters (points to NFS root)

### 3. NFS Server

Exports the root filesystem (`/nfs/rootfs`) to the Pi. The Pi mounts this as its root (`/`) via:

```
root=/dev/nfs nfsroot=<server_ip>:/nfs/rootfs,vers=3 rw ip=dhcp
```

## macOS/Colima Considerations

### Problem: Nested Virtualization

```
Mac → Colima VM → Docker Container → NFS
```

Standard `--net=host` in Docker only binds to the Colima VM, not your Mac's physical network.

### Solution: Bridged Networking

```bash
colima start --network-address
```

This gives the Colima VM a real IP on your LAN (e.g., `192.168.1.50`), making the container reachable by the Pi.

### Problem: NFS Re-Export

You cannot NFS-export a virtiofs mount (Mac → Colima). The NFS server requires a native Linux filesystem.

### Solution: Docker Volumes

```yaml
volumes:
  rpi-rootfs:  # Stored inside Colima VM's disk
```

Use `sync-rootfs.sh` to copy files into this volume.

## Network Flow

```
1. Pi powers on, sends DHCP DISCOVER
2. Router responds with IP (DHCP OFFER)
3. Our ProxyDHCP responds with TFTP server IP
4. Pi downloads bootcode.bin, start4.elf via TFTP
5. Pi downloads kernel, DTB, cmdline.txt via TFTP
6. Pi mounts NFS root, boots Linux
7. Developer SSHs in or uses console
```

## File Layout

### On Server (Docker)

```
/tftpboot/              # TFTP root
├── bootcode.bin
├── start4.elf
├── fixup4.dat
├── kernel8.img
├── bcm2711-rpi-4-b.dtb
├── cmdline.txt         # Points to NFS root
└── config.txt

/nfs/rootfs/            # NFS root (Docker volume)
├── bin/
├── etc/
├── lib/
├── usr/
└── ...
```

### On Pi (at runtime)

```
/                       # NFS mounted from server
├── home/
│   └── scripts/
│       └── commit-to-drive.sh
└── ...
```

## Security Notes

- NFS uses `no_root_squash` for development (root on Pi = root on NFS)
- Not suitable for production — development use only
- Consider adding SSH key authentication for Pi access
