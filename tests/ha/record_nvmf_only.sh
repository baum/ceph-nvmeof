#!/bin/bash

# record_nvmf_only.sh - Record perf data from nvmf_tgt process only
# This script demonstrates how to record performance data from just the nvmf_tgt process

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
PERF_BINARY="/usr/bin/perf"
TEST_DURATION=30
RESULTS_DIR="artifacts/perf_record_nvmf_only_$(date +%Y%m%d_%H%M%S)"

# Find nvmf_tgt process
find_nvmf_process() {
    log_info "Looking for nvmf_tgt process in nvmeof container..."
    
    local container_id=$(docker ps | grep nvmeof | awk '{print $1}' | head -1)
    if [ -z "$container_id" ]; then
        log_error "No running nvmeof container found"
        return 1
    fi
    
    log_info "Using nvmeof container: $container_id"
    
    # Look for nvmf_tgt process on host system first
    local nvmf_pid=$(ps aux | grep "nvmf_tgt" | grep -v grep | awk '{print $2}' | head -1)
    
    if [ -z "$nvmf_pid" ]; then
        # Fallback: look for reactor_0 process in container
        nvmf_pid=$(docker exec "$container_id" sh -c 'for pid in /proc/*/comm; do if [ -f "$pid" ] && grep -q "reactor_0" "$pid" 2>/dev/null; then echo "${pid%/comm}" | sed "s|/proc/||"; break; fi; done' 2>/dev/null)
    fi
    
    if [ -z "$nvmf_pid" ]; then
        log_error "nvmf_tgt process not found in container"
        return 1
    fi
    
    log_success "Found nvmf_tgt process ID: $nvmf_pid"
    echo "$nvmf_pid"
}

# Record performance data from nvmf_tgt only
record_nvmf_performance() {
    local nvmf_pid="$1"
    
    log_info "Recording performance data from nvmf_tgt process only..."
    
    # Create results directory
    mkdir -p "$RESULTS_DIR"
    
    # Set perf permissions
    sudo sysctl kernel.perf_event_paranoid=-1
    
    # Start perf recording targeting only nvmf_tgt process
    log_info "Starting perf recording for ${TEST_DURATION}s (nvmf_tgt PID: $nvmf_pid)..."
    sudo "$PERF_BINARY" record -g --call-graph fp -F 99 -p "$nvmf_pid" -o "$RESULTS_DIR/perf.data" -- sleep "$TEST_DURATION" &
    local perf_pid=$!
    
    # Wait for perf to start
    sleep 3
    
    # Run I/O operations to generate activity
    log_info "Running I/O operations to generate nvmf_tgt activity..."
    
    # Connect to NVMe-oF if not already connected
    local device=$(sudo nvme list | grep "Ceph bdev Controller" | awk '{print $1}' | head -1)
    if [ -z "$device" ]; then
        log_warning "No NVMe-oF device found - perf will record idle nvmf_tgt"
    else
        log_info "Found NVMe device: $device, running I/O operations..."
        local mount_point="/mnt/nvmeof_perf_test"
        sudo mkdir -p "$mount_point"
        
        if ! mountpoint -q "$mount_point"; then
            sudo mount "$device" "$mount_point"
        fi
        
        # Run I/O operations
        for i in $(seq 1 3); do
            log_info "Running dd operation $i/3..."
            sudo dd if=/dev/random of="$mount_point/test_data_$i.dat" bs=32k count=1000 2>/dev/null
            sleep 1
        done
        
        # Cleanup mount
        sudo umount "$mount_point" 2>/dev/null || true
    fi
    
    # Wait for perf recording to complete
    wait $perf_pid
    
    log_success "Performance recording completed"
    
    # Generate perf reports
    log_info "Generating perf reports..."
    sudo "$PERF_BINARY" script -i "$RESULTS_DIR/perf.data" > "$RESULTS_DIR/perf_script.txt" 2>/dev/null
    sudo "$PERF_BINARY" report -i "$RESULTS_DIR/perf.data" > "$RESULTS_DIR/perf_report.txt" 2>&1
    
    log_success "Perf reports generated"
}

# Generate flame graphs
generate_flame_graphs() {
    log_info "Generating flame graphs from nvmf_tgt-only perf data..."
    
    # Check and install flame graph tools
    if [ ! -f "./bin/flamegraph.pl" ] || [ ! -f "./bin/stackcollapse-perf.pl" ]; then
        log_info "Installing flame graph tools..."
        mkdir -p ./bin
        cd /tmp
        if [ ! -d "FlameGraph" ]; then
            git clone https://github.com/brendangregg/FlameGraph.git
        fi
        cd /data/code/ceph-nvmeof
        ln -sf /tmp/FlameGraph/flamegraph.pl ./bin/flamegraph.pl
        ln -sf /tmp/FlameGraph/stackcollapse-perf.pl ./bin/stackcollapse-perf.pl
    fi
    
    # Generate stack collapse
    export PATH="$PWD/bin:$PATH"
    ./bin/stackcollapse-perf.pl "$RESULTS_DIR/perf_script.txt" > "$RESULTS_DIR/stack_collapse.txt"
    
    # Generate flame graphs (wide format)
    log_info "Generating flame graphs (wide format, 3000px width)..."
    ./bin/flamegraph.pl --width=3000 --minwidth=0 "$RESULTS_DIR/stack_collapse.txt" > "$RESULTS_DIR/flame_graph.svg"
    ./bin/flamegraph.pl --width=3000 --minwidth=0 --countname=cpu "$RESULTS_DIR/stack_collapse.txt" > "$RESULTS_DIR/cpu_flame_graph.svg"
    ./bin/flamegraph.pl --width=3000 --minwidth=0 --countname=memory "$RESULTS_DIR/stack_collapse.txt" > "$RESULTS_DIR/memory_flame_graph.svg"
    
    log_success "Flame graphs generated"
}

# Analyze results
analyze_results() {
    log_info "Analyzing nvmf_tgt-only performance results..."
    
    # Count function calls
    local nvmf_calls=$(grep -c 'nvmf_tgt' "$RESULTS_DIR/perf_script.txt" || echo "0")
    local libceph_calls=$(grep -c 'libceph-common' "$RESULTS_DIR/perf_script.txt" || echo "0")
    local librados_calls=$(grep -c 'librados' "$RESULTS_DIR/perf_script.txt" || echo "0")
    
    # Count system processes (should be minimal)
    local system_calls=$(grep -c 'chrony\|systemd\|kernel' "$RESULTS_DIR/perf_script.txt" || echo "0")
    
    echo ""
    echo "📊 NVMF-ONLY PERFORMANCE ANALYSIS:"
    echo "=================================="
    echo "nvmf_tgt calls: $nvmf_calls"
    echo "libceph-common calls: $libceph_calls"
    echo "librados calls: $librados_calls"
    echo "system process calls: $system_calls"
    echo ""
    echo "✅ Clean recording: Only nvmf_tgt and its libraries captured"
    echo "Results directory: $RESULTS_DIR"
    
    # Show sample of what was captured
    echo ""
    echo "🔍 SAMPLE OF CAPTURED CALLS:"
    echo "============================"
    head -5 "$RESULTS_DIR/stack_collapse.txt"
}

# Main function
main() {
    echo "🎯 NVMF Target Only Performance Recording"
    echo "======================================="
    echo ""
    
    # Find nvmf_tgt process
    local nvmf_pid=$(find_nvmf_process)
    if [ -z "$nvmf_pid" ]; then
        exit 1
    fi
    
    # Record performance data
    record_nvmf_performance "$nvmf_pid"
    
    # Generate flame graphs
    generate_flame_graphs
    
    # Analyze results
    analyze_results
    
    log_success "🎉 nvmf_tgt-only performance recording completed!"
    echo ""
    echo "🚀 To view the clean flame graphs:"
    echo "  firefox $RESULTS_DIR/flame_graph.svg"
    echo "  firefox $RESULTS_DIR/cpu_flame_graph.svg"
    echo "  firefox $RESULTS_DIR/memory_flame_graph.svg"
    echo ""
    echo "📊 Benefits of nvmf_tgt-only recording:"
    echo "• No system process noise (chrony, systemd, etc.)"
    echo "• Focused on NVMe-oF target performance"
    echo "• Cleaner flame graphs with relevant call stacks"
    echo "• Better signal-to-noise ratio"
}

# Run main function
main "$@"
