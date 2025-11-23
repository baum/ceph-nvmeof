#!/bin/bash

# cleanup_environment.sh - Comprehensive cleanup script for Ceph-NVMeoF environment
# This script performs a complete cleanup of the testing environment

set -e

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

# Configuration
MOUNT_POINT="/mnt/nvmeof_perf_test"
NVME_PORTS="4420 5500 8009 10008"

# Step 1: Clean up NVMe devices and mounts
unmount_devices() {
    log_info "Step 1: Cleaning up NVMe devices and mounts..."
    
    # Check for mounted devices
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        log_info "Unmounting $MOUNT_POINT..."
        sudo umount "$MOUNT_POINT"
        log_success "Unmounted $MOUNT_POINT"
    else
        log_info "No device mounted at $MOUNT_POINT (using direct block device I/O)"
    fi
    
    # Check for other NVMe mounts
    local other_mounts=$(mount | grep -E "(nvme|nvmf)" | awk '{print $3}' || true)
    if [ -n "$other_mounts" ]; then
        log_info "Found other NVMe mounts, unmounting..."
        for mount in $other_mounts; do
            sudo umount "$mount" 2>/dev/null && log_success "Unmounted $mount" || log_warning "Failed to unmount $mount"
        done
    fi
    
    # Remove mount point directory
    sudo rmdir "$MOUNT_POINT" 2>/dev/null && log_success "Removed mount point directory" || log_info "Mount point directory already clean"
}

# Step 2: Disconnect NVMe-oF devices
disconnect_nvmeof() {
    log_info "Step 2: Disconnecting NVMe-oF devices..."
    
    # Check for active connections
    local connections=$(sudo nvme list 2>/dev/null | grep "Ceph bdev Controller" | wc -l || echo "0")
    if [ "$connections" -gt 0 ]; then
        log_info "Found $connections NVMe-oF connections, disconnecting..."
        sudo nvme disconnect-all 2>/dev/null
        log_success "Disconnected all NVMe-oF devices"
    else
        log_info "No NVMe-oF connections found"
    fi
}

# Step 3: Stop Docker containers
stop_containers() {
    log_info "Step 3: Stopping Docker containers and services..."
    
    # Stop docker compose services
    if docker compose ps >/dev/null 2>&1; then
        log_info "Stopping docker compose services..."
        docker compose down
        log_success "Docker compose services stopped"
    else
        log_info "No docker compose services running"
    fi
    
    # Check for any remaining NVMe-oF related containers
    local containers=$(docker ps --format "table {{.Names}}" | grep -E "(nvmeof|ceph)" | wc -l || echo "0")
    if [ "$containers" -gt 0 ]; then
        log_warning "Found $containers remaining containers, stopping them..."
        docker ps --format "table {{.Names}}" | grep -E "(nvmeof|ceph)" | xargs -r docker stop
        log_success "Stopped remaining containers"
    fi
}

# Step 4: Clean up processes
cleanup_processes() {
    log_info "Step 4: Checking for remaining processes..."
    
    # Check for NVMe-oF related processes
    local processes=$(ps aux | grep -E "(nvmf|reactor)" | grep -v grep | wc -l || echo "0")
    if [ "$processes" -gt 0 ]; then
        log_warning "Found $processes NVMe-oF related processes"
        ps aux | grep -E "(nvmf|reactor)" | grep -v grep
    else
        log_success "No NVMe-oF processes running"
    fi
}

# Step 5: Check network ports
check_network_ports() {
    log_info "Step 5: Checking network ports..."
    
    local ports_in_use=""
    for port in $NVME_PORTS; do
        if ss -tlnp | grep -q ":$port "; then
            ports_in_use="$ports_in_use $port"
        fi
    done
    
    if [ -n "$ports_in_use" ]; then
        log_warning "Ports still in use:$ports_in_use"
        ss -tlnp | grep -E "($(echo $NVME_PORTS | tr ' ' '|'))"
    else
        log_success "No NVMe-oF ports in use"
    fi
}

# Step 6: Verify cleanup
verify_cleanup() {
    log_info "Step 6: Verifying cleanup..."
    
    echo ""
    echo "📊 CLEANUP VERIFICATION:"
    echo "======================="
    
    # Check containers
    local containers=$(docker ps | grep -E "(nvmeof|ceph)" | wc -l || echo "0")
    if [ "$containers" -eq 0 ]; then
        log_success "No NVMe-oF containers running"
    else
        log_warning "$containers NVMe-oF containers still running"
    fi
    
    # Check NVMe devices
    local devices=$(sudo nvme list 2>/dev/null | grep "Ceph bdev Controller" | wc -l)
    if [ "$devices" -eq 0 ]; then
        log_success "No NVMe-oF devices found"
    else
        log_warning "$devices NVMe-oF devices still present"
    fi
    
    # Check mounts
    local mounts=$(mount | grep -E "(nvme|nvmf)" | wc -l || echo "0")
    if [ "$mounts" -eq 0 ]; then
        log_success "No NVMe mounts found (direct block device I/O mode)"
    else
        log_warning "$mounts NVMe mounts still present"
    fi
    
    # Check processes
    local processes=$(ps aux | grep -E "(nvmf|reactor)" | grep -v grep | wc -l || echo "0")
    if [ "$processes" -eq 0 ]; then
        log_success "No NVMe-oF processes running"
    else
        log_warning "$processes NVMe-oF processes still running"
    fi
}

# Main cleanup function
main() {
    echo "🧹 CEPH-NVMEOF ENVIRONMENT CLEANUP"
    echo "=================================="
    echo ""
    
    # Perform cleanup steps
    unmount_devices
    disconnect_nvmeof
    stop_containers
    cleanup_processes
    check_network_ports
    verify_cleanup
    
    echo ""
    log_success "🎉 CLEANUP COMPLETED!"
    echo ""
    echo "✅ Environment is now clean and ready for a fresh start"
    echo ""
    echo "🚀 To start fresh:"
    echo "  make setup"
    echo "  ./tests/ha/start_up.sh 1"
}

# Run cleanup
main "$@"

