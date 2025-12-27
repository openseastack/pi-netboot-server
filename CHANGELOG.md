# pi-netboot-server Changelog

All notable changes to this project.

---

## [0.2.0] - 2025-12-26

### Changed
- **Container Base Image**: Migrated from Ubuntu 22.04 to Debian stable-slim
  - Image size reduced from 755MB to 294MB (61% reduction)
  - Multi-stage build for optimal size
  - Maintains unfs3 (userspace NFS) for Mac/Colima compatibility
  - Better glibc support compared to musl-based alternatives
- **UI Layout Optimization**: Completely redesigned Web UI with improved space utilization
  - Implemented fixed 2-column grid layout for consistent alignment
  - Row 1: Network Configuration | Network Status (50/50 split)
  - Row 2: Connected Devices (full-width for optimal table visibility)
  - Row 3: Image Manager | Setup & Troubleshooting (50/50 split)  
  - Row 4: Live Server Logs (full-width, collapsible by default, stacked vertically when expanded)
  - All rows now aligned to same width for clean, professional appearance
- **Write-to-Disk Architecture**: Complete rewrite from SSH to HTTP-based approach
  - Replaced SSH/paramiko dependency with HTTP service (port 8888) on Pi
  - **Zero-dependency Python service** using only stdlib (http.server) - works on Buildroot without pip3
  - IP whitelist + shared secret token (openseastack-netboot-2024) for security
  - **Auto-bootstrap system**: Service auto-installs during netboot, never persists to written disk
  - **Always downloads fresh service files** on every boot to ensure updates propagate automatically
  - **Automatic partition table wiping** before image write to handle existing OS installations
  - **Kernel partition table refresh** (partprobe/blockdev) to prevent stale partition errors
  - Supports both compressed (.img.gz) and uncompressed (.img) images
  - POSIX sh compatible for BusyBox/Buildroot environments
  - Service only runs during netboot (NFS root), eliminates SSH security concerns
  - **Real-time progress tracking**: Backend tracks wipe/write/sync stages with percentage
  - **Progress modal**: Web UI shows live progress with stage indicators (wiping 0-10%, writing 10-95%, syncing 95-100%)
  - **Status proxy endpoint**: `/api/devices/<ip>/status` proxies Pi status to avoid CORS issues

### Added
- **Network Status Card**: Dedicated real-time status dashboard
  - Current DHCP mode display
  - DHCP server detection with IP address
  - Latest Boot Device card showing IP, MAC, image name, and boot time
- **Auto-Bootstrap System**: Zero-configuration Pi service installation
  - `/api/bootstrap/imager-service` - Serves Python service script
  - `/api/bootstrap/imager-config` - Auto-configured settings with server IP
  - `/api/bootstrap/imager-unit` - Systemd unit file
  - `/api/bootstrap/install-script` - Smart installation script with auto-update
  - **Always downloads fresh service files** on every boot to ensure updates propagate
  - Automatically restarts service to pick up new code
  - Service only runs during netboot (NFS root)
- **Image Download Endpoint**: `/api/images/download/<image_name>`
  - Serves .img or .img.gz files to Pi during write operations
  - Supports compressed and uncompressed images
- **Enhanced Device Tracking**: Connected Devices now shows comprehensive boot information
  - MAC address display for all detected devices
  - Last boot time with relative formatting (e.g., "5 min ago")
  - Boot count tracking across reboots
  - Active image name displayed for each device
  - Status indicator (green for recently booted, gray for inactive)
  - Auto-refresh every 10 seconds
  - Boot history persistence via JSON storage
  - IP address detection from TFTP transfers for proxy mode deployments
- **Boot Event Parsing**: Automatic parsing of dnsmasq logs for PXE boot events
  - Correlates TFTP transfers with boot events to capture device IPs
- **Pi Service Templates**: Complete service implementation in `pi-service/` directory
  - `netboot-imager-service.py` - HTTP service with IP whitelist and token auth
  - `netboot-imager.service` - Systemd unit file
  - `config.json` - Configuration template
  - `first-boot.sh` - NFS-aware bootstrap script
  - `README.md` - Installation and usage documentation
- **Alternative Dockerfiles**: Created Alpine (193MB) and Ubuntu backup options
  
### Fixed
- **Image Manager Display**: Now correctly detects and displays directly mounted rootfs at `/nfs/rootfs`
  - Shows "openseastack-direct-mount" when using bind mount setup
  - Displays as active image with correct size calculation
- **DHCP Status Display**: Fixed "Loading..." bug by adding proper initialization and auto-refresh
  - Status now updates correctly showing DHCP server detection
  - Auto-refreshes every 15 seconds
- **Live Server Logs Layout**: Fixed horizontal overflow by stacking logs vertically
  - All three log sections (DHCP/TFTP, NFS, Web UI) visible when expanded
- **Write to Disk**: Complete rewrite for reliability and security
  - Now uses HTTP service instead of SSH (no authentication issues)
  - Works with direct mount and symlink image setups
  - Clear error messages for missing service or images

### Removed
- **SSH/Paramiko Dependency**: No longer needed for write-to-disk functionality

---

## [0.1.0] - 2025-12-24

### Added
- Initial project structure
- `README.md` with quick start guide and architecture diagram
- `docs/architecture.md` with technical deep-dive
- `docker/Dockerfile` - Ubuntu 22.04 with dnsmasq, NFS, rpcbind
- `docker/entrypoint.sh` - Service startup with DHCP mode selection
- `docker-compose.yml` - Named volumes, privileged mode, host network
- `run.sh` - Main CLI (start/stop/logs/status) with DHCP auto-detect
- `scripts/sync-rootfs.sh` - Sync Buildroot output to Docker volumes
- SSH key injection via `--ssh-key` flag or `keys/` directory
- `keys/README.md` - SSH key configuration instructions
- DHCP mode options: auto, proxy, full
- macOS/Colima support with bridged networking
- RPi MAC OUI detection (Pi 3/4/5)
- `docs/linux-setup.md` - Native Docker on Linux guide
- `docs/macos-setup.md` - Colima configuration guide

### Fixed
- **NFS Server Crash (Docker/Colima):** Replaced `nfs-kernel-server` with `unfs3` (User Space NFS) built from source. Resolves kernel module incompatibility on Colima/Mac.
- **Boot Config Overwrite:** `sync-rootfs.sh` now excludes `cmdline.txt` to prevent overwriting the netboot config with the SD card's config (which caused boot hangs). `entrypoint.sh` now strictly enforces NFS root generation.
- **Exports Compatibility:** Simplified `/etc/exports` to `(rw,no_root_squash)` for `unfs3` compatibility.

### Phase 2: Helper Scripts
- `scripts/bootstrap-eeprom.sh` - Create EEPROM update SD for netboot
- `scripts/commit-to-drive.sh` - Flash netboot image to NVMe/SD on Pi
