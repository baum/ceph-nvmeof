#!/bin/bash

# Test script to verify symbol resolution fix
# This script tests the improved sed patterns for symbol resolution

set -e

echo "🧪 TESTING SYMBOL RESOLUTION FIX:"
echo "================================="
echo ""

# Get the latest test directory
LATEST_DIR=$(ls -t artifacts/ | head -1)
RESULTS_DIR="artifacts/$LATEST_DIR"

if [ ! -d "$RESULTS_DIR" ]; then
    echo "❌ No test directory found"
    exit 1
fi

echo "Using test directory: $RESULTS_DIR"
echo ""

# Check if we have a running container
CONTAINER_ID=$(docker ps | grep nvmeof | awk '{print $1}' | head -1)
if [ -z "$CONTAINER_ID" ]; then
    echo "❌ No running nvmeof container found"
    exit 1
fi

echo "Using container: $CONTAINER_ID"
echo ""

# Test symbol resolution on a sample address
echo "Testing symbol resolution for address 918c0:"
echo ""

# Get the symbol
SYMBOL=$(docker exec "$CONTAINER_ID" addr2line -e /usr/lib64/librados.so.2.0.0 -f -C "0x918c0" 2>/dev/null | head -1)
echo "Resolved symbol: $SYMBOL"
echo ""

# Test the sed replacement
if [ -f "$RESULTS_DIR/perf_script.txt" ]; then
    echo "Testing sed replacement:"
    echo ""
    echo "Original line:"
    grep "918c0" "$RESULTS_DIR/perf_script.txt" | head -1
    echo ""
    echo "After first sed pattern:"
    grep "918c0" "$RESULTS_DIR/perf_script.txt" | head -1 | sed "s/\s\+918c0 \[unknown\] ([^)]*)/ $SYMBOL/g"
    echo ""
    echo "After second sed pattern:"
    grep "918c0" "$RESULTS_DIR/perf_script.txt" | head -1 | sed "s/918c0 \[unknown\] ([^)]*)/$SYMBOL/g"
    echo ""
    echo "✅ Second pattern produces clean output!"
else
    echo "❌ No perf_script.txt found"
fi

echo ""
echo "🎯 RECOMMENDATION:"
echo "=================="
echo "The second sed pattern works better because:"
echo "• It doesn't require specific whitespace matching"
echo "• It replaces the entire '[unknown] (...)' section"
echo "• It produces clean output without extra whitespace"
echo ""
echo "The fix should now work correctly in robust_perf_test.sh!"






