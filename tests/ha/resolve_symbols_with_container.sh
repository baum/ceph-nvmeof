#!/bin/bash

# resolve_symbols_with_container.sh - Resolve symbols using nvmeof container debug info
# This script extracts addresses from perf data and resolves them using the container's debug info

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

# Get the running nvmeof container ID
get_nvmeof_container() {
    local container_id=$(docker ps | grep nvmeof | awk '{print $1}' | head -1)
    if [ -z "$container_id" ]; then
        log_error "No running nvmeof container found"
        exit 1
    fi
    echo "$container_id"
}

# Resolve symbols for a specific library
resolve_library_symbols() {
    local library_path="$1"
    local library_name="$2"
    local perf_script_file="$3"
    local output_file="$4"
    
    log_info "Resolving symbols for $library_name..."
    
    # Extract unique addresses for this library (perf script uses hex without 0x prefix)
    local addresses=$(grep "$library_path" "$perf_script_file" | grep -oE '\s+[0-9a-f]{6,8}\s+' | tr -d ' ' | sort -u)
    
    if [ -z "$addresses" ]; then
        log_warning "No addresses found for $library_name"
        return 0
    fi
    
    local count=0
    local resolved_count=0
    
    echo "# $library_name symbol resolution" >> "$output_file"
    echo "# Library: $library_path" >> "$output_file"
    echo "" >> "$output_file"
    
    for address in $addresses; do
        count=$((count + 1))
        
        # Use addr2line to resolve the symbol
        local symbol=$(docker exec "$CONTAINER_ID" addr2line -e "$library_path" -f -C "$address" 2>/dev/null | head -1)
        
        if [ -n "$symbol" ] && [ "$symbol" != "??" ]; then
            resolved_count=$((resolved_count + 1))
            echo "0x$address -> $symbol" >> "$output_file"
        else
            echo "0x$address -> [unresolved]" >> "$output_file"
        fi
        
        # Progress indicator
        if [ $((count % 10)) -eq 0 ]; then
            log_info "Processed $count addresses for $library_name..."
        fi
    done
    
    echo "" >> "$output_file"
    echo "# Summary: $resolved_count/$count symbols resolved for $library_name" >> "$output_file"
    echo "" >> "$output_file"
    
    log_success "Resolved $resolved_count/$count symbols for $library_name"
}

# Main function
main() {
    echo "🔍 Symbol Resolution using nvmeof Container Debug Info"
    echo "====================================================="
    echo ""
    
    # Get the latest perf data directory
    PERF_DIR=$(get_latest_perf_dir)
    log_info "Using perf data from: $PERF_DIR"
    
    # Get the running nvmeof container
    CONTAINER_ID=$(get_nvmeof_container)
    log_info "Using nvmeof container: $CONTAINER_ID"
    
    # Check if perf script file exists
    PERF_SCRIPT_FILE="$PERF_DIR/perf_script.txt"
    if [ ! -f "$PERF_SCRIPT_FILE" ]; then
        log_error "Perf script file not found: $PERF_SCRIPT_FILE"
        exit 1
    fi
    
    # Create output file
    OUTPUT_FILE="$PERF_DIR/symbol_resolution.txt"
    log_info "Creating symbol resolution output: $OUTPUT_FILE"
    
    # Clear output file
    > "$OUTPUT_FILE"
    
    echo "# Symbol Resolution Results" >> "$OUTPUT_FILE"
    echo "# Generated: $(date)" >> "$OUTPUT_FILE"
    echo "# Perf data: $PERF_DIR" >> "$OUTPUT_FILE"
    echo "# Container: $CONTAINER_ID" >> "$OUTPUT_FILE"
    echo "" >> "$OUTPUT_FILE"
    
    # Resolve symbols for each library
    resolve_library_symbols "/usr/lib64/librados.so.2.0.0" "librados" "$PERF_SCRIPT_FILE" "$OUTPUT_FILE"
    resolve_library_symbols "/usr/lib64/ceph/libceph-common.so.2" "libceph-common" "$PERF_SCRIPT_FILE" "$OUTPUT_FILE"
    
    # Create a summary
    echo "# Overall Summary" >> "$OUTPUT_FILE"
    echo "# ===============" >> "$OUTPUT_FILE"
    echo "# Total addresses processed: $(grep -c "0x" "$OUTPUT_FILE" || echo "0")" >> "$OUTPUT_FILE"
    echo "# Resolved symbols: $(grep -c " -> " "$OUTPUT_FILE" | grep -v "unresolved" || echo "0")" >> "$OUTPUT_FILE"
    echo "# Unresolved symbols: $(grep -c "unresolved" "$OUTPUT_FILE" || echo "0")" >> "$OUTPUT_FILE"
    
    log_success "Symbol resolution completed!"
    log_info "Results saved to: $OUTPUT_FILE"
    
    # Show summary
    echo ""
    echo "📊 SUMMARY:"
    echo "==========="
    echo "Total addresses processed: $(grep -c "0x" "$OUTPUT_FILE" 2>/dev/null || echo "0")"
    echo "Resolved symbols: $(grep -c " -> " "$OUTPUT_FILE" 2>/dev/null | grep -v "unresolved" || echo "0")"
    echo "Unresolved symbols: $(grep -c "unresolved" "$OUTPUT_FILE" 2>/dev/null || echo "0")"
    
    echo ""
    echo "🎯 Next steps:"
    echo "• Review resolved symbols in: $OUTPUT_FILE"
    echo "• Use resolved symbols to improve flame graphs"
    echo "• Update perf script with resolved function names"
}

# Run main function
main "$@"
