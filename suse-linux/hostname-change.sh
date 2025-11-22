#!/bin/bash

# ------------------------------------------------------------------
# Installer Script: Mountpoint for Amazon S3 on SUSE Linux
# ------------------------------------------------------------------
# Author         : Amaan Ul Haq Siddiqui - DevOps Engineer
# Purpose        : Enterprise hostname configuration tool for SUSE Linux Enterprise
#                  This script performs permanent hostname modification across
#                  system configuration files and runtime settings
# ------------------------------------------------------------------

# Exit on any error
set -e

# Logging functions
log_info() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

log_success() {
    echo "[SUCCESS] $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Main execution
main() {
    log_info "Initiating hostname configuration procedure"
    
    # Prompt for new hostname
    echo ""
    read -p "Please enter the new hostname: " NEW_HOSTNAME
    echo ""
    
    # Validate hostname input
    if [ -z "$NEW_HOSTNAME" ]; then
        log_error "Hostname cannot be empty. Operation aborted."
        exit 1
    fi
    
    # Validate hostname format (RFC 1123)
    if ! [[ "$NEW_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
        log_error "Invalid hostname format. Must comply with RFC 1123 standards."
        exit 1
    fi
    
    log_info "Target hostname: $NEW_HOSTNAME"
    
    # Step 1: Apply hostname using hostnamectl
    log_info "Applying hostname configuration via hostnamectl"
    sudo hostnamectl set-hostname "$NEW_HOSTNAME"
    
    # Step 2: Update /etc/hostname
    log_info "Updating /etc/hostname configuration file"
    echo "$NEW_HOSTNAME" | sudo tee /etc/hostname > /dev/null
    
    # Step 3: Update /etc/hosts
    log_info "Configuring /etc/hosts entries"
    IP=$(hostname -I | awk '{print $1}')
    
    if [ -z "$IP" ]; then
        log_error "Unable to determine primary IP address"
        exit 1
    fi
    
    log_info "Primary IP address detected: $IP"
    
    # Remove existing IP entry
    sudo sed -i "/$IP/d" /etc/hosts
    
    # Update localhost entry
    sudo sed -i "/127.0.0.1/s/$/ $NEW_HOSTNAME/" /etc/hosts
    
    # Add new hostname to IP mapping
    echo "$IP    $NEW_HOSTNAME" | sudo tee -a /etc/hosts > /dev/null
    
    # Verification
    CURRENT_HOSTNAME=$(hostname)
    log_success "Hostname configuration completed successfully"
    log_info "Current hostname: $CURRENT_HOSTNAME"
    log_info "Please verify network connectivity and DNS resolution"
    echo ""
}

# Execute main function
main
