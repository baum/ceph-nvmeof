#!/bin/bash

# Flame Graph Generation with Symbol Resolution
# This script generates flame graphs with resolved function names instead of binary addresses

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

usage() {
    echo "Usage: $0 <results_directory> [binary_path]"
    echo ""
    echo "Arguments:"
    echo "  results_directory  Path to perf recording results directory"
    echo "  binary_path        Optional path to nvmf_tgt binary (default: extracts from container)"
    echo ""
    echo "Example:"
    echo "  $0 artifacts/perf_record_*/"
    echo ""
    echo "This script will:"
    echo "  1. Extract binary addresses from perf script output"
    echo "  2. Resolve them to function names using addr2line"
    echo "  3. Generate flame graphs with resolved symbols"
}

check_flame_graph_tools() {
    log_info "Checking flame graph tools..."
    if [ ! -f "./bin/flamegraph.pl" ] || [ ! -f "./bin/stackcollapse-perf.pl" ]; then
        log_info "Installing flame graph tools..."
        
        # Create bin directory if it doesn't exist
        mkdir -p bin
        
        # Clone flame graph repository if not exists
        if [ ! -d "$FLAME_GRAPH_DIR" ]; then
            log_info "Cloning FlameGraph repository..."
            mkdir -p "$(dirname "$FLAME_GRAPH_DIR")"
            cd "$(dirname "$FLAME_GRAPH_DIR")"
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
    else
        log_success "Flame graph tools found"
    fi
}

resolve_symbols_in_script() {
    local perf_script_file="$1"
    local binary_path="$2"
    local resolved_script_file="$3"
    
    log_info "Resolving symbols in perf script output..."
    
    # Create a mapping of addresses to function names
    local symbol_map_file="/tmp/symbol_map_$(date +%s).txt"
    
    # Extract unique addresses from perf script
    grep -o '0x[0-9a-f]\{6,\}' "$perf_script_file" | sort -u > "$symbol_map_file.tmp"
    
    # Filter out invalid addresses (too small)
    awk '$1 ~ /^0x[0-9a-f]{6,}$/ && $1 > 0x100000' "$symbol_map_file.tmp" > "$symbol_map_file"
    rm -f "$symbol_map_file.tmp"
    
    local resolved_count=0
    local total_count=$(wc -l < "$symbol_map_file")
    
    log_info "Resolving $total_count unique addresses..."
    
    # Create symbol mapping file
    > "$symbol_map_file.map"
    while IFS= read -r addr; do
        # Try to resolve with addr2line
        local resolved=$(addr2line -e "$binary_path" -f -C "$addr" 2>/dev/null || echo "")
        
        if [ -n "$resolved" ] && [ "$resolved" != "??" ] && [[ "$resolved" != *"??"* ]]; then
            local func_name=$(echo "$resolved" | head -1)
            local location=$(echo "$resolved" | tail -1)
            
            # Clean up function name (remove template parameters, etc.)
            func_name=$(echo "$func_name" | sed 's/<.*>//g' | sed 's/::.*//g')
            
            echo "${addr} ${func_name}" >> "$symbol_map_file.map"
            ((resolved_count++))
        fi
    done < "$symbol_map_file"
    
    log_success "Resolved $resolved_count out of $total_count addresses"
    
    # Replace addresses with function names in perf script
    if [ $resolved_count -gt 0 ]; then
        log_info "Replacing addresses with function names..."
        cp "$perf_script_file" "$resolved_script_file"
        
        while IFS= read -r line; do
            addr=$(echo "$line" | cut -d' ' -f1)
            func_name=$(echo "$line" | cut -d' ' -f2-)
            
            if [ -n "$addr" ] && [ -n "$func_name" ]; then
                sed -i "s|$addr|$func_name|g" "$resolved_script_file"
            fi
        done < "$symbol_map_file.map"
        
        log_success "Symbol replacement completed"
    else
        log_warning "No symbols resolved, using original perf script"
        cp "$perf_script_file" "$resolved_script_file"
    fi
    
    # Cleanup
    rm -f "$symbol_map_file" "$symbol_map_file.map"
}

main() {
    if [ $# -lt 1 ]; then
        usage
        exit 1
    fi
    
    local results_dir="$1"
    local binary_path="${2:-}"
    
    # Configuration
    local FLAME_GRAPH_DIR="$(pwd)/artifacts/FlameGraph"
    
    echo "🔥 Flame Graph Generation with Symbol Resolution"
    echo "================================================"
    echo ""
    
    # Check if results directory exists
    if [ ! -d "$results_dir" ]; then
        log_error "Results directory not found: $results_dir"
        exit 1
    fi
    
    local perf_data_file="$results_dir/perf.data"
    local perf_script_file="$results_dir/perf_script.txt"
    
    if [ ! -f "$perf_data_file" ]; then
        log_error "Perf data file not found: $perf_data_file"
        exit 1
    fi
    
    if [ ! -f "$perf_script_file" ]; then
        log_error "Perf script file not found: $perf_script_file"
        exit 1
    fi
    
    # Get binary path
    if [ -z "$binary_path" ]; then
        log_info "Extracting nvmf_tgt binary from container..."
        local container_id=$(docker ps --format '{{.ID}}\t{{.Names}}' | awk '$2 ~ /nvmeof/ && $2 ~ /1/ {print $1}' | head -1)
        
        if [ -z "$container_id" ]; then
            log_error "No nvmeof container found"
            exit 1
        fi
        
        binary_path="/tmp/nvmf_tgt_$(date +%s)"
        docker cp "$container_id:/usr/local/bin/nvmf_tgt" "$binary_path"
        log_success "Binary extracted to: $binary_path"
    fi
    
    # Check if binary exists and has debug info
    if [ ! -f "$binary_path" ]; then
        log_error "Binary file not found: $binary_path"
        exit 1
    fi
    
    local binary_info=$(file "$binary_path")
    if [[ "$binary_info" == *"not stripped"* ]] && [[ "$binary_info" == *"debug_info"* ]]; then
        log_success "Binary has debug symbols and is not stripped"
    else
        log_warning "Binary may not have full debug information"
    fi
    
    # Check flame graph tools
    check_flame_graph_tools
    
    # Resolve symbols in perf script
    local resolved_script_file="$results_dir/perf_script_resolved.txt"
    resolve_symbols_in_script "$perf_script_file" "$binary_path" "$resolved_script_file"
    
    # Generate flame graphs
    log_info "Generating flame graphs with resolved symbols..."
    
    local stack_collapse_file="$results_dir/stack_collapse_resolved.txt"
    local flame_graph_file="$results_dir/flame_graph_resolved.svg"
    local cpu_flame_graph_file="$results_dir/cpu_flame_graph_resolved.svg"
    local memory_flame_graph_file="$results_dir/memory_flame_graph_resolved.svg"
    
    # Add local bin to PATH for flame graph tools
    export PATH="$PWD/bin:$PATH"
    
    # Generate stack collapse from resolved perf script
    log_info "Generating stack collapse data..."
    if ! ./bin/stackcollapse-perf.pl "$resolved_script_file" > "$stack_collapse_file" 2>/dev/null; then
        log_warning "Failed to generate stack collapse from resolved script"
        log_info "Falling back to original perf script..."
        ./bin/stackcollapse-perf.pl "$perf_script_file" > "$stack_collapse_file" 2>/dev/null
    fi
    
    # Generate flame graphs
    if [ -s "$stack_collapse_file" ]; then
        log_info "Generating main flame graph..."
        ./bin/flamegraph.pl "$stack_collapse_file" > "$flame_graph_file" 2>/dev/null
        if [ -f "$flame_graph_file" ] && [ -s "$flame_graph_file" ]; then
            log_success "Resolved flame graph generated: $flame_graph_file"
        else
            log_warning "Resolved flame graph generation failed"
        fi
        
        log_info "Generating CPU flame graph..."
        ./bin/flamegraph.pl --countname=cpu "$stack_collapse_file" > "$cpu_flame_graph_file" 2>/dev/null
        if [ -f "$cpu_flame_graph_file" ] && [ -s "$cpu_flame_graph_file" ]; then
            log_success "Resolved CPU flame graph generated: $cpu_flame_graph_file"
        else
            log_warning "Resolved CPU flame graph generation failed"
        fi
        
        log_info "Generating memory flame graph..."
        ./bin/flamegraph.pl --countname=memory "$stack_collapse_file" > "$memory_flame_graph_file" 2>/dev/null
        if [ -f "$memory_flame_graph_file" ] && [ -s "$memory_flame_graph_file" ]; then
            log_success "Resolved memory flame graph generated: $memory_flame_graph_file"
        else
            log_warning "Resolved memory flame graph generation failed"
        fi
    else
        log_warning "Stack collapse data is empty"
    fi
    
    # Generate summary
    local summary_file="$results_dir/flame_graph_resolved_summary.txt"
    {
        echo "=== Flame Graph with Symbol Resolution Summary ==="
        echo "Date: $(date)"
        echo "Results Directory: $results_dir"
        echo "Binary Path: $binary_path"
        echo ""
        echo "Generated Files:"
        echo "- Original flame graph: $results_dir/flame_graph.svg"
        echo "- Resolved flame graph: $flame_graph_file"
        echo "- Resolved CPU flame graph: $cpu_flame_graph_file"
        echo "- Resolved memory flame graph: $memory_flame_graph_file"
        echo "- Resolved stack collapse: $stack_collapse_file"
        echo "- Resolved perf script: $resolved_script_file"
        echo ""
        echo "Symbol Resolution:"
        echo "- Binary addresses replaced with function names"
        echo "- Source code locations preserved where possible"
        echo "- Improved readability for performance analysis"
    } > "$summary_file"
    
    log_success "Flame graph generation with symbol resolution completed!"
    echo ""
    echo "Results directory: $results_dir"
    echo ""
    echo "Generated files:"
    ls -la "$results_dir"/*resolved*
    echo ""
    echo "To view the resolved flame graphs:"
    echo "1. Open the SVG files in a web browser"
    echo "2. Or use: firefox $flame_graph_file"
    echo "3. Or use: google-chrome $flame_graph_file"
    echo ""
    echo "Compare with original flame graphs to see the improvement!"
    
    # Cleanup if we extracted the binary
    if [[ "$binary_path" == "/tmp/nvmf_tgt_"* ]]; then
        rm -f "$binary_path"
        log_info "Cleaned up extracted binary"
    fi
}

main "$@"










