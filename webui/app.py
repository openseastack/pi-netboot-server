"""
pi-netboot-server Web UI Backend
Flask API for managing netboot images and connected devices
"""

from flask import Flask, jsonify, request, send_from_directory, send_file
from flask_cors import CORS
import requests
import subprocess
import os
import json
from pathlib import Path
from datetime import datetime
import re

app = Flask(__name__, static_folder='static')
CORS(app)

# Configuration
IMAGES_DIR = Path('/images')
ACTIVE_LINK = IMAGES_DIR / 'active-rootfs'
GITHUB_REPO = 'openseastack/openseastack'  # Update with actual repo

# ============================================================================
# GitHub Release Management
# ============================================================================

@app.route('/api/releases/latest', methods=['GET'])
def get_latest_release():
    """Fetch latest GitHub release info"""
    try:
        url = f'https://api.github.com/repos/{GITHUB_REPO}/releases/latest'
        response = requests.get(url, timeout=10)
        response.raise_for_status()
        
        release = response.json()
        
        # Find .img.gz asset
        img_asset = next(
            (a for a in release['assets'] if a['name'].endswith('.img.gz')),
            None
        )
        
        return jsonify({
            'version': release['tag_name'],
            'name': release['name'],
            'published_at': release['published_at'],
            'changelog': release['body'],
            'download_url': img_asset['browser_download_url'] if img_asset else None,
            'size_mb': round(img_asset['size'] / 1024 / 1024, 1) if img_asset else 0
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500


        
        # Download file
        img_path = version_dir / 'image.img.gz'
        
        response = requests.get(url, stream=True, timeout=30)
        response.raise_for_status()
        
        total_size = int(response.headers.get('content-length', 0))
        downloaded = 0
        
        with open(img_path, 'wb') as f:
            for chunk in response.iter_content(chunk_size=8192):
                if chunk:
                    f.write(chunk)
                    downloaded += len(chunk)
                    # TODO: Emit progress events via SSE or WebSocket
        
        # Extract image
        subprocess.run(['gunzip', str(img_path)], check=True)
        
        # Mount and extract rootfs
        extract_rootfs(version_dir / 'image.img', version_dir / 'rootfs-raw')
        
        return jsonify({'success': True, 'version': version})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/images/upload', methods=['POST'])
def upload_image():
    """Upload image file from browser"""
    if 'file' not in request.files:
        return jsonify({'error': 'No file provided'}), 400
    
    file = request.files['file']
    
    if file.filename == '':
        return jsonify({'error': 'No file selected'}), 400
    
    try:
        # Generate version name from filename
        filename = file.filename
        if filename.endswith('.img.gz'):
            version_name = filename.replace('.img.gz', '')
        elif filename.endswith('.img'):
            version_name = filename.replace('.img', '')
        elif filename.endswith('.tar.gz'):
            version_name = filename.replace('.tar.gz', '')
        else:
            version_name = filename
        
        # Create version directory
        version_dir = IMAGES_DIR / version_name
        version_dir.mkdir(parents=True, exist_ok=True)
        
        # Save uploaded file
        saved_path = version_dir / filename
        file.save(str(saved_path))
        
        # If it's compressed, extract it
        if filename.endswith('.gz'):
            subprocess.run(['gunzip', str(saved_path)], check=True)
            img_path = version_dir / filename.replace('.gz', '')
        else:
            img_path = saved_path
        
        # Extract rootfs if it's an image file
        if img_path.suffix == '.img':
            extract_rootfs(img_path, version_dir / 'rootfs-raw')
        elif img_path.suffix == '.tar':
            # Extract tar directly to rootfs-raw
            subprocess.run(['tar', '-xf', str(img_path), '-C', str(version_dir)], check=True)
            # Rename to rootfs-raw if needed
            if not (version_dir / 'rootfs-raw').exists():
                # Find extracted directory
                extracted = next(version_dir.iterdir(), None)
                if extracted and extracted.is_dir():
                    extracted.rename(version_dir / 'rootfs-raw')
        
        return jsonify({'success': True, 'name': version_name})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/images/import', methods=['POST'])
def import_local_image():
    """Import image from local path"""
    data = request.json
    source_path = data.get('path')
    
    if not source_path or not os.path.exists(source_path):
        return jsonify({'error': 'Invalid path'}), 400
    
    try:
        # Detect if it's a directory (rootfs-raw) or image file
        source = Path(source_path)
        
        if source.is_dir():
            # Copy directory
            import_name = source.name
            dest_dir = IMAGES_DIR / import_name
            subprocess.run(['cp', '-r', str(source), str(dest_dir)], check=True)
        else:
            # Copy and extract image
            import_name = source.stem.replace('.img', '')
            dest_dir = IMAGES_DIR / import_name
            dest_dir.mkdir(parents=True, exist_ok=True)
            
            subprocess.run(['cp', str(source), str(dest_dir / 'image.img')], check=True)
            extract_rootfs(dest_dir / 'image.img', dest_dir / 'rootfs-raw')
        
        return jsonify({'success': True, 'name': import_name})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/images/list', methods=['GET'])
def list_images():
    """List all imported images"""
    images = []
    
    # Check for images in /images directory
    if IMAGES_DIR.exists():
        for item in IMAGES_DIR.iterdir():
            if item.is_dir() and item.name != 'active-rootfs':
                is_active = ACTIVE_LINK.exists() and ACTIVE_LINK.resolve() == (item / 'rootfs-raw').resolve()
                
                images.append({
                    'name': item.name,
                    'active': is_active,
                    'size_mb': get_dir_size(item)
                })
    
    # Also check for direct mount at /nfs/rootfs (common setup)
    direct_rootfs = Path('/nfs/rootfs')
    if direct_rootfs.exists() and direct_rootfs.is_dir():
        # Check if this is a real directory (not empty) and not already listed
        try:
            # Check if it has typical rootfs contents
            if list(direct_rootfs.iterdir()):
                # Determine a name for this image
                image_name = 'openseastack-direct-mount'
                
                # Check if this is already in the list
                if not any(img['name'] == image_name for img in images):
                    images.append({
                        'name': image_name,
                        'active': True,  # Direct mount is always active
                        'size_mb': get_dir_size(direct_rootfs)
                    })
        except:
            pass
    
    return jsonify({'images': images})


@app.route('/api/images/activate', methods=['POST'])
def activate_image():
    """Set active image (symlink)"""
    data = request.json
    image_name = data.get('name')
    
    if not image_name:
        return jsonify({'error': 'Missing name'}), 400
    
    target = IMAGES_DIR / image_name / 'rootfs-raw'
    
    if not target.exists():
        return jsonify({'error': 'Image not found'}), 404
    
    try:
        # Remove old symlink
        if ACTIVE_LINK.exists() or ACTIVE_LINK.is_symlink():
            ACTIVE_LINK.unlink()
        
        # Create new symlink
        ACTIVE_LINK.symlink_to(target)
        
        return jsonify({'success': True})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


# ============================================================================
# Device Management
# ============================================================================

BOOT_HISTORY_FILE = '/tmp/boot-history.json'


def load_boot_history():
    """Load boot history from JSON file"""
    if os.path.exists(BOOT_HISTORY_FILE):
        try:
            with open(BOOT_HISTORY_FILE, 'r') as f:
                return json.load(f)
        except:
            return {}
    return {}


def save_boot_history(history):
    """Save boot history to JSON file"""
    try:
        with open(BOOT_HISTORY_FILE, 'w') as f:
            json.dump(history, f, indent=2)
    except Exception as e:
        print(f"Error saving boot history: {e}")


def parse_boot_events():
    """Parse dnsmasq logs for PXE boot events and update boot history"""
    log_file = '/var/log/netboot/dnsmasq.log'
    
    if not os.path.exists(log_file):
        return
    
    history = load_boot_history()
    
    try:
        # Read last 500 lines to capture recent boot events
        result = subprocess.run(['tail', '-n', '500', log_file], 
                              capture_output=True, text=True, timeout=5)
        
        lines = result.stdout.split('\n')
        
        # Parse PXE boot events and TFTP transfers
        # PXE format: "Dec 24 23:52:53 dnsmasq-dhcp[34]: 3274722395 PXE(col0) 2c:cf:67:7c:d4:67 proxy"
        pxe_pattern = re.compile(r'(\w+ \d+ \d+:\d+:\d+).*PXE\([^)]+\)\s+([0-9a-f:]+)\s+proxy')
        # TFTP format: "Dec 26 17:39:48 dnsmasq-tftp[26]: sent /tftpboot/start4.elf to 10.10.200.180"
        tftp_pattern = re.compile(r'(\w+ \d+ \d+:\d+:\d+).*sent .* to ([0-9.]+)')
        
        # Build a time-ordered list of events
        boot_events = []
        tftp_transfers = []
        
        for line in lines:
            # Match PXE boot events
            pxe_match = pxe_pattern.search(line)
            if pxe_match:
                timestamp_str = pxe_match.group(1)
                mac = pxe_match.group(2).lower()
                
                # Parse timestamp
                try:
                    current_year = datetime.now().year
                    timestamp = datetime.strptime(f"{current_year} {timestamp_str}", "%Y %b %d %H:%M:%S")
                except:
                    timestamp = datetime.now()
                
                boot_events.append({
                    'time': timestamp,
                    'mac': mac
                })
            
            # Match TFTP transfers (these come after PXE and contain the IP)
            tftp_match = tftp_pattern.search(line)
            if tftp_match:
                timestamp_str = tftp_match.group(1)
                ip = tftp_match.group(2)
                
                try:
                    current_year = datetime.now().year
                    timestamp = datetime.strptime(f"{current_year} {timestamp_str}", "%Y %b %d %H:%M:%S")
                except:
                    timestamp = datetime.now()
                
                tftp_transfers.append({
                    'time': timestamp,
                    'ip': ip
                })
        
        # Correlate PXE boots with TFTP transfers
        # TFTP transfers happen within ~30 seconds after PXE boot
        for boot in boot_events:
            mac = boot['mac']
            boot_time = boot['time']
            
            # Find TFTP transfers within 30 seconds after this boot
            matching_ip = None
            for tftp in tftp_transfers:
                time_diff = (tftp['time'] - boot_time).total_seconds()
                if 0 <= time_diff <= 30:
                    matching_ip = tftp['ip']
                    break
            
            # Update or create boot history entry
            timestamp_iso = boot_time.isoformat()
            if mac not in history:
                history[mac] = {
                    'mac': mac,
                    'last_boot': timestamp_iso,
                    'boot_count': 1,
                    'last_ip': matching_ip
                }
            else:
                # Only count as new boot if it's been more than 2 minutes since last boot
                try:
                    last_boot = datetime.fromisoformat(history[mac]['last_boot'])
                    if (boot_time - last_boot).total_seconds() > 120:
                        history[mac]['boot_count'] += 1
                        history[mac]['last_boot'] = timestamp_iso
                        if matching_ip:
                            history[mac]['last_ip'] = matching_ip
                except:
                    history[mac]['last_boot'] = timestamp_iso
                    if matching_ip:
                        history[mac]['last_ip'] = matching_ip
        
        save_boot_history(history)
    except Exception as e:
        print(f"Error parsing boot events: {e}")


def get_active_image_name():
    """Get the name of the currently active image"""
    try:
        # First check if active-rootfs symlink exists in /images
        if ACTIVE_LINK.exists() and ACTIVE_LINK.is_symlink():
            target = ACTIVE_LINK.resolve()
            image_dir = target.parent
            return image_dir.name
        
        # If not, check if we're using a direct mount at /nfs/rootfs
        direct_rootfs = Path('/nfs/rootfs')
        if direct_rootfs.exists() and direct_rootfs.is_dir():
            # Check if it has content (not empty)
            if list(direct_rootfs.iterdir()):
                return 'openseastack-direct-mount'
    except Exception as e:
        print(f"Error detecting active image: {e}")
    
    return None

@app.route('/api/devices', methods=['GET'])
def list_devices():
    """List connected Pis with boot history and active image info"""
    try:
        # Update boot history from logs
        parse_boot_events()
        
        # Load boot history
        boot_history = load_boot_history()
        
        # Get active image name
        active_image = get_active_image_name()
        
        # Try multiple possible lease file locations
        possible_paths = [
            '/var/lib/misc/dnsmasq.leases',
            '/var/lib/dnsmasq/dnsmasq.leases',
            '/tmp/dnsmasq.leases'
        ]
        
        leases_file = None
        for path in possible_paths:
            if os.path.exists(path):
                leases_file = path
                break
        
        # Build device list from leases
        devices = []
        
        if leases_file and os.path.exists(leases_file):
            with open(leases_file, 'r') as f:
                for line in f:
                    parts = line.strip().split()
                    if len(parts) >= 4:
                        mac = parts[1].lower()
                        device = {
                            'ip': parts[2],
                            'mac': mac,
                            'hostname': parts[3] if len(parts) > 3 else 'unknown'
                        }
                        
                        # Merge boot history if available
                        if mac in boot_history:
                            device['last_boot'] = boot_history[mac].get('last_boot')
                            device['boot_count'] = boot_history[mac].get('boot_count', 0)
                        else:
                            device['last_boot'] = None
                            device['boot_count'] = 0
                        
                        # Add active image
                        device['image'] = active_image
                        
                        devices.append(device)
        
        # Also include devices from boot history that may not have current leases
        for mac, boot_data in boot_history.items():
            # Check if this MAC is already in devices list
            if not any(d['mac'] == mac for d in devices):
                devices.append({
                    'ip': boot_data.get('last_ip', 'unknown'),
                    'mac': mac,
                    'hostname': 'unknown',
                    'last_boot': boot_data.get('last_boot'),
                    'boot_count': boot_data.get('boot_count', 0),
                    'image': active_image
                })
        
        return jsonify({'devices': devices})
    except Exception as e:
        return jsonify({'error': str(e), 'devices': []}), 500


@app.route('/api/logs', methods=['GET'])
def get_logs():
    """Get recent logs from all services"""
    try:
        logs = {}
        log_files = {
            'dnsmasq': '/var/log/netboot/dnsmasq.log',
            'unfsd': '/var/log/netboot/unfsd.log',
            'webui': '/var/log/netboot/webui.log'
        }
        
        for service, log_path in log_files.items():
            if os.path.exists(log_path):
                try:
                    # Get last 50 lines
                    result = subprocess.run(['tail', '-n', '50', log_path], 
                                          capture_output=True, text=True, timeout=5)
                    logs[service] = result.stdout
                except:
                    logs[service] = f"Error reading {log_path}"
            else:
                logs[service] = f"Log file not found: {log_path}"
        
        return jsonify({'logs': logs})
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/devices/<ip>/write-disk', methods=['POST'])
def write_to_disk(ip):
    """Write active image to Pi's local disk via HTTP service"""
    data = request.json
    device = data.get('device', '/dev/mmcblk0')  # or /dev/nvme0n1
    
    # Check for active image - either via symlink or direct mount
    img_file = None
    image_name = None
    
    if ACTIVE_LINK.exists():
        # Symlink exists - find .img in the linked directory
        active_dir = ACTIVE_LINK.resolve().parent
        img_file = next(active_dir.glob('*.img'), None)
        if img_file:
            image_name = active_dir.name
    else:
        # No symlink - check /images directory for any .img files
        for img_dir in IMAGES_DIR.iterdir():
            if img_dir.is_dir():
                potential_img = next(img_dir.glob('*.img'), None)
                if potential_img:
                    img_file = potential_img
                    image_name = img_dir.name
                    break
    
    if not img_file or not img_file.exists():
        return jsonify({'error': 'No active image found. Please import and activate an image first.'}), 400
    
    try:
        # Get server IP from environment or config
        server_ip = os.getenv('SERVER_IP', '10.10.200.75')
        
        # Build image download URL
        image_url = f'http://{server_ip}:38434/api/images/download/{image_name}'
        
        # Shared secret for authentication
        shared_secret = 'openseastack-netboot-2024'
        
        # Send request to Pi's HTTP service
        pi_service_url = f'http://{ip}:8888/write-image'
        
        response = requests.post(
            pi_service_url,
            json={
                'device': device,
                'image_url': image_url,
                'netboot_ip': server_ip
            },
            headers={
                'X-Netboot-Token': shared_secret
            },
            timeout=300  # 5 minute timeout for large images
        )
        
        if response.status_code == 200:
            return jsonify(response.json())
        else:
            error_msg = response.json().get('error', 'Unknown error')
            return jsonify({'error': f'Pi service error: {error_msg}'}), response.status_code
            
    except requests.exceptions.ConnectionError:
        return jsonify({'error': 'Cannot connect to Pi service. Ensure the netboot-imager service is running on the Pi.'}), 503
    except requests.exceptions.Timeout:
        return jsonify({'error': 'Write operation timed out after 5 minutes'}), 504
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/devices/<ip>/status', methods=['GET'])
def get_device_status(ip):
    """Proxy status requests to Pi to avoid CORS issues"""
    try:
        # Poll Pi's status endpoint
        response = requests.get(f'http://{ip}:8888/status', timeout=2)
        return jsonify(response.json())
    except requests.RequestException as e:
        # Pi might be offline or rebooting
        return jsonify({
            'stage': 'idle',
            'percent': 0,
            'message': 'Device offline or not responding',
            'error': None
        })


@app.route('/api/images/download/<image_name>')
def download_image(image_name):
    """Serve image file for Pi to download during write operation"""
    try:
        # Find the image directory
        image_dir = IMAGES_DIR / image_name
        
        if not image_dir.exists():
            return jsonify({'error': 'Image not found'}), 404
        
        # Find .img or .img.gz file
        img_file = next(image_dir.glob('*.img'), None)
        img_gz_file = next(image_dir.glob('*.img.gz'), None)
        
        if img_gz_file:
            # Serve compressed image (Pi will decompress)
            return send_file(
                img_gz_file,
                mimetype='application/gzip',
                as_attachment=True,
                download_name=img_gz_file.name
            )
        elif img_file:
            # Serve uncompressed image
            return send_file(
                img_file,
                mimetype='application/octet-stream',
                as_attachment=True,
                download_name=img_file.name
            )
        else:
            return jsonify({'error': 'Image file (.img or .img.gz) not found'}), 404
            
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/bootstrap/imager-service')
def bootstrap_imager_service():
    """Serve netboot-imager service script for Pi auto-installation"""
    service_file = Path(__file__).parent.parent / 'pi-service' / 'netboot-imager-service.py'
    if service_file.exists():
        return send_file(service_file, mimetype='text/x-python')
    return jsonify({'error': 'Service file not found'}), 404


@app.route('/api/bootstrap/imager-config')
def bootstrap_imager_config():
    """Serve auto-configured config.json with detected server IP"""
    server_ip = os.getenv('SERVER_IP', '10.10.200.75')
    
    config = {
        'allowed_ips': [server_ip, f"{'.'.join(server_ip.split('.')[:3])}.0/24"],
        'shared_secret': 'openseastack-netboot-2024',
        'port': 8888
    }
    
    return jsonify(config)


@app.route('/api/bootstrap/imager-unit')
def bootstrap_imager_unit():
    """Serve systemd unit file"""
    unit_file = Path(__file__).parent.parent / 'pi-service' / 'netboot-imager.service'
    if unit_file.exists():
        return send_file(unit_file, mimetype='text/plain')
    return jsonify({'error': 'Unit file not found'}), 404


@app.route('/api/bootstrap/install-script')
def bootstrap_install_script():
    """Serve installation script for Pi (POSIX sh compatible for Buildroot)"""
    server_ip = os.getenv('SERVER_IP', '10.10.200.75')
    
    script = f'''#!/bin/sh
# Netboot Image Writer - Auto-Install Script
# POSIX sh compatible for Buildroot/BusyBox
# Always downloads fresh files to ensure updates propagate

echo "Installing/updating netboot-imager service..."

# Create directory
mkdir -p /opt/netboot-imager

# Always download fresh service files from netboot server
echo "Downloading service script..."
if ! curl -f http://{server_ip}:38434/api/bootstrap/imager-service -o /opt/netboot-imager/netboot-imager-service.py; then
    echo "ERROR: Failed to download service script"
    exit 1
fi

echo "Downloading config..."
if ! curl -f http://{server_ip}:38434/api/bootstrap/imager-config -o /opt/netboot-imager/config.json; then
    echo "ERROR: Failed to download config"
    exit 1
fi

echo "Downloading systemd unit..."
if ! curl -f http://{server_ip}:38434/api/bootstrap/imager-unit -o /etc/systemd/system/netboot-imager.service; then
    echo "ERROR: Failed to download systemd unit"
    exit 1
fi

# Set permissions  
chmod +x /opt/netboot-imager/netboot-imager-service.py

# Enable and start service (restart if already running to pick up updates)
systemctl daemon-reload
systemctl enable netboot-imager 2>/dev/null || true
systemctl restart netboot-imager

echo "Netboot imager service installed/updated"
'''
    
    return script, 200, {'Content-Type': 'text/x-shellscript'}

@app.route('/api/network/status', methods=['GET'])
def network_status():
    """Get current network status"""
    try:
        current_mode = os.environ.get('DHCP_MODE', 'proxy')
        
        # Get server IP and subnet by reading dnsmasq log
        result = subprocess.run(['tail', '-5', '/var/log/netboot/dnsmasq.log'], 
                              capture_output=True, text=True, timeout=5)
        
        subnet = None
        for line in result.stdout.split('\n'):
            if 'proxy on subnet' in line or 'DHCP, IP range' in line:
                # Extract subnet from log line
                parts = line.split('subnet')
                if len(parts) > 1:
                    subnet = parts[1].strip().split()[0]
                break
        
        # Get server IP from environment or detect
        server_ip = os.environ.get('SERVER_IP')
        if not server_ip:
            ip_result = subprocess.run(['hostname', '-I'], 
                                      capture_output=True, text=True, timeout=5)
            ips = ip_result.stdout.strip().split()
            # Prefer 10.10.200.x
            server_ip = next((ip for ip in ips if ip.startswith('10.10.200.')), 
                           next((ip for ip in ips if ip.startswith('10.')),  
                           ips[0] if ips else 'unknown'))
        
        return jsonify({
            'mode': current_mode,
            'server_ip': server_ip,
            'subnet': subnet or 'detecting...'
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@app.route('/api/network/interfaces', methods=['GET'])
def list_interfaces():
    """List available network interfaces with IPs"""
    try:
        result = subprocess.run(['ip', '-j', 'addr', 'show'], 
                              capture_output=True, text=True, timeout=5)
        
        if result.returncode != 0:
            return jsonify({'interfaces': []}), 500
        
        data = json.loads(result.stdout)
        interfaces = []
        
        for iface in data:
            if iface['operstate'] != 'UP':
                continue
            
            # Get IPv4 address
            ipv4 = None
            for addr_info in iface.get('addr_info', []):
                if addr_info['family'] == 'inet' and not addr_info['local'].startswith('127.'):
                    ipv4 = addr_info['local']
                    break
            
            if ipv4:
                interfaces.append({
                    'name': iface['ifname'],
                    'ip': ipv4
                })
        
        return jsonify({'interfaces': interfaces})
    except Exception as e:
        return jsonify({'error': str(e), 'interfaces': []}), 500


@app.route('/api/network/mode', methods=['POST'])
def set_dhcp_mode():
    """Switch DHCP mode (requires container restart)"""
    data = request.json
    mode = data.get('mode', 'proxy')
    
    if mode not in ['proxy', 'full']:
        return jsonify({'error': 'Invalid mode'}), 400
    
    try:
        # Write config to file that entrypoint can read on restart
        config_file = Path('/tmp/dhcp-mode.conf')
        config = {
            'mode': mode,
            'interface': data.get('interface'),
            'range': data.get('range')
        }
        config_file.write_text(json.dumps(config))
        
        # Return success with restart instruction
        return jsonify({
            'success': True,
            'message': 'Settings saved. Restart container to apply changes.',
            'requires_restart': True
        })
    except Exception as e:
        return jsonify({'error': str(e)}), 500


# ============================================================================
# File Browser
# ============================================================================

@app.route('/api/browse', methods=['GET'])
def browse_directory():
    """Open native OS file dialog to select directory"""
    import platform
    
    # Check if running in Docker
    in_docker = os.path.exists('/.dockerenv') or os.path.exists('/run/.containerenv')
    
    if in_docker:
        # Running in container - suggest common paths for macOS host
        suggestions = [
            '../openseastack/images/rootfs-raw',
            '../openseastack/images/build-latest/rootfs-raw',
            '/Users/YOUR_USERNAME/projects/omos/openseastack/images/rootfs-raw'
        ]
        return jsonify({
            'error': 'Running in Docker - Browse not available',
            'suggestions': suggestions,
            'hint': 'Type the path manually. Common paths are shown below.'
        }), 200
    
    try:
        system = platform.system()
        
        if system == 'Darwin':  # macOS
            cmd = [
                'osascript', '-e',
                'POSIX path of (choose folder with prompt "Select OpenSeaStack image directory")'
            ]
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
            if result.returncode == 0:
                path = result.stdout.strip()
                return jsonify({'path': path})
            else:
                return jsonify({'error': 'Cancelled'}), 400
                
        elif system == 'Linux':
            # Try zenity first, fallback to kdialog
            if subprocess.run(['which', 'zenity'], capture_output=True).returncode == 0:
                cmd = ['zenity', '--file-selection', '--directory', '--title=Select OpenSeaStack image directory']
                result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
                if result.returncode == 0:
                    path = result.stdout.strip()
                    return jsonify({'path': path})
            elif subprocess.run(['which', 'kdialog'], capture_output=True).returncode == 0:
                cmd = ['kdialog', '--getexistingdirectory', '.', '--title', 'Select OpenSeaStack image directory']
                result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
                if result.returncode == 0:
                    path = result.stdout.strip()
                    return jsonify({'path': path})
            
            return jsonify({'error': 'No file dialog available (install zenity or kdialog)'}), 500
        else:
            return jsonify({'error': 'Unsupported platform'}), 500
            
    except Exception as e:
        return jsonify({'error': str(e)}), 500


# ============================================================================
# Helper Functions
# ============================================================================

def extract_rootfs(img_path, dest_dir):
    """Extract rootfs from .img file using loop mount"""
    # This is a placeholder - actual implementation needs privileged container
    # For now, we'll assume user provides rootfs-raw directly
    dest_dir.mkdir(parents=True, exist_ok=True)
    # TODO: Implement actual extraction logic


def get_dir_size(path):
    """Get directory size in MB"""
    total = 0
    for entry in path.rglob('*'):
        if entry.is_file():
            total += entry.stat().st_size
    return round(total / 1024 / 1024, 1)


# ============================================================================
# Static Files
# ============================================================================

@app.route('/')
def index():
    return send_from_directory('static', 'index.html')


@app.route('/<path:path>')
def static_files(path):
    return send_from_directory('static', path)


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=38434, debug=True)
