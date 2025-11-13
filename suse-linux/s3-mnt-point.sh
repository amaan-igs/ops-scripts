#!/bin/bash
# ------------------------------------------------------------------
# Installer Script: Mountpoint for Amazon S3 on SUSE Linux
# ------------------------------------------------------------------
# Author: Amaan Ul Haq Siddiqui - DevOps Engineer
# Purpose: Install Mountpoint for Amazon S3 in a standardized,
#          non-interactive, auditable manner for corporate environments
# Refrences:
#   - https://docs.aws.amazon.com/AmazonS3/latest/userguide/mountpoint-installation.html
#   - https://docs.aws.amazon.com/AmazonS3/latest/userguide/mountpoint-usage.html
# ------------------------------------------------------------------

set -euo pipefail
LOGFILE="$HOME/mountpoint-install.log"

# Function to log messages
log() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOGFILE"
}

log "Starting Mountpoint installation..."

# Check for root privileges
if [[ $EUID -ne 0 ]]; then
   log "This script requires root privileges. Please run with sudo."
   exit 1
fi

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)
        PKG_URL="https://s3.amazonaws.com/mountpoint-s3-release/latest/x86_64/mount-s3.tar.gz"
        SIG_URL="https://s3.amazonaws.com/mountpoint-s3-release/latest/x86_64/mount-s3.tar.gz.asc"
        ;;
    aarch64)
        PKG_URL="https://s3.amazonaws.com/mountpoint-s3-release/latest/arm64/mount-s3.tar.gz"
        SIG_URL="https://s3.amazonaws.com/mountpoint-s3-release/latest/arm64/mount-s3.tar.gz.asc"
        ;;
    *)
        log "Unsupported architecture: $ARCH"
        exit 1
        ;;
esac
log "Detected architecture: $ARCH"

# Install dependencies non-interactively
log "Installing FUSE dependencies and required tools..."
zypper --non-interactive refresh
zypper --non-interactive install fuse libfuse2 gnupg wget

# Create working directory
WORKDIR=$(mktemp -d)
cd "$WORKDIR" || exit 1

# Download package and signature
log "Downloading Mountpoint package and signature..."
wget -q "$PKG_URL" -O mount-s3.tar.gz
wget -q "$SIG_URL" -O mount-s3.tar.gz.asc

# Import AWS Mountpoint public key
log "Importing AWS Mountpoint public key..."
wget -q https://s3.amazonaws.com/mountpoint-s3-release/public_keys/KEYS -O KEYS
gpg --import KEYS

# Verify signature
log "Verifying package signature..."
if gpg --verify mount-s3.tar.gz.asc mount-s3.tar.gz; then
    log "Signature verification passed."
else
    log "Signature verification failed. Exiting."
    exit 1
fi

# Install Mountpoint
log "Installing Mountpoint to /opt/aws/mountpoint-s3..."
mkdir -p /opt/aws/mountpoint-s3
tar -C /opt/aws/mountpoint-s3 -xzf mount-s3.tar.gz

# Add to PATH if not already present
PROFILE="$HOME/.profile"
if ! grep -q "/opt/aws/mountpoint-s3/bin" "$PROFILE"; then
    log "Adding Mountpoint binary to PATH in $PROFILE"
    echo 'export PATH=$PATH:/opt/aws/mountpoint-s3/bin' >> "$PROFILE"
fi
source "$PROFILE"

# Verify installation
log "Verifying installation..."
VERSION=$(mount-s3 --version)
log "Installed Mountpoint version: $VERSION"

log "Mountpoint for Amazon S3 installation completed!"
