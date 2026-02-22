#!/bin/bash

# robust_perf_test.sh - performance test with verification and cleanup
# This script:
# 0. Loads required kernel modules for NVMe-oF
# 1. Verifies clean system state (no mounts, no gateway)
# 2. Starts clean gateway setup
# 3. Creates NVMe-oF namespace with RBD backend
# 4. Connects to namespace and runs sustained asynchronous high-intensity write operations
# 5. Records performance data during continuous overlapping write workload to Ceph device
# 6. Generates flame graphs
# 7. Provides results analysis

set -e

# Configuration
NQN="nqn.2016-06.io.spdk:perftest"
NAMESPACE_SIZE="64MB"
BLOCK_SIZE="32k"
# Container-based perf (installed in nvmeof container)
CONTAINER_ID=""
PERF_BINARY="docker exec \$CONTAINER_ID /usr/bin/perf"
TEST_DURATION=30  # seconds
RESULTS_DIR="$(pwd)/artifacts/perf_record_$(date +%Y%m%d_%H%M%S)"

# I/O Configuration for sustained high-intensity workload
IO_THREADS=3          # Number of parallel I/O threads
IO_CHUNK_SIZE=512     # Blocks per operation (16MB with 32k blocks)
IO_CONCURRENT_OPS=3   # Maximum concurrent operations per thread (no sleep model)

# Performance test specific configuration
# - Limits reactor threads to 1 using -m 1 for predictable profiling
# - Optimized for performance analysis
export NVMEOF_CONFIG=./tests/ceph-nvmeof.perf-test.conf

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

gw_name() {
    local i=$1
    docker ps --format '{{.ID}}\t{{.Names}}' | awk '$2 ~ /nvmeof/ && $2 ~ /'$i'/ {print $1}'
}

gw_ip() {
    local gw_id=$1
    docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$gw_id"
}

# Step 0: Load required kernel modules
load_kernel_modules() {
    log_info "Loading required kernel modules for NVMe-oF..."
    
    # List of required kernel modules for NVMe-oF (in dependency order)
    local required_modules=(
        "nvme-core"
        "nvme"
        "nvme-fabrics"
        "nvme-tcp"
        "nvme-rdma"
    )
    
    local loaded_modules=()
    local failed_modules=()
    
    for module in "${required_modules[@]}"; do
        if sudo modprobe "$module" 2>/dev/null; then
            log_success "Loaded kernel module: $module"
            loaded_modules+=("$module")
        else
            # Check if module is already loaded
            if lsmod | grep -q "^$module "; then
                log_info "Kernel module already loaded: $module"
                loaded_modules+=("$module")
            else
                log_warning "Failed to load kernel module: $module"
                failed_modules+=("$module")
            fi
        fi
    done
    
    # Verify nvme CLI is available
    if ! command -v nvme &> /dev/null; then
        log_error "nvme CLI not found. Please install nvme-cli package."
        return 1
    fi
    
    # Check if any NVMe modules are loaded and verify system support
    local nvme_modules_loaded=$(lsmod | grep nvme | wc -l)
    if [ "$nvme_modules_loaded" -eq 0 ]; then
        log_warning "No NVMe kernel modules loaded. NVMe-oF may not work properly."
        log_info "Trying to load core NVMe module manually..."
        if sudo modprobe nvme-core 2>/dev/null; then
            log_success "Successfully loaded nvme-core module"
        else
            log_error "Failed to load nvme-core module. NVMe-oF functionality may be limited."
        fi
    else
        log_success "NVMe kernel modules are loaded ($nvme_modules_loaded modules)"
    fi
    
    # Check if NVMe device classes are available
    if [ -d "/sys/class/nvme" ] || [ -d "/sys/class/nvme-fabrics" ]; then
        log_success "NVMe device classes are available"
    else
        log_warning "NVMe device classes not found, but modules are loaded"
    fi
    
    log_success "Kernel module loading completed"
    log_info "Loaded modules: ${loaded_modules[*]}"
    if [ ${#failed_modules[@]} -gt 0 ]; then
        log_warning "Failed to load: ${failed_modules[*]}"
    fi
    
    # Display current NVMe modules
    log_info "Current NVMe-related kernel modules:"
    lsmod | grep nvme || log_info "No NVMe modules currently loaded"
}

# Step 1: Verify clean system state
verify_clean_state() {
    log_info "Verifying clean system state..."
    
    # Check for NVMe mounts (for compatibility with previous tests)
    local nvme_mounts=$(mount | grep nvme | wc -l)
    if [ "$nvme_mounts" -gt 0 ]; then
        log_warning "Found $nvme_mounts NVMe mounts (will be cleaned up automatically)"
        mount | grep nvme
    else
        log_success "No NVMe mounts found"
    fi
    
    # Check for NVMe-oF connections
    local nvme_connections=$(sudo nvme list 2>/dev/null | grep -c "Ceph bdev Controller" 2>/dev/null || true)
    if [ "${nvme_connections:-0}" -gt 0 ]; then
        log_error "Found $nvme_connections NVMe-oF connections. Please disconnect them first:"
        sudo nvme list | grep "Ceph bdev Controller"
        return 1
    fi
    log_success "No NVMe-oF connections found"
    
    # Check for running containers
    local running_containers=$(docker ps | grep -E "(nvmeof|ceph)" | wc -l)
    if [ "$running_containers" -gt 0 ]; then
        log_error "Found $running_containers running containers. Please stop them first:"
        docker ps | grep -E "(nvmeof|ceph)"
        return 1
    fi
    log_success "No running containers found"
    
    log_success "System state is clean - ready to proceed"
}

# Step 2: Setup environment and start gateway
setup_and_start_gateway() {
    log_info "Setting up environment and starting gateway..."
    
    # Setup huge pages
    log_info "Setting up huge pages..."
    make setup
    
    # Clean any existing setup
    log_info "Cleaning any existing setup..."
    make down
    
    # Start gateway
    log_info "Starting gateway..."
    ./tests/ha/start_up.sh 1
    
    # Wait for gateway to be ready
    log_info "Waiting for gateway to be ready..."
    sleep 15
    
    # Verify gateway is running
    local gw_id=$(gw_name 1)
    if [ -z "$gw_id" ]; then
        log_error "Gateway not found after startup"
        return 1
    fi
    
    local gw_ip=$(gw_ip "$gw_id")
    if [ -z "$gw_ip" ]; then
        log_error "Could not get gateway IP"
        return 1
    fi
    
    log_success "Gateway started: $gw_id ($gw_ip)"
    
    # Wait for gRPC service
    log_info "Waiting for gRPC service..."
    local timeout=30
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        if docker compose run --rm nvmeof-cli --server-address "$gw_ip" --server-port 5500 get_subsystems >/dev/null 2>&1; then
            log_success "gRPC service is ready"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    
    log_error "gRPC service not ready after ${timeout}s"
    return 1
}

# Step 3: Create NVMe-oF namespace
create_namespace() {
    local gw_id=$(gw_name 1)
    local gw_ip=$(gw_ip "$gw_id")
    
    log_info "Creating NVMe-oF namespace..."
    
    # Create subsystem
    log_info "Creating subsystem: $NQN"
    if ! docker compose run --rm nvmeof-cli --server-address "$gw_ip" --server-port 5500 subsystem add --subsystem "$NQN" --no-group-append; then
        log_error "Failed to create subsystem"
        return 1
    fi
    
    # Create namespace with RBD backend
    log_info "Creating namespace with RBD backend..."
    if ! docker compose run --rm nvmeof-cli --server-address "$gw_ip" --server-port 5500 namespace add --subsystem "$NQN" --rbd-pool rbd --rbd-image perf_test_image --size "$NAMESPACE_SIZE" --rbd-create-image -l 1; then
        log_error "Failed to create namespace"
        return 1
    fi
    
    # Add listener
    log_info "Adding listener on port 4420..."
    if ! docker compose run --rm nvmeof-cli --server-address "$gw_ip" --server-port 5500 listener add --subsystem "$NQN" --host-name "$gw_id" --traddr "$gw_ip" --trsvcid 4420; then
        log_error "Failed to add listener"
        return 1
    fi
    
    # Add host
    log_info "Adding host..."
    if ! docker compose run --rm nvmeof-cli --server-address "$gw_ip" --server-port 5500 host add --subsystem "$NQN" --host-nqn "*"; then
        log_error "Failed to add host"
        return 1
    fi
    
    log_success "NVMe-oF namespace created successfully"
}

# Note: perf is now installed during image build in Dockerfile.spdk

# Step 4: Connect to namespace
connect_to_namespace() {
    local gw_ip=$(gw_ip "$(gw_name 1)")
    
    log_info "Connecting to NVMe-oF namespace..."
    
    # Load kernel modules
    log_info "Loading NVMe kernel modules..."
    sudo modprobe nvme-core nvme-fabrics nvme-tcp
    
    # Verify modules are loaded
    if ! lsmod | grep -q nvme_fabrics; then
        log_error "nvme-fabrics module not loaded"
        return 1
    fi
    
    # Verify nvme-fabrics device exists
    if [ ! -c /dev/nvme-fabrics ]; then
        log_error "/dev/nvme-fabrics device not found"
        return 1
    fi
    
    log_success "NVMe modules loaded and devices available"
    
    # Connect to namespace
    log_info "Connecting to namespace..."
    if ! sudo nvme connect -t tcp --traddr "$gw_ip" -s 4420 -n "$NQN" --data-digest; then
        log_error "Failed to connect to NVMe-oF namespace"
        return 1
    fi
    
    # Find the device
    sleep 2
    local device=$(sudo nvme list | grep "Ceph bdev Controller" | awk '{print $1}' | head -1)
    if [ -z "$device" ]; then
        log_error "NVMe device not found"
        return 1
    fi
    
    log_success "Connected to device: $device"
    
    # Store device globally for direct I/O operations
    NVME_DEVICE="$device"
    
    log_info "Using direct block device I/O"
    log_success "Ready for direct block device operations"
}

# Step 5: Record performance data with I/O operations
record_performance_with_io() {
    log_info "Recording performance data with I/O operations..."
    
    # Create results directory
    mkdir -p "$RESULTS_DIR"
    
    # Copy configuration file to artifacts for reference
    log_info "Copying configuration file to artifacts..."
    cp "$NVMEOF_CONFIG" "$RESULTS_DIR/gateway_config.conf"
    log_success "Configuration file copied to $RESULTS_DIR/gateway_config.conf"
    
    # Get container ID
    CONTAINER_ID=$(docker ps | grep nvmeof | awk '{print $1}' | head -1)
    if [ -z "$CONTAINER_ID" ]; then
        log_error "No running nvmeof container found"
        return 1
    fi
    log_info "Using container: $CONTAINER_ID"
    
    # Note: perf is now installed during image build in Dockerfile.spdk
    
    # Set perf permissions on host
    sudo sysctl kernel.perf_event_paranoid=-1
    
    # Find the reactor_0 process ID in container (nvmf_tgt appears as reactor_0)
    # Use /proc filesystem since ps may not be available in container
    local nvmf_pid=$(docker exec "$CONTAINER_ID" sh -c 'for pid in /proc/[0-9]*; do if [ -f "$pid/comm" ] && grep -q "reactor_0" "$pid/comm" 2>/dev/null; then echo "$(basename $pid)"; break; fi; done')
    
    if [ -z "$nvmf_pid" ]; then
        log_error "reactor_0 process ID not found in container (nvmf_tgt not running)"
        return 1
    fi
    
    log_info "Found reactor_0 process ID in container: $nvmf_pid (nvmf_tgt)"
    
    # Start perf recording in container
    log_info "Starting perf recording in container for ${TEST_DURATION}s..."
    docker exec "$CONTAINER_ID" /usr/bin/perf record -p "$nvmf_pid" -g -o /tmp/perf.data sleep "$TEST_DURATION" &
    local perf_pid=$!
    
    # Wait for perf to start
    sleep 3
    
    # Run sustained write operations to Ceph device throughout the test duration
    log_info "Running sustained write operations to Ceph device during recording..."
    
    # Calculate I/O parameters for sustainable high-intensity workload
    local total_blocks=$((64 * 1024 / 32))  # 2048 blocks in 64MB namespace
    local chunk_size=$IO_CHUNK_SIZE  # Configurable chunk size for continuous I/O
    local num_chunks=$((total_blocks / chunk_size))  # Number of chunks to cycle through
    
    log_info "Write I/O Configuration (No-Sleep Model):"
    log_info "  - Total blocks: $total_blocks (64MB)"
    log_info "  - Chunk size: $chunk_size blocks ($((chunk_size * 32 / 1024))MB)"
    log_info "  - Number of chunks: $num_chunks"
    log_info "  - Block size: $BLOCK_SIZE"
    log_info "  - I/O threads: $IO_THREADS"
    log_info "  - Concurrent write operations per thread: $IO_CONCURRENT_OPS"
    log_info "  - Model: Asynchronous overlapping write I/O to Ceph device"
    
    # Start multiple parallel I/O operations for sustained load
    local io_pids=()
    
    # Function to run continuous asynchronous I/O operations
    run_sustained_io() {
        local io_id=$1
        local operation_count=0
        local active_ops=0
        local max_concurrent=$IO_CONCURRENT_OPS  # Maximum concurrent operations per thread
        
        while kill -0 $perf_pid 2>/dev/null; do
            # Start multiple concurrent operations without waiting
            for ((j=0; j<max_concurrent; j++)); do
                # Cycle through different offsets for variety
                local offset=$(((operation_count + j) % num_chunks * chunk_size))
                
                # Write operations to Ceph device only (no reads)
                sudo dd if=/dev/random of="$NVME_DEVICE" bs="$BLOCK_SIZE" count="$chunk_size" seek="$offset" 2>/dev/null &
                
                active_ops=$((active_ops + 1))
            done
            
            operation_count=$((operation_count + max_concurrent))
            
            # Wait for some operations to complete before starting more
            # This creates natural pacing without artificial sleep
            wait 2>/dev/null || true
            active_ops=$((active_ops - 1))
            
            # Only start new operations if we have room
            if [ $active_ops -lt $max_concurrent ]; then
                continue
            fi
        done
        
        # Wait for any remaining operations to complete
        wait 2>/dev/null || true
        
        log_info "I/O thread $io_id completed $operation_count operations"
    }
    
    # Start multiple I/O threads for sustained load
    log_info "Starting sustained I/O operations..."
    for i in $(seq 1 $IO_THREADS); do
        run_sustained_io $i &
        io_pids+=($!)
        log_info "Started I/O thread $i (PID: $!)"
    done
    
    # Wait for perf recording to complete
    wait $perf_pid
    
    # Stop I/O operations
    log_info "Stopping I/O operations..."
    for pid in "${io_pids[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null || true
            log_info "Stopped I/O thread (PID: $pid)"
        fi
    done
    
    # Copy perf data from container to host
    log_info "Copying perf data from container..."
    docker cp "$CONTAINER_ID:/tmp/perf.data" "$RESULTS_DIR/perf.data"
    
    log_success "Performance recording completed"
    
    # Generate perf reports using container-based perf (with built-in symbol resolution)
    log_info "Generating perf reports with container-based symbol resolution..."
    docker exec "$CONTAINER_ID" /usr/bin/perf script -i /tmp/perf.data > "$RESULTS_DIR/perf_script.txt" 2>/dev/null
    docker exec "$CONTAINER_ID" /usr/bin/perf report -i /tmp/perf.data > "$RESULTS_DIR/perf_report.txt" 2>&1
    
    log_success "Perf reports generated with container-based symbol resolution"
}

# Note: Manual symbol resolution removed - perf now runs inside container with built-in symbol resolution
# Step 7: Generate flame graphs using container-based symbol resolution
generate_flame_graphs() {
    log_info "Generating flame graphs using container-based symbol resolution..."
    
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
    
    # Generate stack collapse using perf script with container-based symbol resolution
    export PATH="$PWD/bin:$PATH"
    log_info "Using perf script with container-based symbol resolution for stack collapse"
    ./bin/stackcollapse-perf.pl "$RESULTS_DIR/perf_script.txt" > "$RESULTS_DIR/stack_collapse.txt"
    
    # Generate flame graphs using container-based symbol resolution (wide format to prevent truncation)
    log_info "Generating flame graphs with container-based symbol resolution (100000px width)..."
    ./bin/flamegraph.pl --width=100000 --minwidth=0 "$RESULTS_DIR/stack_collapse.txt" > "$RESULTS_DIR/flame_graph.svg"
    ./bin/flamegraph.pl --width=100000 --minwidth=0 --countname=cpu "$RESULTS_DIR/stack_collapse.txt" > "$RESULTS_DIR/cpu_flame_graph.svg"
    ./bin/flamegraph.pl --width=100000 --minwidth=0 --countname=memory "$RESULTS_DIR/stack_collapse.txt" > "$RESULTS_DIR/memory_flame_graph.svg"
    
    log_success "Flame graphs generated with container-based symbol resolution"
}

# Step 8: Analyze results
analyze_results() {
    log_info "Analyzing performance results..."
    
    # Count function calls
    local nvmf_calls=$(grep -c 'nvmf_tgt' "$RESULTS_DIR/perf_script.txt" || echo "0")
    local libceph_calls=$(grep -c 'libceph-common' "$RESULTS_DIR/perf_script.txt" || echo "0")
    local librados_calls=$(grep -c 'librados' "$RESULTS_DIR/perf_script.txt" || echo "0")
    
    # Count resolved symbols from stack_collapse.txt (container-based symbol resolution)
    local resolved_symbols=0
    local total_symbols=0
    if [ -f "$RESULTS_DIR/stack_collapse.txt" ]; then
        total_symbols=$(wc -l < "$RESULTS_DIR/stack_collapse.txt" || echo "0")
        resolved_symbols=$(grep -v "\[unknown\]" "$RESULTS_DIR/stack_collapse.txt" | wc -l || echo "0")
    fi
    
    # Create summary
    local summary_file="$RESULTS_DIR/test_summary.txt"
    {
        echo "=== Robust Performance Test Summary ==="
        echo "Date: $(date)"
        echo "Duration: ${TEST_DURATION}s"
        echo "Results Directory: $RESULTS_DIR"
        echo ""
        echo "=== Performance Metrics ==="
        echo "nvmf_tgt function calls: $nvmf_calls"
        echo "libceph-common calls: $libceph_calls"
        echo "librados calls: $librados_calls"
        echo ""
        echo "=== Symbol Resolution ==="
        echo "Total symbols processed: $total_symbols"
        echo "Resolved symbols: $resolved_symbols"
        echo "Resolution rate: $([ $total_symbols -gt 0 ] && awk "BEGIN {printf \"%.1f\", $resolved_symbols * 100 / $total_symbols}" || echo "0")%"
        echo ""
        echo "=== Generated Artifacts ==="
        ls -la "$RESULTS_DIR"
        echo ""
    } > "$summary_file"
    
    log_success "Results analysis completed"
    echo ""
    echo "📊 PERFORMANCE SUMMARY:"
    echo "======================"
    echo "nvmf_tgt calls: $nvmf_calls"
    echo "libceph calls: $libceph_calls"
    echo "librados calls: $librados_calls"
    echo ""
    echo "Symbol Resolution: $resolved_symbols/$total_symbols ($([ $total_symbols -gt 0 ] && awk "BEGIN {printf \"%.1f\", $resolved_symbols * 100 / $total_symbols}" || echo "0")%)"
    echo "Results: $RESULTS_DIR"
}

# Step 8: Cleanup
# Step 9: Optional cleanup
cleanup() {
    log_info "Cleaning up..."
    
    # Check for mounted devices (for compatibility with previous tests)
    if [ -n "$MOUNT_POINT" ] && mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        log_info "Unmounting $MOUNT_POINT..."
        sudo umount "$MOUNT_POINT"
        log_success "Unmounted $MOUNT_POINT"
        
        # Remove mount point
        if [ -d "$MOUNT_POINT" ]; then
            sudo rmdir "$MOUNT_POINT" 2>/dev/null || true
            log_success "Removed mount point directory"
        fi
    else
        log_info "No device mounted (using direct block device I/O)"
    fi
    
    # Disconnect NVMe-oF
    log_info "Disconnecting NVMe-oF..."
    sudo nvme disconnect-all 2>/dev/null || true
    
    # Optional: Unload kernel modules (commented out by default to avoid breaking system)
    # Uncomment the following lines if you want to unload NVMe modules after test
    # log_info "Unloading NVMe kernel modules..."
    # sudo modprobe -r nvme-tcp nvme-rdma nvme-fabrics nvme 2>/dev/null || true
    
    log_success "Cleanup completed"
}

# Main execution
main() {
    echo "🔥 Robust Performance Test with Verification"
    echo "==========================================="
    echo ""
    
    # Execute all steps
    load_kernel_modules || exit 1
    verify_clean_state || exit 1
    setup_and_start_gateway || exit 1
    create_namespace || exit 1
    connect_to_namespace || exit 1
    record_performance_with_io || exit 1
    generate_flame_graphs || exit 1
    analyze_results
    
    echo ""
    log_success "🎉 Robust performance test completed successfully!"
    echo "Results directory: $RESULTS_DIR"
    echo ""
    echo "Flame graphs with container-based symbol resolution:"
    echo "  $RESULTS_DIR/flame_graph.svg"
    echo "  $RESULTS_DIR/cpu_flame_graph.svg"
    echo "  $RESULTS_DIR/memory_flame_graph.svg"
    echo ""
    echo "To view perf report with symbols:"
    echo "  cat $RESULTS_DIR/perf_report.txt"
    
    # Ask user if they want to cleanup
    echo ""
    read -p "Do you want to cleanup (disconnect, stop containers)? [y/N]: " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        cleanup
        make down
    else
        echo "System left running for further analysis"
        echo "To cleanup later, run: make down"
    fi
}

# Run main function
main "$@"



