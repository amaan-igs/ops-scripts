#!/bin/bash

# Docker Environment Cleanup Script
# Description: Comprehensive Docker cleanup utility for development environments
# Author: Amaan Ul Haq Siddiqui - DevSecOps Engineer

set -euo pipefail  # Exit on error, undefined vars, and pipe failures

# Configuration
SCRIPT_NAME="Docker Cleanup Utility"
LOG_FILE="/tmp/docker-cleanup-$(date +%Y%m%d-%H%M%S).log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# Color codes for output (optional, can be disabled for pure text)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    local level=$1
    shift
    local message="$*"
    echo "[$TIMESTAMP] [$level] $message" | tee -a "$LOG_FILE"
}

# Print header
print_header() {
    echo "============================================================"
    echo "$SCRIPT_NAME"
    echo "============================================================"
    echo "Timestamp: $TIMESTAMP"
    echo "Log file: $LOG_FILE"
    echo "============================================================"
}

# Check if Docker is running
check_docker() {
    if ! docker info >/dev/null 2>&1; then
        log "ERROR" "Docker daemon is not running or not accessible"
        exit 1
    fi
    log "INFO" "Docker daemon is running"
}

# Get current Docker state
get_docker_state() {
    local containers=$(docker ps -aq 2>/dev/null | wc -l)
    local running_containers=$(docker ps -q 2>/dev/null | wc -l)
    local images=$(docker images -q 2>/dev/null | wc -l)
    local volumes=$(docker volume ls -q 2>/dev/null | wc -l)
    local networks=$(docker network ls --format "table {{.Name}}" | grep -v -E '^(bridge|host|none|NETWORK)$' | wc -l)
    local compose_stacks=0
    
    if command -v jq >/dev/null 2>&1; then
        compose_stacks=$(docker compose ls --format json 2>/dev/null | jq '. | length' 2>/dev/null || echo "0")
    fi
    
    echo "Current Docker Environment State:"
    echo "  - Total containers: $containers (running: $running_containers)"
    echo "  - Total images: $images"
    echo "  - Total volumes: $volumes"
    echo "  - Custom networks: $networks"
    echo "  - Compose stacks: $compose_stacks"
    echo ""
}

# Confirmation prompt
confirm_cleanup() {
    echo "WARNING: This operation will permanently remove:"
    echo "  - All Docker containers (running and stopped)"
    echo "  - All Docker images"
    echo "  - All Docker volumes"
    echo "  - All custom Docker networks"
    echo "  - All Docker Compose stacks"
    echo "  - Docker build cache"
    echo ""
    echo "This action cannot be undone."
    echo ""
    
    read -p "Do you want to proceed? Type 'yes' to continue: " confirm
    if [[ "$confirm" != "yes" ]]; then
        log "INFO" "Operation cancelled by user"
        echo "Operation cancelled."
        exit 0
    fi
    log "INFO" "User confirmed cleanup operation"
}

# Stop all running containers
stop_containers() {
    log "INFO" "Starting container shutdown process"
    local running_containers=$(docker ps -q)
    
    if [[ -n "$running_containers" ]]; then
        echo "Stopping running containers..."
        echo "$running_containers" | while read container; do
            local name=$(docker inspect --format='{{.Name}}' "$container" 2>/dev/null | sed 's/\///')
            echo "  - Stopping container: $name ($container)"
            if docker stop "$container" >/dev/null 2>&1; then
                log "INFO" "Successfully stopped container: $name ($container)"
            else
                log "WARN" "Failed to stop container: $name ($container)"
            fi
        done
    else
        echo "No running containers found."
        log "INFO" "No running containers to stop"
    fi
}

# Remove all containers
remove_containers() {
    log "INFO" "Starting container removal process"
    local all_containers=$(docker ps -aq)
    
    if [[ -n "$all_containers" ]]; then
        echo "Removing all containers..."
        local count=0
        echo "$all_containers" | while read container; do
            local name=$(docker inspect --format='{{.Name}}' "$container" 2>/dev/null | sed 's/\///' || echo "unknown")
            echo "  - Removing container: $name ($container)"
            if docker rm "$container" >/dev/null 2>&1; then
                log "INFO" "Successfully removed container: $name ($container)"
                ((count++))
            else
                log "WARN" "Failed to remove container: $name ($container)"
            fi
        done
        log "INFO" "Container removal completed"
    else
        echo "No containers found to remove."
        log "INFO" "No containers to remove"
    fi
}

# Remove all images
remove_images() {
    log "INFO" "Starting image removal process"
    local all_images=$(docker images -q)
    
    if [[ -n "$all_images" ]]; then
        echo "Removing all images..."
        local count=0
        docker images --format "table {{.Repository}}:{{.Tag}}\t{{.ID}}" | grep -v "REPOSITORY:TAG" | while read image_info; do
            local image_name=$(echo "$image_info" | awk '{print $1}')
            local image_id=$(echo "$image_info" | awk '{print $2}')
            echo "  - Removing image: $image_name ($image_id)"
            if docker rmi -f "$image_id" >/dev/null 2>&1; then
                log "INFO" "Successfully removed image: $image_name ($image_id)"
                ((count++))
            else
                log "WARN" "Failed to remove image: $image_name ($image_id)"
            fi
        done
        log "INFO" "Image removal completed"
    else
        echo "No images found to remove."
        log "INFO" "No images to remove"
    fi
}

# Remove all volumes
remove_volumes() {
    log "INFO" "Starting volume removal process"
    local all_volumes=$(docker volume ls -q)
    
    if [[ -n "$all_volumes" ]]; then
        echo "Removing all volumes..."
        echo "$all_volumes" | while read volume; do
            echo "  - Removing volume: $volume"
            if docker volume rm "$volume" >/dev/null 2>&1; then
                log "INFO" "Successfully removed volume: $volume"
            else
                log "WARN" "Failed to remove volume: $volume"
            fi
        done
        log "INFO" "Volume removal completed"
    else
        echo "No volumes found to remove."
        log "INFO" "No volumes to remove"
    fi
}

# Remove custom networks
remove_networks() {
    log "INFO" "Starting custom network removal process"
    local custom_networks=$(docker network ls --format "{{.Name}}" | grep -v -E '^(bridge|host|none)$')
    
    if [[ -n "$custom_networks" ]]; then
        echo "Removing custom networks..."
        echo "$custom_networks" | while read network; do
            echo "  - Removing network: $network"
            if docker network rm "$network" >/dev/null 2>&1; then
                log "INFO" "Successfully removed network: $network"
            else
                log "WARN" "Failed to remove network: $network (may be in use)"
            fi
        done
        log "INFO" "Network removal completed"
    else
        echo "No custom networks found to remove."
        log "INFO" "No custom networks to remove"
    fi
}

# Clean build cache
clean_build_cache() {
    log "INFO" "Starting build cache cleanup"
    echo "Cleaning Docker build cache..."
    
    if docker builder prune -af --filter type=cache >/dev/null 2>&1; then
        echo "  - Build cache cleaned successfully"
        log "INFO" "Build cache cleaned successfully"
    else
        echo "  - Failed to clean build cache"
        log "WARN" "Failed to clean build cache"
    fi
}

# Remove Docker Compose stacks
remove_compose_stacks() {
    log "INFO" "Starting Docker Compose stack removal"
    
    # Check if jq is available
    if ! command -v jq >/dev/null 2>&1; then
        echo "Warning: jq not found. Skipping Docker Compose stack removal."
        log "WARN" "jq not available for Docker Compose stack removal"
        return
    fi
    
    local stacks=$(docker compose ls --format json 2>/dev/null | jq -r '.[].Name' 2>/dev/null)
    
    if [[ -n "$stacks" && "$stacks" != "null" ]]; then
        echo "Removing Docker Compose stacks..."
        echo "$stacks" | while read stack; do
            if [[ -n "$stack" ]]; then
                echo "  - Removing stack: $stack"
                if docker compose -p "$stack" down -v --remove-orphans >/dev/null 2>&1; then
                    log "INFO" "Successfully removed stack: $stack"
                else
                    log "WARN" "Failed to remove stack: $stack"
                fi
            fi
        done
        log "INFO" "Docker Compose stack removal completed"
    else
        echo "No Docker Compose stacks found to remove."
        log "INFO" "No Docker Compose stacks to remove"
    fi
}

# System prune
system_prune() {
    log "INFO" "Starting Docker system prune"
    echo "Performing final system cleanup..."
    
    if docker system prune -af >/dev/null 2>&1; then
        echo "  - System prune completed successfully"
        log "INFO" "System prune completed successfully"
    else
        echo "  - System prune failed"
        log "WARN" "System prune failed"
    fi
}

# Final verification
verify_cleanup() {
    log "INFO" "Verifying cleanup results"
    echo ""
    echo "Cleanup verification:"
    
    local containers=$(docker ps -aq 2>/dev/null | wc -l)
    local images=$(docker images -q 2>/dev/null | wc -l)
    local volumes=$(docker volume ls -q 2>/dev/null | wc -l)
    local networks=$(docker network ls --format "table {{.Name}}" | grep -v -E '^(bridge|host|none|NETWORK)$' | wc -l)
    
    echo "  - Remaining containers: $containers"
    echo "  - Remaining images: $images"
    echo "  - Remaining volumes: $volumes"
    echo "  - Remaining custom networks: $networks"
    
    log "INFO" "Cleanup verification completed - Containers: $containers, Images: $images, Volumes: $volumes, Networks: $networks"
}

# Main execution
main() {
    print_header
    
    # Check prerequisites
    check_docker
    
    # Show current state
    get_docker_state
    
    # Get user confirmation
    confirm_cleanup
    
    echo ""
    echo "Starting Docker environment cleanup..."
    echo ""
    
    # Execute cleanup steps
    stop_containers
    echo ""
    
    remove_containers
    echo ""
    
    remove_compose_stacks
    echo ""
    
    remove_images
    echo ""
    
    remove_volumes
    echo ""
    
    remove_networks
    echo ""
    
    clean_build_cache
    echo ""
    
    system_prune
    echo ""
    
    verify_cleanup
    
    echo ""
    echo "============================================================"
    echo "Docker cleanup completed successfully"
    echo "Log file saved to: $LOG_FILE"
    echo "============================================================"
    
    log "INFO" "Docker cleanup script completed successfully"
}

# Execute main function
main "$@"
