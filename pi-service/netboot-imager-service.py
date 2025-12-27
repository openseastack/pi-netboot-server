#!/usr/bin/env python3
"""
Netboot Image Writer Service
Runs on Raspberry Pi to receive write-to-disk requests from netboot server
Uses only Python standard library - no external dependencies
"""

from http.server import HTTPServer, BaseHTTPRequestHandler
import subprocess
import os
import json
from pathlib import Path
import threading
import time

# Load configuration
CONFIG_FILE = Path(__file__).parent / 'config.json'

def load_config():
    """Load configuration from file"""
    if CONFIG_FILE.exists():
        with open(CONFIG_FILE) as f:
            return json.load(f)
    return {
        'allowed_ips': ['10.10.200.75', '10.10.200.0/24'],
        'shared_secret': 'openseastack-netboot-2024',
        'port': 8888
    }

config = load_config()

# Global progress tracking
write_progress = {
    'stage': 'idle',  # idle, wiping, downloading, writing, syncing, complete, error
    'percent': 0,
    'message': '',
    'error': None,
    'lock': threading.Lock()
}


def validate_ip(client_ip):
    """Validate request IP against whitelist"""
    for allowed_pattern in config['allowed_ips']:
        if '/' in allowed_pattern:
            # CIDR notation - simple check
            network = allowed_pattern.split('/')[0].rsplit('.', 1)[0]
            if client_ip.startswith(network):
                return True
        else:
            if client_ip == allowed_pattern:
                return True
    return False


def update_progress(stage, percent, message, error=None):
    """Update global progress state (thread-safe)"""
    with write_progress['lock']:
        write_progress['stage'] = stage
        write_progress['percent'] = percent
        write_progress['message'] = message
        write_progress['error'] = error
        print(f"Progress: {stage} - {percent}% - {message}")


class NetbootImageHandler(BaseHTTPRequestHandler):
    """HTTP request handler for write-to-disk requests"""
    
    def log_message(self, format, *args):
        """Custom logging"""
        print(f"{self.client_address[0]} - {format % args}")
    
    def send_json(self, data, status=200):
        """Send JSON response"""
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())
    
    def do_GET(self):
        """Handle GET requests"""
        if self.path == '/health':
            self.send_json({'status': 'ok', 'service': 'netboot-imager'})
        elif self.path == '/status':
            # Return current write progress
            with write_progress['lock']:
                self.send_json({
                    'stage': write_progress['stage'],
                    'percent': write_progress['percent'],
                    'message': write_progress['message'],
                    'error': write_progress['error']
                })
        else:
            self.send_json({'error': 'Not found'}, 404)
    
    def do_POST(self):
        """Handle POST requests"""
        if self.path == '/write-image':
            self.handle_write_image()
        else:
            self.send_json({'error': 'Not found'}, 404)
    
    def handle_write_image(self):
        """Write image to local disk"""
        client_ip = self.client_address[0]
        
        # Validate IP
        if not validate_ip(client_ip):
            self.send_json({'error': f'Unauthorized IP: {client_ip}'}, 403)
            return
        
        # Validate token
        token = self.headers.get('X-Netboot-Token')
        if token != config['shared_secret']:
            self.send_json({'error': 'Invalid token'}, 403)
            return
        
        # Parse request
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length)
        try:
            data = json.loads(body.decode())
        except:
            self.send_json({'error': 'Invalid JSON'}, 400)
            return
        
        device = data.get('device', '/dev/mmcblk0')
        image_url = data.get('image_url')
        
        if not image_url:
            self.send_json({'error': 'image_url required'}, 400)
            return
        
        # Validate device path
        valid_devices = ['/dev/mmcblk0', '/dev/mmcblk1', '/dev/nvme0n1', '/dev/sda']
        if device not in valid_devices:
            self.send_json({'error': f'Invalid device. Must be one of: {valid_devices}'}, 400)
            return
        
        try:
            # Reset progress
            update_progress('wiping', 0, f'Preparing to write image to {device}')
            
            print(f'Writing image from {image_url} to {device}')
            
            # Wipe existing partition table (handles existing OS installations)
            update_progress('wiping', 5, f'Wiping partition table on {device}...')
            print(f'Wiping partition table on {device}...')
            try:
                wipe_result = subprocess.run(
                    ['wipefs', '-a', device],
                    capture_output=True,
                    text=True,
                    timeout=30
                )
                
                if wipe_result.returncode != 0:
                    print(f'Warning: wipefs failed, trying dd fallback: {wipe_result.stderr}')
                    raise FileNotFoundError("wipefs failed, using fallback")
                    
            except (FileNotFoundError, OSError) as e:
                # Buildroot doesn't have wipefs - use dd fallback
                print(f'wipefs not available ({e}), using dd to wipe partition table')
                subprocess.run(
                    f'dd if=/dev/zero of={device} bs=1M count=10',
                    shell=True,
                    capture_output=True,
                    timeout=30
                )
            
            # Force kernel to re-read partition table
            print('Refreshing kernel partition table...')
            try:
                subprocess.run(['partprobe', device], capture_output=True, timeout=10)
            except:
                # partprobe might not exist, try blockdev
                try:
                    subprocess.run(['blockdev', '--rereadpt', device], capture_output=True, timeout=10)
                except:
                    # If both fail, at least sync
                    subprocess.run(['sync'], capture_output=True, timeout=5)
            
            update_progress('writing', 10, f'Partition table wiped, downloading and writing image...')
            print('Partition table wiped, writing image...')
            
            # Download and write image  
            # Simplified dd flags for BusyBox compatibility
            if image_url.endswith('.gz'):
                cmd = f'curl -s "{image_url}" | gunzip | dd of={device} bs=4M'
            else:
                cmd = f'curl -s "{image_url}" | dd of={device} bs=4M'
            
            # Execute dd command
            result = subprocess.run(
                cmd,
                shell=True,
                capture_output=True,
                text=True,
                timeout=600  # 10 minute timeout
            )
            
            if result.returncode == 0:
                update_progress('syncing', 95, f'Image written, synchronizing filesystem...')
                print(f'Successfully wrote image to {device}')
                
                # Sync filesystems
                subprocess.run(['sync'], check=True)
                
                update_progress('complete', 100, f'Image successfully written to {device}')
                
                self.send_json({
                    'success': True,
                    'message': f'Image successfully written to {device}',
                    'output': result.stderr  # dd writes progress to stderr
                })
            else:
                update_progress('error', 0, f'Write failed', error=result.stderr)
                print(f'Write failed: {result.stderr}')
                self.send_json({'error': result.stderr}, 500)
                
        except subprocess.TimeoutExpired:
            update_progress('error', 0, 'Write operation timed out', error='Timeout after 10 minutes')
            self.send_json({'error': 'Write operation timed out after 10 minutes'}, 504)
        except Exception as e:
            update_progress('error', 0, f'Error: {str(e)}', error=str(e))
            print(f'Error writing image: {e}')
            self.send_json({'error': str(e)}, 500)


def run_server():
    """Run the HTTP server"""
    port = config.get('port', 8888)
    server = HTTPServer(('0.0.0.0', port), NetbootImageHandler)
    print(f'Netboot Image Writer Service starting on port {port}')
    print(f'Allowed IPs: {config["allowed_ips"]}')
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print('\nShutting down...')
        server.shutdown()


if __name__ == '__main__':
    run_server()
