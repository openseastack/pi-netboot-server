#!/bin/bash
# run.sh - Main developer command for rpi-netboot-dev
#
# Usage:
#   ./run.sh start [options]    Start the netboot server
#   ./run.sh stop               Stop the netboot server
#   ./run.sh logs               View server logs
#   ./run.sh status             Show server status
#   ./run.sh shell              Open shell in container

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default values
DHCP_MODE="auto"
WEB_UI=false
DHCP_RANGE=""

# =============================================================================
# Helper Functions
# =============================================================================

print_banner() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║       rpi-netboot-dev Server             ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo ""
}

check_colima() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # Check for Homebrew
        if ! command -v brew &> /dev/null; then
            echo -e "${RED}Error: Homebrew not found.${NC}"
            echo "Install from: https://brew.sh"
            return 1
        fi
        
        # Check for Colima
        if ! command -v colima &> /dev/null; then
            echo -e "${YELLOW}Colima not found. Install with:${NC}"
            echo "  brew install colima docker"
            return 1
        fi
        
        # Check for socket_vmnet (required for bridged networking)
        if ! brew list socket_vmnet &>/dev/null; then
            echo -e "${RED}Error: socket_vmnet not installed.${NC}"
            echo ""
            echo "socket_vmnet is required for bridged networking to your LAN."
            echo "Without it, the netboot server won't be reachable from your Pi."
            echo ""
            read -p "Install socket_vmnet now? [Y/n] " -n 1 -r
            echo ""
            if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                echo "Installing socket_vmnet..."
                brew install socket_vmnet
                brew tap homebrew/services
                sudo brew services start socket_vmnet
                echo ""
                echo -e "${GREEN}✓ socket_vmnet installed${NC}"
                echo ""
                echo "Now restart Colima with bridged networking:"
                echo "  colima stop"
                echo "  colima start --network-address --cpu 4 --memory 8"
                return 1
            else
                echo "Please install socket_vmnet manually:"
                echo "  brew install socket_vmnet"
                echo "  brew tap homebrew/services"
                echo "  sudo brew services start socket_vmnet"
                return 1
            fi
        fi
        
        # Check socket_vmnet service is running (check if launchctl has it)
        if ! launchctl list 2>/dev/null | grep -q "socket_vmnet"; then
            echo -e "${YELLOW}Warning: socket_vmnet service may not be running.${NC}"
            echo "Start with: sudo brew services start socket_vmnet"
        fi
        
        # Check Colima is running
        if ! colima status &> /dev/null; then
            echo -e "${RED}Error: Colima is not running.${NC}"
            echo "Start with: colima start --network-address --cpu 4 --memory 8"
            return 1
        fi
        
        # Check for bridged networking
        local colima_output=$(colima status 2>&1)
        local colima_ip=$(echo "$colima_output" | grep "address:" | sed 's/.*address: *//' | awk '{print $1}')
        if [ -z "$colima_ip" ]; then
            echo -e "${YELLOW}Warning: Colima may not have bridged networking.${NC}"
            echo "Restart with: colima stop && colima start --network-address"
        else
            echo -e "${GREEN}✓ Colima running with bridged IP: ${colima_ip}${NC}"
        fi
    fi
    return 0
}

check_dhcp() {
    echo "Checking for existing DHCP server..."
    
    # Platform-specific DHCP detection
    # We assume if the machine has a default gateway, there's a DHCP server
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS: Check if we have a default route (implies DHCP or static config)
        if netstat -rn | grep -q "^default"; then
            echo -e "${GREEN}✓ Network gateway detected (DHCP likely active)${NC}"
            return 0
        fi
    else
        # Linux: Check for dynamic IP assignment
        if ip addr show 2>/dev/null | grep -q "dynamic"; then
            echo -e "${GREEN}✓ DHCP server detected on network${NC}"
            return 0
        fi
        # Fallback: check for default route
        if ip route show default 2>/dev/null | grep -q "default"; then
            echo -e "${GREEN}✓ Network gateway detected (DHCP likely active)${NC}"
            return 0
        fi
    fi
    
    echo -e "${YELLOW}⚠ Could not confirm DHCP server${NC}"
    return 1
}

check_rootfs() {
    # Check if Docker volume has content
    if docker volume inspect rpi-rootfs &> /dev/null; then
        # Check if volume has content (rough check)
        local size=$(docker run --rm -v rpi-rootfs:/data alpine du -sh /data 2>/dev/null | cut -f1)
        if [ -n "$size" ] && [ "$size" != "0" ]; then
            echo -e "${GREEN}✓ Root filesystem found (${size})${NC}"
            return 0
        fi
    fi
    
    echo -e "${YELLOW}⚠ No rootfs found in Docker volume${NC}"
    echo "Run: ./scripts/sync-rootfs.sh /path/to/buildroot/output"
    return 1
}

# =============================================================================
# Commands
# =============================================================================

cmd_start() {
    print_banner
    
    echo "Starting netboot server..."
    echo ""
    
    # Auto-detect DHCP mode
    DHCP_MODE="proxy"
    if ! netstat -rn 2>/dev/null | grep -q "^default"; then
        echo "No default gateway detected. Using full DHCP mode."
        DHCP_MODE="full"
    fi
    
    # Start services
    DHCP_MODE="$DHCP_MODE" docker compose up -d
    
    echo ""
    echo -e "${GREEN}=== Server Started ===${NC}"
    echo ""
    echo "Web UI: ${BLUE}http://localhost:38434${NC}"
    echo "Logs:   ${BLUE}./run.sh logs${NC}"
    echo ""
}

cmd_stop() {
    echo "Stopping netboot server..."
    docker compose down
    echo -e "${GREEN}Server stopped.${NC}"
}

cmd_logs() {
    docker compose logs -f
}

cmd_status() {
    print_banner
    
    if docker compose ps | grep -q "rpi-netboot-dev"; then
        echo -e "${GREEN}● Server is running${NC}"
        echo ""
        docker compose ps
    else
        echo -e "${RED}○ Server is not running${NC}"
    fi
}

cmd_shell() {
    docker compose exec netboot /bin/bash
}

cmd_help() {
    echo "Usage: ./run.sh <command> [options]"
    echo ""
    echo "Commands:"
    echo "  start [options]   Start the netboot server"
    echo "  stop              Stop the netboot server"
    echo "  logs              View server logs (follow)"
    echo "  status            Show server status"
    echo "  shell             Open shell in container"
    echo ""
    echo "Start Options:"
    echo "  --dhcp-mode <mode>    auto|proxy|full (default: auto)"
    echo "  --dhcp-range <range>  IP range for full DHCP mode"
    echo "  --web-ui              Enable web monitoring UI"
    echo ""
    echo "Examples:"
    echo "  ./run.sh start                              # Auto-detect DHCP mode"
    echo "  ./run.sh start --dhcp-mode proxy            # Safe ProxyDHCP mode"
    echo "  ./run.sh start --dhcp-mode full             # Full DHCP server"
    echo ""
}

# =============================================================================
# Main
# =============================================================================

case "${1:-help}" in
    start)
        shift
        cmd_start "$@"
        ;;
    stop)
        cmd_stop
        ;;
    logs)
        cmd_logs
        ;;
    status)
        cmd_status
        ;;
    shell)
        cmd_shell
        ;;
    help|--help|-h)
        cmd_help
        ;;
    *)
        echo "Unknown command: $1"
        cmd_help
        exit 1
        ;;
esac
