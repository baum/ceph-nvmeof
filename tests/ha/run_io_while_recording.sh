#!/bin/bash

# run_io_while_recording.sh - Run I/O operations while recording performance
# This script connects to the NVMe-oF namespace and runs I/O operations

set -e

# Configuration
GW_IP="192.168.13.3"
NQN="nqn.2016-06.io.spdk:perftest"
DURATION=${1:-30}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

# Function to connect to NVMe-oF namespace
connect_nvmeof() {
    log_info "Connecting to NVMe-oF namespace..."
    
    # Load kernel modules
    sudo modprobe nvme-core
    sudo modprobe nvme-fabrics
    sudo modprobe nvme-tcp
    
    # Connect to the namespace
    if sudo nvme connect -t tcp --traddr $GW_IP -s 4420 -n $NQN --data-digest; then
        log_success "Connected to NVMe-oF namespace"
        sleep 2
        
        # Find the device
        local device
        device=$(sudo nvme list | grep "Ceph bdev Controller" | awk '{print $1}' | head -1)
        
        if [ -n "$device" ]; then
            log_success "Found NVMe device: $device"
            echo "$device"
        else
            log_error "NVMe device not found"
            return 1
        fi
    else
        log_error "Failed to connect to NVMe-oF namespace"
        return 1
    fi
}

# Function to run I/O operations
run_io_operations() {
    local device=$1
    local duration=$2
    
    log_info "Running I/O operations for ${duration}s..."
    
    # Create filesystem if needed
    if ! sudo blkid "$device" >/dev/null 2>&1; then
        log_info "Creating filesystem on $device"
        sudo mkfs.ext4 -F "$device"
    fi
    
    # Mount the device
    local mount_point="/mnt/nvmeof_io_test"
    sudo mkdir -p "$mount_point"
    
    if ! mountpoint -q "$mount_point"; then
        sudo mount "$device" "$mount_point"
        log_success "Mounted $device to $mount_point"
    fi
    
    # Run I/O operations in background
    log_info "Starting I/O operations..."
    
    # Start dd operations
    (
        while [ $(($(date +%s) - START_TIME)) -lt $duration ]; do
            sudo dd if=/dev/random of="$mount_point/test_$(date +%s).dat" bs=32k count=100 2>/dev/null
            sleep 0.1
        done
    ) &
    
    local dd_pid=$!
    
    # Wait for the specified duration
    sleep $duration
    
    # Stop I/O operations
    kill $dd_pid 2>/dev/null || true
    wait $dd_pid 2>/dev/null || true
    
    log_success "I/O operations completed"
    
    # Cleanup
    sudo umount "$mount_point" 2>/dev/null || true
    sudo rmdir "$mount_point" 2>/dev/null || true
}

# Function to disconnect from NVMe-oF
disconnect_nvmeof() {
    local device=$1
    
    log_info "Disconnecting from NVMe-oF namespace..."
    
    if [ -n "$device" ]; then
        sudo nvme disconnect -d "$device" 2>/dev/null || true
    fi
    
    log_success "Disconnected from NVMe-oF namespace"
}

# Main execution
main() {
    echo "🔥 NVMe-oF I/O Operations"
    echo "========================"
    echo ""
    
    START_TIME=$(date +%s)
    
    # Connect to NVMe-oF
    local device
    device=$(connect_nvmeof)
    
    if [ -z "$device" ]; then
        exit 1
    fi
    
    # Run I/O operations
    run_io_operations "$device" "$DURATION"
    
    # Disconnect
    disconnect_nvmeof "$device"
    
    log_success "I/O operations completed successfully!"
}

# Run main function
main "$@"












