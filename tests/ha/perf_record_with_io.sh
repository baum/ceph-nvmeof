#!/bin/bash

# perf_record_with_io.sh - Performance recording with I/O operations
# This script records performance data while running I/O operations on the nvmeof target

set -e

# Configuration
PERF_BINARY="/data/code/linux/tools/perf/perf"
DURATION=${1:-30}  # Default 30 seconds if not provided
RESULTS_DIR="/tmp/nvmeof_perf_record_$(date +%Y%m%d_%H%M%S)"

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

# Function to find the nvmeof target process
find_nvmeof_target() {
    local container_id=$1
    local target_pid
    
    # Look for nvmf_tgt or reactor processes in the container
    target_pid=$(docker exec "$container_id" sh -c 'for pid in /proc/*/comm; do if [ -f "$pid" ] && grep -q "reactor" "$pid" 2>/dev/null; then echo "${pid%/comm}"; break; fi; done' 2>/dev/null | sed 's|/proc/||' | head -1)
    
    if [ -z "$target_pid" ]; then
        log_error "nvmf_tgt/reactor process not found in container $container_id"
        return 1
    fi
    
    echo "$target_pid"
}

# Function to check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check perf binary
    if [ ! -f "$PERF_BINARY" ]; then
        log_error "perf binary not found at $PERF_BINARY"
        exit 1
    fi
    log_success "perf binary found at $PERF_BINARY"
    
    # Check if docker is available
    if ! command -v docker >/dev/null 2>&1; then
        log_error "docker command not found"
        exit 1
    fi
    log_success "docker command found"
    
    # Check if we have a running nvmeof container
    local container_id
    container_id=$(docker ps --format '{{.ID}}\t{{.Names}}' | awk '$2 ~ /nvmeof/ && $2 ~ /1/ {print $1}' | head -1)
    
    if [ -z "$container_id" ]; then
        log_error "No nvmeof container found. Please start the gateway first."
        exit 1
    fi
    
    log_success "Found nvmeof container: $container_id"
    echo "$container_id"
}

# Function to run I/O operations in background
run_io_operations() {
    local duration=$1
    
    log_info "Starting I/O operations in background..."
    
    # Run I/O operations script in background
    ./tests/ha/run_io_while_recording.sh "$duration" &
    local io_pid=$!
    
    echo "$io_pid"
}

# Function to record performance data
record_performance() {
    local container_id=$1
    local target_pid=$2
    local duration=$3
    local io_pid=$4
    
    log_info "Starting performance recording for nvmeof target process (PID: $target_pid)"
    log_info "Duration: ${duration}s"
    
    # Create results directory
    mkdir -p "$RESULTS_DIR"
    
    # Record performance data
    local perf_data_file="$RESULTS_DIR/perf.data"
    local perf_script_file="$RESULTS_DIR/perf_script.txt"
    
    log_info "Recording performance data to: $perf_data_file"
    
    # Use perf record with the target process (need sudo for container process profiling)
    if ! sudo $PERF_BINARY record -g -p "$target_pid" -o "$perf_data_file" -- sleep "$duration"; then
        log_error "Failed to record performance data"
        return 1
    fi
    
    log_success "Performance recording completed"
    
    # Wait for I/O operations to complete
    if [ -n "$io_pid" ]; then
        log_info "Waiting for I/O operations to complete..."
        wait "$io_pid" 2>/dev/null || true
        log_success "I/O operations completed"
    fi
    
    # Generate perf script output for flame graph generation
    log_info "Generating perf script output..."
    if ! sudo $PERF_BINARY script -i "$perf_data_file" > "$perf_script_file" 2>/dev/null; then
        log_warning "Failed to generate perf script output"
    else
        log_success "Perf script output generated: $perf_script_file"
    fi
    
    # Generate basic perf report
    local perf_report_file="$RESULTS_DIR/perf_report.txt"
    log_info "Generating perf report..."
    if ! sudo $PERF_BINARY report -i "$perf_data_file" > "$perf_report_file" 2>&1; then
        log_warning "Failed to generate perf report"
    else
        log_success "Perf report generated: $perf_report_file"
    fi
    
    # Save metadata
    local metadata_file="$RESULTS_DIR/metadata.txt"
    {
        echo "=== Performance Recording Metadata ==="
        echo "Date: $(date)"
        echo "Duration: ${duration}s"
        echo "Container ID: $container_id"
        echo "Target PID: $target_pid"
        echo "Target Process: nvmf_tgt (reactor)"
        echo "Perf Binary: $PERF_BINARY"
        echo "Results Directory: $RESULTS_DIR"
        echo "I/O Operations: Enabled"
        echo ""
        echo "=== Files Generated ==="
        echo "Perf data: $perf_data_file"
        echo "Perf script: $perf_script_file"
        echo "Perf report: $perf_report_file"
        echo "Metadata: $metadata_file"
    } > "$metadata_file"
    
    log_success "Metadata saved to: $metadata_file"
}

# Main execution
main() {
    echo "🔥 NVMe-oF Target Performance Recording with I/O"
    echo "==============================================="
    echo ""
    
    # Check prerequisites and get container ID
    local container_id
    container_id=$(check_prerequisites)
    
    # Find the nvmeof target process
    local target_pid
    target_pid=$(find_nvmeof_target "$container_id")
    
    if [ -z "$target_pid" ]; then
        exit 1
    fi
    
    log_success "Found nvmeof target process: PID $target_pid"
    
    # Start I/O operations in background
    local io_pid
    io_pid=$(run_io_operations "$DURATION")
    
    # Record performance data
    record_performance "$container_id" "$target_pid" "$DURATION" "$io_pid"
    
    if [ $? -eq 0 ]; then
        echo ""
        log_success "Performance recording completed successfully!"
        echo "Results directory: $RESULTS_DIR"
        echo ""
        echo "Files created:"
        ls -la "$RESULTS_DIR"
        echo ""
        echo "To generate flame graphs, run:"
        echo "  ./tests/ha/flame_graph.sh $RESULTS_DIR"
    else
        log_error "Performance recording failed"
        exit 1
    fi
}

# Run main function
main "$@"












