#!/bin/bash

# flame_graph.sh - Flame graph generation script for perf data
# This script generates flame graphs from perf recording data

set -e

# Configuration
RESULTS_DIR=${1:-""}
FLAME_GRAPH_DIR="$(pwd)/artifacts/FlameGraph"

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

# Function to check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check if results directory is provided
    if [ -z "$RESULTS_DIR" ]; then
        log_error "Results directory not provided"
        echo "Usage: $0 <results_directory>"
        echo "Example: $0 /tmp/nvmeof_perf_record_20250917_192000"
        exit 1
    fi
    
    # Check if results directory exists
    if [ ! -d "$RESULTS_DIR" ]; then
        log_error "Results directory not found: $RESULTS_DIR"
        exit 1
    fi
    log_success "Results directory found: $RESULTS_DIR"
    
    # Check if perf data file exists
    local perf_data_file="$RESULTS_DIR/perf.data"
    if [ ! -f "$perf_data_file" ]; then
        log_error "Perf data file not found: $perf_data_file"
        exit 1
    fi
    log_success "Perf data file found: $perf_data_file"
    
    # Check if perf script file exists
    local perf_script_file="$RESULTS_DIR/perf_script.txt"
    if [ ! -f "$perf_script_file" ]; then
        log_warning "Perf script file not found: $perf_script_file"
        log_info "Will generate it from perf data..."
    else
        log_success "Perf script file found: $perf_script_file"
    fi
}

# Function to install flame graph tools
install_flame_graph_tools() {
    log_info "Checking flame graph tools..."
    
    # Check if flame graph tools are already available
    if [ -f "./bin/flamegraph.pl" ] && [ -f "./bin/stackcollapse-perf.pl" ]; then
        log_success "Flame graph tools found"
        return 0
    fi
    
    log_info "Installing flame graph tools..."
    
    # Create bin directory if it doesn't exist
    mkdir -p bin
    
    # Clone flame graph repository if not exists
    if [ ! -d "$FLAME_GRAPH_DIR" ]; then
        log_info "Cloning FlameGraph repository..."
        cd "$(pwd)/artifacts"
        if ! git clone https://github.com/brendangregg/FlameGraph.git; then
            log_error "Failed to clone FlameGraph repository"
            exit 1
        fi
        cd /data/code/ceph-nvmeof
    fi
    
    # Create symlinks
    ln -sf "$FLAME_GRAPH_DIR/flamegraph.pl" bin/flamegraph.pl
    ln -sf "$FLAME_GRAPH_DIR/stackcollapse-perf.pl" bin/stackcollapse-perf.pl
    
    log_success "Flame graph tools installed"
}

# Function to generate flame graphs
generate_flame_graphs() {
    local results_dir=$1
    local perf_data_file="$results_dir/perf.data"
    local perf_script_file="$results_dir/perf_script.txt"
    
    log_info "Generating flame graphs..."
    
    # Generate perf script if not exists
    if [ ! -f "$perf_script_file" ]; then
        log_info "Generating perf script from perf data..."
        if ! /data/code/linux/tools/perf/perf script -i "$perf_data_file" > "$perf_script_file" 2>/dev/null; then
            log_error "Failed to generate perf script"
            return 1
        fi
        log_success "Perf script generated: $perf_script_file"
    fi
    
    # Generate stack collapse data
    local stack_collapse_file="$results_dir/stack_collapse.txt"
    log_info "Generating stack collapse data..."
    
    if ! ./bin/stackcollapse-perf.pl "$perf_script_file" > "$stack_collapse_file" 2>/dev/null; then
        log_error "Failed to generate stack collapse data"
        return 1
    fi
    
    # Check if stack collapse data is valid
    if [ ! -s "$stack_collapse_file" ]; then
        log_warning "Stack collapse data is empty - no call stack information available"
        log_info "This might happen if the target process was idle during recording"
        return 0
    fi
    
    log_success "Stack collapse data generated: $stack_collapse_file"
    
    # Generate flame graph
    local flame_graph_file="$results_dir/flame_graph.svg"
    log_info "Generating flame graph..."
    
    if ! ./bin/flamegraph.pl "$stack_collapse_file" > "$flame_graph_file" 2>/dev/null; then
        log_error "Failed to generate flame graph"
        return 1
    fi
    
    # Check if flame graph was generated successfully
    if [ ! -s "$flame_graph_file" ]; then
        log_warning "Flame graph file is empty"
        return 1
    fi
    
    log_success "Flame graph generated: $flame_graph_file"
    
    # Generate additional flame graph variants
    log_info "Generating additional flame graph variants..."
    
    # CPU flame graph
    local cpu_flame_graph="$results_dir/cpu_flame_graph.svg"
    if ./bin/flamegraph.pl --title "CPU Flame Graph" "$stack_collapse_file" > "$cpu_flame_graph" 2>/dev/null; then
        log_success "CPU flame graph generated: $cpu_flame_graph"
    fi
    
    # Memory flame graph (if available)
    local mem_flame_graph="$results_dir/memory_flame_graph.svg"
    if ./bin/flamegraph.pl --title "Memory Flame Graph" --colors mem "$stack_collapse_file" > "$mem_flame_graph" 2>/dev/null; then
        log_success "Memory flame graph generated: $mem_flame_graph"
    fi
    
    # Generate summary
    local summary_file="$results_dir/flame_graph_summary.txt"
    {
        echo "=== Flame Graph Generation Summary ==="
        echo "Date: $(date)"
        echo "Results Directory: $results_dir"
        echo ""
        echo "=== Generated Files ==="
        echo "Stack collapse data: $stack_collapse_file"
        echo "Main flame graph: $flame_graph_file"
        echo "CPU flame graph: $cpu_flame_graph"
        echo "Memory flame graph: $mem_flame_graph"
        echo "Summary: $summary_file"
        echo ""
        echo "=== File Sizes ==="
        ls -lh "$results_dir"/*.svg "$results_dir"/*.txt 2>/dev/null | grep -E '\.(svg|txt)$' || echo "No SVG or TXT files found"
        echo ""
        echo "=== Usage Instructions ==="
        echo "1. Open the flame graph SVG files in a web browser"
        echo "2. Click on any function to zoom in"
        echo "3. Use Ctrl+click to zoom out"
        echo "4. Search for specific functions using Ctrl+F"
    } > "$summary_file"
    
    log_success "Flame graph summary generated: $summary_file"
    
    return 0
}

# Function to display results
display_results() {
    local results_dir=$1
    
    echo ""
    log_success "Flame graph generation completed!"
    echo "Results directory: $results_dir"
    echo ""
    echo "Generated files:"
    ls -la "$results_dir" | grep -E '\.(svg|txt)$' || echo "No SVG or TXT files found"
    echo ""
    echo "To view the flame graphs:"
    echo "1. Open the SVG files in a web browser"
    echo "2. Or use: firefox $results_dir/flame_graph.svg"
    echo "3. Or use: google-chrome $results_dir/flame_graph.svg"
}

# Main execution
main() {
    echo "🔥 Flame Graph Generation"
    echo "========================"
    echo ""
    
    # Check prerequisites
    check_prerequisites
    
    # Install flame graph tools
    install_flame_graph_tools
    
    # Generate flame graphs
    if generate_flame_graphs "$RESULTS_DIR"; then
        display_results "$RESULTS_DIR"
    else
        log_error "Flame graph generation failed"
        exit 1
    fi
}

# Run main function
main "$@"

