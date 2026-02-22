#!/bin/bash

# generate_resolved_flamegraphs_simple.sh - Simple approach to generate flame graphs with resolved symbols
# This script uses a simpler approach to replace addresses with function names

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

# Get the latest perf data directory
get_latest_perf_dir() {
    local latest_dir=$(ls -td /data/code/ceph-nvmeof/artifacts/perf_record_* 2>/dev/null | head -1)
    if [ -z "$latest_dir" ]; then
        log_error "No perf record directories found"
        exit 1
    fi
    echo "$latest_dir"
}

# Create simple symbol mapping using direct replacement
create_simple_mapping() {
    local perf_dir="$1"
    local symbol_resolution_file="$perf_dir/symbol_resolution.txt"
    
    log_info "Creating simple symbol mapping for flame graphs..."
    
    if [ ! -f "$symbol_resolution_file" ]; then
        log_error "No symbol resolution file found: $symbol_resolution_file"
        exit 1
    fi
    
    # Create resolved stack collapse by direct replacement
    local stack_collapse_file="$perf_dir/stack_collapse.txt"
    local resolved_stack_collapse="$perf_dir/stack_collapse_resolved.txt"
    
    # Start with original stack collapse
    cp "$stack_collapse_file" "$resolved_stack_collapse"
    
    # Apply replacements one by one
    local replacement_count=0
    
    # Extract mappings and apply them
    grep " -> " "$symbol_resolution_file" | grep -v "unresolved" | while read line; do
        local address=$(echo "$line" | sed 's/0x\([0-9a-f]*\) -> .*/\1/')
        local symbol=$(echo "$line" | sed 's/0x[0-9a-f]* -> \(.*\)/\1/')
        
        # Create a simple function name (remove complex C++ mangling)
        local simple_name=$(echo "$symbol" | sed 's/.*::\([^:]*\)(.*/\1/' | sed 's/<.*>//' | sed 's/.*:://')
        
        if [ -n "$simple_name" ] && [ "$simple_name" != "$symbol" ]; then
            # Apply replacement
            sed -i "s/$address\[unknown\] ([^)]*)/$simple_name/g" "$resolved_stack_collapse"
            replacement_count=$((replacement_count + 1))
            log_info "Replaced $address -> $simple_name"
        fi
    done
    
    log_success "Applied $replacement_count symbol replacements"
}

# Generate flame graphs with resolved symbols
generate_resolved_flamegraphs() {
    local perf_dir="$1"
    local resolved_stack_collapse="$perf_dir/stack_collapse_resolved.txt"
    
    log_info "Generating flame graphs with resolved symbols..."
    
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
    
    if [ -f "$resolved_stack_collapse" ]; then
        # Generate flame graphs with resolved symbols (wide format to prevent truncation)
        log_info "Generating flame graphs with resolved symbols (wide format, 3000px width)..."
        ./bin/flamegraph.pl --width=3000 --minwidth=0 "$resolved_stack_collapse" > "$perf_dir/flame_graph_resolved.svg"
        ./bin/flamegraph.pl --width=3000 --minwidth=0 --countname=cpu "$resolved_stack_collapse" > "$perf_dir/cpu_flame_graph_resolved.svg"
        ./bin/flamegraph.pl --width=3000 --minwidth=0 --countname=memory "$resolved_stack_collapse" > "$perf_dir/memory_flame_graph_resolved.svg"
        
        log_success "Flame graphs with resolved symbols generated"
        
    else
        log_error "No resolved stack collapse file found: $resolved_stack_collapse"
        exit 1
    fi
}

# Show comparison between original and resolved
show_comparison() {
    local perf_dir="$1"
    local stack_collapse_file="$perf_dir/stack_collapse.txt"
    local resolved_stack_collapse="$perf_dir/stack_collapse_resolved.txt"
    
    if [ -f "$resolved_stack_collapse" ]; then
        log_info "Showing comparison between original and resolved stack collapse..."
        
        echo ""
        echo "📊 ORIGINAL STACK COLLAPSE (with addresses):"
        echo "==========================================="
        head -3 "$stack_collapse_file"
        
        echo ""
        echo "📊 RESOLVED STACK COLLAPSE (with function names):"
        echo "==============================================="
        head -3 "$resolved_stack_collapse"
        
        echo ""
        echo "🔍 BEFORE/AFTER COMPARISON:"
        echo "=========================="
        
        # Show side-by-side comparison
        echo "BEFORE:"
        grep "4b34b0" "$stack_collapse_file" | head -1
        echo ""
        echo "AFTER:"
        grep "read_bulk\|4b34b0" "$resolved_stack_collapse" | head -1
    fi
}

# Main function
main() {
    echo "🔥 Simple Flame Graph Generation with Resolved Symbols"
    echo "===================================================="
    echo ""
    
    # Get the latest perf data directory
    PERF_DIR=$(get_latest_perf_dir)
    log_info "Using perf data from: $PERF_DIR"
    
    # Create simple symbol mapping
    create_simple_mapping "$PERF_DIR"
    
    # Generate flame graphs with resolved symbols
    generate_resolved_flamegraphs "$PERF_DIR"
    
    # Show comparison
    show_comparison "$PERF_DIR"
    
    log_success "🎉 Flame graphs with resolved symbols generated successfully!"
    echo ""
    echo "📁 Generated files in $PERF_DIR:"
    echo "• flame_graph_resolved.svg - Main flame graph with function names"
    echo "• cpu_flame_graph_resolved.svg - CPU-focused flame graph with function names"
    echo "• memory_flame_graph_resolved.svg - Memory-focused flame graph with function names"
    echo "• stack_collapse_resolved.txt - Resolved stack collapse data"
    echo ""
    echo "🚀 To view the flame graphs:"
    echo "  firefox $PERF_DIR/flame_graph_resolved.svg"
    echo "  firefox $PERF_DIR/cpu_flame_graph_resolved.svg"
    echo "  firefox $PERF_DIR/memory_flame_graph_resolved.svg"
}

# Run main function
main "$@"
