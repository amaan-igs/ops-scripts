#!/bin/bash
################################################################################
# Docker Engine Installation Script for RHEL
#
# Supported versions: RHEL 8, 9, 10
# Installs: Docker Engine, CLI, containerd, buildx plugin, and Docker Compose
#
# Usage: sudo ./docker-install.sh [OPTIONS]
# Options:
#   --non-root-user <username>  Add specified user to docker group for non-root access
#   --no-autostart              Do not configure Docker to start on boot
#   --dry-run                   Show what would be installed without making changes
#   -h, --help                  Display this help message
################################################################################

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
NON_ROOT_USER=""
ENABLE_AUTOSTART=true
DRY_RUN=false
LOG_FILE="/var/log/docker-install.log"

################################################################################
# Functions
################################################################################

log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $*" | tee -a "$LOG_FILE"
}

success() {
    echo -e "${GREEN}✓${NC} $*" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}✗ ERROR:${NC} $*" | tee -a "$LOG_FILE"
}

warning() {
    echo -e "${YELLOW}⚠ WARNING:${NC} $*" | tee -a "$LOG_FILE"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (use 'sudo')"
        exit 1
    fi
}

check_os() {
    log "Checking OS compatibility..."

    if [[ ! -f /etc/os-release ]]; then
        error "Cannot determine OS version"
        exit 1
    fi

    . /etc/os-release

    if [[ "$ID" != "rhel" ]]; then
        error "This script is designed for RHEL only. Detected: $ID"
        exit 1
    fi

    # Extract major version
    VERSION_MAJOR=$(echo "$VERSION_ID" | cut -d. -f1)

    if ! [[ "$VERSION_MAJOR" =~ ^[8-9]$ ]] && [[ "$VERSION_MAJOR" != "10" ]]; then
        error "Unsupported RHEL version: $VERSION_ID (requires 8, 9, or 10)"
        exit 1
    fi

    success "Detected RHEL $VERSION_ID"
}

show_help() {
    head -n 15 "$0" | tail -n +2 | sed 's/^# //' | sed 's/^#//'
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --non-root-user)
                NON_ROOT_USER="$2"
                shift 2
                ;;
            --no-autostart)
                ENABLE_AUTOSTART=false
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

remove_conflicting_packages() {
    log "Checking for conflicting packages..."

    local packages=(
        "docker"
        "docker-client"
        "docker-client-latest"
        "docker-common"
        "docker-latest"
        "docker-latest-logrotate"
        "docker-logrotate"
        "docker-engine"
        "podman"
        "runc"
    )

    local to_remove=""
    for pkg in "${packages[@]}"; do
        if dnf list installed "$pkg" &>/dev/null 2>&1; then
            to_remove="$to_remove $pkg"
        fi
    done

    if [[ -n "$to_remove" ]]; then
        log "Found conflicting packages:$to_remove"
        if [[ "$DRY_RUN" == false ]]; then
            log "Removing conflicting packages..."
            dnf remove -y $to_remove || warning "Some packages could not be removed"
        else
            log "[DRY RUN] Would remove:$to_remove"
        fi
        success "Conflicting packages removed"
    else
        success "No conflicting packages found"
    fi
}

setup_docker_repository() {
    log "Setting up Docker repository..."

    if [[ "$DRY_RUN" == false ]]; then
        # Install dnf-plugins-core
        log "Installing dnf-plugins-core..."
        dnf install -y dnf-plugins-core

        # Add Docker repository
        log "Adding Docker CE repository..."
        dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
        success "Docker repository configured"
    else
        log "[DRY RUN] Would install dnf-plugins-core"
        log "[DRY RUN] Would add Docker CE repository"
    fi
}

install_docker_packages() {
    log "Installing Docker packages..."

    local packages=(
        "docker-ce"
        "docker-ce-cli"
        "containerd.io"
        "docker-buildx-plugin"
        "docker-compose-plugin"
    )

    if [[ "$DRY_RUN" == false ]]; then
        dnf install -y "${packages[@]}"
        success "Docker packages installed"
    else
        log "[DRY RUN] Would install: ${packages[*]}"
    fi
}

start_docker_service() {
    log "Starting Docker service..."

    if [[ "$DRY_RUN" == false ]]; then
        if [[ "$ENABLE_AUTOSTART" == true ]]; then
            systemctl enable --now docker
            success "Docker service enabled and started (will autostart on boot)"
        else
            systemctl start docker
            success "Docker service started"
        fi
    else
        if [[ "$ENABLE_AUTOSTART" == true ]]; then
            log "[DRY RUN] Would enable and start Docker service"
        else
            log "[DRY RUN] Would start Docker service"
        fi
    fi
}

verify_installation() {
    log "Verifying Docker installation..."

    if [[ "$DRY_RUN" == false ]]; then
        # Check if Docker is running
        if ! systemctl is-active --quiet docker; then
            error "Docker service is not running"
            exit 1
        fi

        # Check Docker command
        if ! command -v docker &> /dev/null; then
            error "Docker command not found"
            exit 1
        fi

        # Check docker-compose
        if ! command -v docker-compose &> /dev/null; then
            error "docker-compose command not found"
            exit 1
        fi

        # Run test container
        log "Running hello-world test..."
        if sudo docker run --rm hello-world > /dev/null 2>&1; then
            success "Docker hello-world test passed"
        else
            warning "Docker hello-world test failed (may be a network issue)"
        fi

        # Display versions
        log "Docker version information:"
        docker --version | sed 's/^/  /'
        docker-compose --version | sed 's/^/  /'
        containerd --version | sed 's/^/  /'
    else
        log "[DRY RUN] Would verify Docker installation"
    fi
}

configure_non_root_user() {
    if [[ -z "$NON_ROOT_USER" ]]; then
        return
    fi

    log "Configuring non-root Docker access for user: $NON_ROOT_USER"

    if [[ "$DRY_RUN" == false ]]; then
        # Check if user exists
        if ! id "$NON_ROOT_USER" &>/dev/null; then
            error "User '$NON_ROOT_USER' does not exist"
            return 1
        fi

        # Create docker group if it doesn't exist
        if ! getent group docker > /dev/null; then
            log "Creating docker group..."
            groupadd docker
        fi

        # Add user to docker group
        log "Adding user to docker group..."
        usermod -aG docker "$NON_ROOT_USER"

        # Fix permissions if .docker directory exists
        local docker_dir="/home/$NON_ROOT_USER/.docker"
        if [[ -d "$docker_dir" ]]; then
            log "Fixing permissions on $docker_dir..."
            chown "$NON_ROOT_USER:$NON_ROOT_USER" "$docker_dir" -R
            chmod g+rwx "$docker_dir" -R
        fi

        success "User '$NON_ROOT_USER' can now run Docker commands without sudo"
        warning "User must log out and log back in for group membership to take effect"
    else
        log "[DRY RUN] Would configure non-root access for user: $NON_ROOT_USER"
    fi
}

configure_systemd_autostart() {
    if [[ "$ENABLE_AUTOSTART" == false ]]; then
        return
    fi

    log "Configuring Docker and containerd to start on boot..."

    if [[ "$DRY_RUN" == false ]]; then
        systemctl enable docker.service
        systemctl enable containerd.service
        success "Docker and containerd will start automatically on boot"
    else
        log "[DRY RUN] Would enable docker.service and containerd.service"
    fi
}

main() {
    check_root
    parse_arguments "$@"

    # Initialize log file
    touch "$LOG_FILE"

    log "=========================================="
    log "Docker Engine Installation Script"
    log "=========================================="

    if [[ "$DRY_RUN" == true ]]; then
        warning "DRY RUN MODE - no changes will be made"
    fi

    check_os
    remove_conflicting_packages
    setup_docker_repository
    install_docker_packages
    start_docker_service
    verify_installation
    configure_non_root_user
    configure_systemd_autostart

    log "=========================================="
    success "Docker installation complete!"
    log "=========================================="
    log "Installation log saved to: $LOG_FILE"

    if [[ "$DRY_RUN" == false ]]; then
        if [[ -n "$NON_ROOT_USER" ]]; then
            log "Next steps:"
            log "  1. User '$NON_ROOT_USER' must log out and log back in"
            log "  2. Or run: newgrp docker"
        fi
        log "Verify Docker is working: docker run hello-world"
    fi
}

main "$@"
