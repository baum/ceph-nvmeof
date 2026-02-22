#!/bin/bash

# perf_record.sh - Performance recording script for nvmeof target process
# This script profiles the nvmeof target process running in the gateway container

set -e

# Configuration
PERF_BINARY="/data/code/linux/tools/perf/perf"
DURATION=${1:-30}  # Default 30 seconds if not provided
RESULTS_DIR="$(pwd)/artifacts/perf_record_$(date +%Y%m%d_%H%M%S)"

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
    # The nvmf_tgt process shows up as reactor_0, reactor_1, etc.
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
}

# Function to record performance data
record_performance() {
    local container_id=$1
    local target_pid=$2
    local duration=$3
    
    log_info "Starting performance recording for nvmeof target process (PID: $target_pid)"
    log_info "Duration: ${duration}s"
    
    # Create results directory
    mkdir -p "$RESULTS_DIR"
    
    # Record performance data
    local perf_data_file="$RESULTS_DIR/perf.data"
    local perf_script_file="$RESULTS_DIR/perf_script.txt"
    
    log_info "Recording performance data to: $perf_data_file"
    
    # Use perf record system-wide (works better for containerized processes)
    # Use -F 99 for 99Hz sampling and --call-graph fp for better stack traces
    if ! sudo $PERF_BINARY record -g --call-graph fp -F 99 -a -o "$perf_data_file" -- sleep "$duration"; then
        log_error "Failed to record performance data"
        return 1
    fi
    
    log_success "Performance recording completed"
    
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
        echo "Target Process: nvmf_tgt"
        echo "Perf Binary: $PERF_BINARY"
        echo "Results Directory: $RESULTS_DIR"
        echo ""
        echo "=== Files Generated ==="
        echo "Perf data: $perf_data_file"
        echo "Perf script: $perf_script_file"
        echo "Perf report: $perf_report_file"
        echo "Metadata: $metadata_file"
    } > "$metadata_file"
    
    log_success "Metadata saved to: $metadata_file"
    
    # Set global results directory
    RESULTS_DIR="$RESULTS_DIR"
}

# Global variables
CONTAINER_ID=""
TARGET_PID=""
RESULTS_DIR=""

# Main execution
main() {
    echo "🔥 NVMe-oF Target Performance Recording"
    echo "======================================"
    echo ""
    
    # Check prerequisites and get container ID
    check_prerequisites
    CONTAINER_ID=$(docker ps --format '{{.ID}}\t{{.Names}}' | awk '$2 ~ /nvmeof/ && $2 ~ /1/ {print $1}' | head -1)
    
    # Find the nvmeof target process
    find_nvmeof_target "$CONTAINER_ID"
    TARGET_PID=$(docker exec "$CONTAINER_ID" sh -c 'for pid in /proc/*/comm; do if [ -f "$pid" ] && grep -q "reactor" "$pid" 2>/dev/null; then echo "${pid%/comm}"; break; fi; done' 2>/dev/null | sed 's|/proc/||' | head -1)
    
    if [ -z "$TARGET_PID" ]; then
        log_error "nvmf_tgt/reactor process not found in container $CONTAINER_ID"
        exit 1
    fi
    
    log_success "Found nvmeof target process: PID $TARGET_PID"
    
    # Set results directory
    RESULTS_DIR="$(pwd)/artifacts/perf_record_$(date +%Y%m%d_%H%M%S)"
    
    # Record performance data
    record_performance "$CONTAINER_ID" "$TARGET_PID" "$DURATION"
    
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
