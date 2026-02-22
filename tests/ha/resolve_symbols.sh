#!/bin/bash

# Symbol Resolution Script for NVMe-oF Performance Analysis
# This script demonstrates how to resolve binary addresses to function names

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
    echo "Usage: $0 <perf_report_file> [binary_path]"
    echo ""
    echo "Arguments:"
    echo "  perf_report_file  Path to perf report file"
    echo "  binary_path       Optional path to nvmf_tgt binary (default: extracts from container)"
    echo ""
    echo "Example:"
    echo "  $0 artifacts/perf_record_*/perf_report.txt"
    echo ""
    echo "This script will:"
    echo "  1. Extract binary addresses from perf report"
    echo "  2. Resolve them to function names using addr2line"
    echo "  3. Show before/after comparison"
}

resolve_symbols() {
    local perf_report="$1"
    local binary_path="$2"
    
    log_info "Resolving symbols from: $perf_report"
    log_info "Using binary: $binary_path"
    
    # Extract binary addresses from perf report
    local addresses=$(grep -o '0x[0-9a-f]\+' "$perf_report" | grep -v '0x0000000000000000' | sort -u | head -20)
    
    if [ -z "$addresses" ]; then
        log_warning "No binary addresses found in perf report"
        return 1
    fi
    
    log_info "Found $(echo "$addresses" | wc -l) unique addresses to resolve"
    echo ""
    
    echo "🔍 Symbol Resolution Results:"
    echo "=============================="
    echo ""
    
    for addr in $addresses; do
        echo -e "${YELLOW}Address: $addr${NC}"
        
        # Try to resolve with addr2line
        local resolved=$(addr2line -e "$binary_path" -f -C "$addr" 2>/dev/null || echo "Failed to resolve")
        
        if [ "$resolved" != "Failed to resolve" ]; then
            echo -e "${GREEN}✅ Function: $(echo "$resolved" | head -1)${NC}"
            echo -e "${BLUE}📍 Location: $(echo "$resolved" | tail -1)${NC}"
        else
            echo -e "${RED}❌ Failed to resolve${NC}"
        fi
        echo ""
    done
}

main() {
    if [ $# -lt 1 ]; then
        usage
        exit 1
    fi
    
    local perf_report="$1"
    local binary_path="$2"
    
    # Check if perf report exists
    if [ ! -f "$perf_report" ]; then
        log_error "Perf report file not found: $perf_report"
        exit 1
    fi
    
    # Get binary path
    if [ -z "${binary_path:-}" ]; then
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
    
    resolve_symbols "$perf_report" "$binary_path"
    
    # Cleanup if we extracted the binary
    if [ "${binary_path}" = "/tmp/nvmf_tgt_"* ]; then
        rm -f "$binary_path"
        log_info "Cleaned up extracted binary"
    fi
}

main "$@"










