#!/bin/bash
# setup.sh - One-command installer for rpi-netboot-dev
# Detects platform, installs dependencies, configures networking

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

banner() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║   rpi-netboot-dev Setup                  ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}"
    echo ""
}

success() {
    echo -e "${GREEN}✓${NC} $1"
}

warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

error() {
    echo -e "${RED}✗${NC} $1"
}

info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

# Detect platform
detect_platform() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        PLATFORM="macos"
        info "Platform: macOS"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        PLATFORM="linux"
        info "Platform: Linux"
    else
        error "Unsupported platform: $OSTYPE"
        exit 1
    fi
}

# macOS: Install Homebrew
install_homebrew() {
    if command -v brew &> /dev/null; then
        success "Homebrew already installed"
        return 0
    fi
    
    warn "Homebrew not found"
    echo ""
    read -p "Install Homebrew? [Y/n] " -n 1 -r
    echo ""
    
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        info "Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        success "Homebrew installed"
    else
        error "Homebrew is required. Install manually: https://brew.sh"
        exit 1
    fi
}

# macOS: Install socket_vmnet
install_socket_vmnet() {
    if brew list socket_vmnet &> /dev/null; then
        success "socket_vmnet already installed"
        
        # Check if service is running
        if launchctl list 2>/dev/null | grep -q "socket_vmnet"; then
            success "socket_vmnet service running"
        else
            warn "socket_vmnet service not running"
            info "Starting socket_vmnet..."
            sudo brew services start socket_vmnet
            success "socket_vmnet started"
        fi
        return 0
    fi
    
    warn "socket_vmnet not found (required for bridged networking)"
    echo ""
    read -p "Install socket_vmnet? [Y/n] " -n 1 -r
    echo ""
    
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        info "Installing socket_vmnet..."
        brew install socket_vmnet
        brew tap homebrew/services
        sudo brew services start socket_vmnet
        success "socket_vmnet installed and started"
    else
        error "socket_vmnet is required for LAN connectivity"
        exit 1
    fi
}

# macOS: Setup Colima
setup_colima() {
    if ! command -v colima &> /dev/null; then
        warn "Colima not found"
        read -p "Install Colima? [Y/n] " -n 1 -r
        echo ""
        
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            info "Installing Colima and Docker..."
            brew install colima docker docker-compose
        else
            error "Colima is required on macOS"
            exit 1
        fi
    else
        success "Colima installed"
    fi
    
    # Check if Colima is running
    if colima status &> /dev/null; then
        local current_ip=$(colima status 2>&1 | grep "address:" | awk '{print $2}')
        
        # Check if it's using NAT (192.168.x.x) instead of bridged
        if [[ "$current_ip" == 192.168.* ]]; then
            warn "Colima is using NAT network ($current_ip)"
            info "Restarting Colima with bridged networking..."
            colima stop
        else
            success "Colima running with bridged IP: $current_ip"
            return 0
        fi
    fi
    
    # Start Colima with bridged networking
    info "Starting Colima (120GB disk, 8 CPU, 16GB RAM, bridged network)..."
    colima start --network-address --cpu 8 --memory 16 --disk 120
    
    local colima_ip=$(colima status 2>&1 | grep "address:" | awk '{print $2}')
    success "Colima started with IP: $colima_ip"
}

# Linux: Check Docker
check_docker_linux() {
    if ! command -v docker &> /dev/null; then
        error "Docker not found"
        echo ""
        echo "Install Docker:"
        echo "  Ubuntu/Debian: sudo apt-get install docker.io docker-compose"
        echo "  Fedora: sudo dnf install docker docker-compose"
        echo ""
        exit 1
    fi
    
    success "Docker installed"
    
    # Check if Docker daemon is running
    if ! docker info &> /dev/null; then
        error "Docker daemon not running"
        echo "Start with: sudo systemctl start docker"
        exit 1
    fi
    
    success "Docker daemon running"
}

# Build netboot container
build_container() {
    info "Building netboot container..."
    docker build -t rpi-netboot-dev ./docker
    success "Container built"
}

# Create images directory
setup_images_dir() {
    if [ ! -d "./images" ]; then
        mkdir -p ./images
        info "Created ./images directory"
    fi
    success "Images directory ready"
}

# Main setup flow
main() {
    banner
    
    detect_platform
    echo ""
    
    if [ "$PLATFORM" == "macos" ]; then
        echo -e "${BLUE}=== macOS Setup ===${NC}"
        install_homebrew
        install_socket_vmnet
        setup_colima
    else
        echo -e "${BLUE}=== Linux Setup ===${NC}"
        check_docker_linux
    fi
    
    echo ""
    echo -e "${BLUE}=== Container Setup ===${NC}"
    build_container
    setup_images_dir
    
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   Setup Complete!                        ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Start the server:"
    echo "     ${BLUE}./run.sh start${NC}"
    echo ""
    echo "  2. Open the Web UI:"
    echo "     ${BLUE}http://localhost:38434${NC}"
    echo ""
}

main
