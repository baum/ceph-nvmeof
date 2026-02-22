#!/bin/bash

# generate_resolved_flamegraphs.sh - Generate flame graphs with resolved symbols from existing perf data
# This script takes existing perf data and symbol resolution results to create flame graphs with function names

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

# Create resolved symbol mapping file
create_symbol_mapping() {
    local perf_dir="$1"
    local symbol_resolution_file="$perf_dir/symbol_resolution.txt"
    
    log_info "Creating symbol mapping for flame graphs..."
    
    if [ ! -f "$symbol_resolution_file" ]; then
        log_error "No symbol resolution file found: $symbol_resolution_file"
        log_info "Please run symbol resolution first"
        exit 1
    fi
    
    # Create a sed script to replace addresses with function names
    local mapping_file="$perf_dir/symbol_mapping.sed"
    
    # Extract mappings from symbol resolution file
    grep " -> " "$symbol_resolution_file" | grep -v "unresolved" | while read line; do
        local address=$(echo "$line" | sed 's/0x\([0-9a-f]*\) -> .*/\1/')
        local symbol=$(echo "$line" | sed 's/0x[0-9a-f]* -> \(.*\)/\1/')
        
        # Escape special characters in symbol name for sed
        symbol=$(echo "$symbol" | sed 's/[[\.*^$()+?{|]/\\&/g')
        
        # Create sed replacement rule
        echo "s/0x$address\[unknown\] ([^)]*)/$symbol/g" >> "$mapping_file"
        echo "s/$address\[unknown\] ([^)]*)/$symbol/g" >> "$mapping_file"
    done
    
    if [ -f "$mapping_file" ]; then
        local rule_count=$(wc -l < "$mapping_file")
        log_success "Symbol mapping created: $rule_count replacement rules"
    else
        log_warning "No symbol mappings created"
        exit 1
    fi
}

# Generate flame graphs with resolved symbols
generate_resolved_flamegraphs() {
    local perf_dir="$1"
    local stack_collapse_file="$perf_dir/stack_collapse.txt"
    local mapping_file="$perf_dir/symbol_mapping.sed"
    
    log_info "Generating flame graphs with resolved symbols..."
    
    # Check if stack collapse file exists
    if [ ! -f "$stack_collapse_file" ]; then
        log_info "Stack collapse file not found, generating from perf script..."
        
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
        
        # Generate stack collapse from perf script
        export PATH="$PWD/bin:$PATH"
        ./bin/stackcollapse-perf.pl "$perf_dir/perf_script.txt" > "$stack_collapse_file"
        log_success "Stack collapse file generated"
    fi
    
    if [ -f "$mapping_file" ]; then
        # Apply symbol mapping to create resolved stack collapse
        local resolved_stack_collapse="$perf_dir/stack_collapse_resolved.txt"
        sed -f "$mapping_file" "$stack_collapse_file" > "$resolved_stack_collapse"
        
        # Generate flame graphs with resolved symbols
        log_info "Generating flame graphs with resolved symbols (unlimited width)..."
        ./bin/flamegraph.pl "$resolved_stack_collapse" > "$perf_dir/flame_graph_resolved.svg"
        ./bin/flamegraph.pl --countname=cpu "$resolved_stack_collapse" > "$perf_dir/cpu_flame_graph_resolved.svg"
        ./bin/flamegraph.pl --countname=memory "$resolved_stack_collapse" > "$perf_dir/memory_flame_graph_resolved.svg"
        
        log_success "Flame graphs with resolved symbols generated"
        
        # Show some statistics
        local original_lines=$(wc -l < "$stack_collapse_file")
        local resolved_lines=$(wc -l < "$resolved_stack_collapse")
        log_info "Stack collapse: $original_lines lines"
        log_info "Resolved stack collapse: $resolved_lines lines"
        
    else
        log_error "No symbol mapping file found: $mapping_file"
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
        head -5 "$stack_collapse_file"
        
        echo ""
        echo "📊 RESOLVED STACK COLLAPSE (with function names):"
        echo "==============================================="
        head -5 "$resolved_stack_collapse"
        
        echo ""
        echo "🔍 EXAMPLE RESOLUTION:"
        echo "===================="
        
        # Show a few examples of resolved symbols
        local resolved_examples=$(grep -v "^$" "$resolved_stack_collapse" | grep -E "(AsyncConnection|md_config|OpTracker|entity_addrvec)" | head -3)
        if [ -n "$resolved_examples" ]; then
            echo "$resolved_examples"
        else
            log_warning "No obvious resolved function examples found"
        fi
    fi
}

# Main function
main() {
    echo "🔥 Flame Graph Generation with Resolved Symbols"
    echo "============================================="
    echo ""
    
    # Get the latest perf data directory
    PERF_DIR=$(get_latest_perf_dir)
    log_info "Using perf data from: $PERF_DIR"
    
    # Create symbol mapping
    create_symbol_mapping "$PERF_DIR"
    
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
    echo "• symbol_mapping.sed - Symbol mapping rules used"
    echo ""
    echo "🚀 To view the flame graphs:"
    echo "  firefox $PERF_DIR/flame_graph_resolved.svg"
    echo "  firefox $PERF_DIR/cpu_flame_graph_resolved.svg"
    echo "  firefox $PERF_DIR/memory_flame_graph_resolved.svg"
}

# Run main function
main "$@"







