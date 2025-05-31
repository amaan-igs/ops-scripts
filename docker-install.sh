#!/bin/bash

# Docker CE Professional Installation Script
# Description: Comprehensive Docker CE installation utility for professional environments
# Author: Amaan Ul Haq Siddiqui - DevSecOps Engineer
# Version: 2.0
# Compatible: Ubuntu 20.04+, Debian 11+, CentOS 8+, RHEL 8+

set -euo pipefail  # Exit on error, undefined vars, and pipe failures

# Configuration
SCRIPT_NAME="Docker CE Professional Installation Utility"
SCRIPT_VERSION="2.0"
LOG_FILE="/tmp/docker-install-$(date +%Y%m%d-%H%M%S).log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
DOCKER_GPG_URL="https://download.docker.com/linux"
MINIMUM_DISK_SPACE_GB=10
MINIMUM_RAM_MB=2048

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Logging function
log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# Print functions
print_header() {
    echo -e "${BLUE}============================================================${NC}"
    echo -e "${CYAN}$SCRIPT_NAME v$SCRIPT_VERSION${NC}"
    echo -e "${BLUE}============================================================${NC}"
    echo "Timestamp: $TIMESTAMP"
    echo "Log file: $LOG_FILE"
    echo "User: $(whoami)"
    echo "System: $(uname -a)"
    echo -e "${BLUE}============================================================${NC}"
    echo ""
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
    log "INFO" "SUCCESS: $1"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
    log "ERROR" "$1"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
    log "WARN" "$1"
}

print_info() {
    echo -e "${CYAN}ℹ $1${NC}"
    log "INFO" "$1"
}

# Check if running as root
check_root() {
    if [[ $EUID -eq 0 ]]; then
        print_error "This script should not be run as root for security reasons"
        print_info "Please run as a regular user. The script will use sudo when needed"
        exit 1
    fi
    local CURRENT_USER=$(whoami)
    print_success "Running as user: $CURRENT_USER"
}

# Check sudo privileges
check_sudo() {
    print_info "Checking sudo privileges..."
    if ! sudo -n true 2>/dev/null; then
        print_warning "Sudo access required. You may be prompted for your password."
        if ! sudo true; then
            print_error "Failed to obtain sudo privileges"
            exit 1
        fi
    fi
    print_success "Sudo privileges confirmed"
}

# Detect operating system
detect_os() {
    print_info "Detecting operating system..."
    
    if [[ ! -f /etc/os-release ]]; then
        print_error "Cannot detect operating system. /etc/os-release not found"
        exit 1
    fi
    
    source /etc/os-release
    local OS_ID="$ID"
    local OS_VERSION="$VERSION_ID"
    local OS_CODENAME="${VERSION_CODENAME:-$UBUNTU_CODENAME}"
    local ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
    
    print_success "Operating System: $PRETTY_NAME"
    print_info "  - ID: $OS_ID"
    print_info "  - Version: $OS_VERSION"
    print_info "  - Codename: $OS_CODENAME"
    print_info "  - Architecture: $ARCH"
    
    # Validate supported OS
    case "$OS_ID" in
        ubuntu|debian)
            if [[ "$OS_ID" == "ubuntu" && $(echo "$OS_VERSION >= 20.04" | bc 2>/dev/null || echo 0) -eq 0 ]]; then
                print_warning "Ubuntu version $OS_VERSION may not be fully supported. Recommended: 20.04+"
            elif [[ "$OS_ID" == "debian" && $(echo "$OS_VERSION >= 11" | bc 2>/dev/null || echo 0) -eq 0 ]]; then
                print_warning "Debian version $OS_VERSION may not be fully supported. Recommended: 11+"
            fi
            ;;
        centos|rhel|fedora)
            print_info "RHEL-based system detected"
            ;;
        *)
            print_warning "Operating system '$OS_ID' may not be fully supported"
            read -p "Do you want to continue anyway? (y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                exit 1
            fi
            ;;
    esac
}

# Check system requirements
check_system_requirements() {
    print_info "Checking system requirements..."
    
    # Get architecture
    local ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
    
    # Check available disk space
    local available_space=$(df / | awk 'NR==2 {print int($4/1024/1024)}')
    if [[ $available_space -lt $MINIMUM_DISK_SPACE_GB ]]; then
        print_error "Insufficient disk space. Required: ${MINIMUM_DISK_SPACE_GB}GB, Available: ${available_space}GB"
        exit 1
    fi
    print_success "Disk space: ${available_space}GB available"
    
    # Check available RAM
    local available_ram=$(free -m | awk 'NR==2{print $2}')
    if [[ $available_ram -lt $MINIMUM_RAM_MB ]]; then
        print_warning "Low RAM detected. Required: ${MINIMUM_RAM_MB}MB, Available: ${available_ram}MB"
        print_info "Docker may not perform optimally with limited RAM"
    else
        print_success "RAM: ${available_ram}MB available"
    fi
    
    # Check CPU architecture
    case "$ARCH" in
        amd64|x86_64)
            print_success "Architecture: $ARCH (supported)"
            ;;
        arm64|aarch64)
            print_success "Architecture: $ARCH (supported)"
            ;;
        *)
            print_warning "Architecture '$ARCH' may have limited support"
            ;;
    esac
}

# Check if Docker is already installed
check_existing_docker() {
    print_info "Checking for existing Docker installation..."
    
    if command -v docker >/dev/null 2>&1; then
        local docker_version=$(docker --version 2>/dev/null || echo "Unknown")
        print_warning "Docker is already installed: $docker_version"
        
        read -p "Do you want to reinstall Docker? This will remove the existing installation (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "Installation cancelled by user"
            exit 0
        fi
        
        print_info "Proceeding with Docker reinstallation..."
        return 0
    fi
    
    print_success "No existing Docker installation found"
}

# Remove conflicting packages
remove_conflicting_packages() {
    print_info "Removing conflicting Docker packages..."
    
    source /etc/os-release
    local OS_ID="$ID"
    
    local packages_to_remove=""
    case "$OS_ID" in
        ubuntu|debian)
            packages_to_remove="docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc"
            ;;
        centos|rhel|fedora)
            packages_to_remove="docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine podman runc"
            ;;
    esac
    
    if [[ -n "$packages_to_remove" ]]; then
        for pkg in $packages_to_remove; do
            if dpkg -l | grep -q "^ii.*$pkg" 2>/dev/null || rpm -q "$pkg" >/dev/null 2>&1; then
                print_info "Removing package: $pkg"
                case "$OS_ID" in
                    ubuntu|debian)
                        sudo apt-get remove -y "$pkg" >/dev/null 2>&1 || true
                        ;;
                    centos|rhel|fedora)
                        sudo yum remove -y "$pkg" >/dev/null 2>&1 || sudo dnf remove -y "$pkg" >/dev/null 2>&1 || true
                        ;;
                esac
            fi
        done
        print_success "Conflicting packages removed"
    else
        print_info "No conflicting packages to remove"
    fi
}

# Update package manager
update_package_manager() {
    print_info "Updating package manager..."
    
    source /etc/os-release
    local OS_ID="$ID"
    
    case "$OS_ID" in
        ubuntu|debian)
            if sudo apt-get update >/dev/null 2>&1; then
                print_success "Package manager updated (apt)"
            else
                print_error "Failed to update package manager"
                exit 1
            fi
            ;;
        centos|rhel|fedora)
            if sudo yum update -y >/dev/null 2>&1 || sudo dnf update -y >/dev/null 2>&1; then
                print_success "Package manager updated (yum/dnf)"
            else
                print_error "Failed to update package manager"
                exit 1
            fi
            ;;
    esac
}

# Install prerequisites
install_prerequisites() {
    print_info "Installing prerequisites..."
    
    source /etc/os-release
    local OS_ID="$ID"
    
    case "$OS_ID" in
        ubuntu|debian)
            local prereqs="ca-certificates curl gnupg lsb-release apt-transport-https software-properties-common"
            if sudo apt-get install -y $prereqs >/dev/null 2>&1; then
                print_success "Prerequisites installed: $prereqs"
            else
                print_error "Failed to install prerequisites"
                exit 1
            fi
            ;;
        centos|rhel|fedora)
            local prereqs="yum-utils device-mapper-persistent-data lvm2 curl"
            if sudo yum install -y $prereqs >/dev/null 2>&1 || sudo dnf install -y $prereqs >/dev/null 2>&1; then
                print_success "Prerequisites installed: $prereqs"
            else
                print_error "Failed to install prerequisites"
                exit 1
            fi
            ;;
    esac
}

# Add Docker repository
add_docker_repository() {
    print_info "Adding Docker official repository..."
    
    source /etc/os-release
    local OS_ID="$ID"
    local OS_CODENAME="${VERSION_CODENAME:-$UBUNTU_CODENAME}"
    local ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
    
    case "$OS_ID" in
        ubuntu|debian)
            # Create keyrings directory
            sudo install -m 0755 -d /etc/apt/keyrings
            
            # Download and add Docker's GPG key
            local gpg_url="$DOCKER_GPG_URL/$OS_ID/gpg"
            if sudo curl -fsSL "$gpg_url" -o /etc/apt/keyrings/docker.asc; then
                sudo chmod a+r /etc/apt/keyrings/docker.asc
                print_success "Docker GPG key added"
            else
                print_error "Failed to download Docker GPG key from $gpg_url"
                exit 1
            fi
            
            # Add repository
            echo \
                "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.asc] $DOCKER_GPG_URL/$OS_ID \
                $OS_CODENAME stable" | \
                sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
            
            # Update package index
            if sudo apt-get update >/dev/null 2>&1; then
                print_success "Docker repository added and package index updated"
            else
                print_error "Failed to update package index after adding repository"
                exit 1
            fi
            ;;
        centos|rhel|fedora)
            local repo_url="$DOCKER_GPG_URL/$OS_ID/docker-ce.repo"
            if sudo yum-config-manager --add-repo "$repo_url" >/dev/null 2>&1 || \
               sudo dnf config-manager --add-repo "$repo_url" >/dev/null 2>&1; then
                print_success "Docker repository added"
            else
                print_error "Failed to add Docker repository"
                exit 1
            fi
            ;;
    esac
}

# Install Docker
install_docker() {
    print_info "Installing Docker CE..."
    
    source /etc/os-release
    local OS_ID="$ID"
    
    case "$OS_ID" in
        ubuntu|debian)
            local docker_packages="docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
            if sudo apt-get install -y $docker_packages >/dev/null 2>&1; then
                print_success "Docker CE installed successfully"
            else
                print_error "Failed to install Docker CE"
                exit 1
            fi
            ;;
        centos|rhel|fedora)
            local docker_packages="docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
            if sudo yum install -y $docker_packages >/dev/null 2>&1 || \
               sudo dnf install -y $docker_packages >/dev/null 2>&1; then
                print_success "Docker CE installed successfully"
            else
                print_error "Failed to install Docker CE"
                exit 1
            fi
            ;;
    esac
}

# Configure Docker service
configure_docker_service() {
    print_info "Configuring Docker service..."
    
    # Enable Docker service
    if sudo systemctl enable docker >/dev/null 2>&1; then
        print_success "Docker service enabled"
    else
        print_error "Failed to enable Docker service"
        exit 1
    fi
    
    # Start Docker service
    if sudo systemctl start docker >/dev/null 2>&1; then
        print_success "Docker service started"
    else
        print_error "Failed to start Docker service"
        exit 1
    fi
    
    # Verify service status
    if sudo systemctl is-active docker >/dev/null 2>&1; then
        print_success "Docker service is running"
    else
        print_error "Docker service is not running properly"
        exit 1
    fi
}

# Configure user permissions
configure_user_permissions() {
    print_info "Configuring user permissions..."
    
    local CURRENT_USER=$(whoami)
    
    # Create docker group if it doesn't exist
    if ! getent group docker >/dev/null 2>&1; then
        if sudo groupadd docker >/dev/null 2>&1; then
            print_success "Docker group created"
        else
            print_error "Failed to create docker group"
            exit 1
        fi
    else
        print_info "Docker group already exists"
    fi
    
    # Add current user to docker group
    if sudo usermod -aG docker "$CURRENT_USER" >/dev/null 2>&1; then
        print_success "User '$CURRENT_USER' added to docker group"
    else
        print_error "Failed to add user to docker group"
        exit 1
    fi
    
    print_warning "You need to log out and log back in for group membership to take effect"
    print_info "Alternatively, you can run: newgrp docker"
}

# Configure Docker daemon
configure_docker_daemon() {
    print_info "Configuring Docker daemon..."
    
    # Create daemon configuration directory
    sudo mkdir -p /etc/docker
    
    # Create daemon.json with recommended settings
    local daemon_config='{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2",
  "exec-opts": ["native.cgroupdriver=systemd"],
  "live-restore": true,
  "userland-proxy": false,
  "experimental": false
}'
    
    if echo "$daemon_config" | sudo tee /etc/docker/daemon.json >/dev/null; then
        print_success "Docker daemon configuration created"
    else
        print_error "Failed to create Docker daemon configuration"
        exit 1
    fi
    
    # Restart Docker to apply configuration
    if sudo systemctl restart docker >/dev/null 2>&1; then
        print_success "Docker daemon restarted with new configuration"
    else
        print_error "Failed to restart Docker daemon"
        exit 1
    fi
}

# Verify installation
verify_installation() {
    print_info "Verifying Docker installation..."
    
    # Check Docker version
    if docker_version=$(docker --version 2>/dev/null); then
        print_success "Docker version: $docker_version"
    else
        print_error "Failed to get Docker version"
        exit 1
    fi
    
    # Check Docker Compose version
    if compose_version=$(docker compose version 2>/dev/null); then
        print_success "Docker Compose version: $compose_version"
    else
        print_warning "Docker Compose verification failed"
    fi
    
    # Test Docker functionality
    print_info "Testing Docker functionality..."
    if docker run --rm hello-world >/dev/null 2>&1; then
        print_success "Docker test run completed successfully"
    else
        print_warning "Docker test run failed - this may be due to group membership (try 'newgrp docker')"
    fi
    
    # Display Docker info
    print_info "Docker system information:"
    docker info 2>/dev/null | grep -E "(Server Version|Storage Driver|Cgroup Driver|Kernel Version)" | while read line; do
        print_info "  $line"
    done
}

# Post-installation recommendations
post_installation_recommendations() {
    echo ""
    print_info "Post-installation recommendations:"
    echo "  1. Log out and log back in to apply group membership changes"
    echo "  2. Run 'docker run hello-world' to test your installation"
    echo "  3. Consider setting up Docker security scanning"
    echo "  4. Review Docker daemon logs: 'sudo journalctl -u docker.service'"
    echo "  5. Configure log rotation if needed"
    echo "  6. Set up Docker registry authentication if using private registries"
    echo "  7. Consider installing Docker security tools like docker-bench-security"
    echo ""
    
    print_info "Useful Docker commands:"
    echo "  - docker --version          : Show Docker version"
    echo "  - docker info              : Show Docker system information"
    echo "  - docker ps                : List running containers"
    echo "  - docker images            : List downloaded images"
    echo "  - docker system prune      : Clean up unused resources"
    echo ""
}

# Main execution function
main() {
    print_header
    
    # Pre-installation checks
    check_root
    check_sudo
    detect_os
    check_system_requirements
    check_existing_docker
    
    echo ""
    print_info "Starting Docker installation process..."
    echo ""
    
    # Installation steps
    remove_conflicting_packages
    update_package_manager
    install_prerequisites
    add_docker_repository
    install_docker
    configure_docker_service
    configure_user_permissions
    configure_docker_daemon
    
    echo ""
    print_info "Verifying installation..."
    verify_installation
    
    echo ""
    print_success "Docker installation completed successfully!"
    echo ""
    
    post_installation_recommendations
    
    echo -e "${BLUE}============================================================${NC}"
    echo -e "${GREEN}Docker CE Professional Installation Completed${NC}"
    echo "Log file saved to: $LOG_FILE"
    echo -e "${BLUE}============================================================${NC}"
    
    log "INFO" "Docker installation script completed successfully"
}

# Handle script interruption
trap 'print_error "Script interrupted by user"; exit 1' INT TERM

# Execute main function
main "$@"