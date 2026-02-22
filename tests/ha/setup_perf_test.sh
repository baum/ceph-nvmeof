#!/bin/bash
set -xe

# Setup script for performance test
# This script prepares the environment for the performance test

echo "🔧 Setting up performance test environment"

# Check if perf binary exists
PERF_BINARY="/data/code/linux/tools/perf/perf"
if [ ! -f "$PERF_BINARY" ]; then
    echo "❌ perf binary not found at $PERF_BINARY"
    echo "Please build the Linux perf tool first:"
    echo "  cd /data/code/linux/tools/perf"
    echo "  make"
    exit 1
fi

echo "✅ perf binary found at $PERF_BINARY"

# Check if jq is available (needed for JSON parsing)
if ! command -v jq &> /dev/null; then
    echo "❌ jq is not installed. Please install jq for JSON parsing"
    exit 1
fi

echo "✅ jq is available"

# Check if docker compose is available
if ! command -v docker &> /dev/null; then
    echo "❌ docker is not available"
    exit 1
fi

echo "✅ docker is available"

# Check if make is available
if ! command -v make &> /dev/null; then
    echo "❌ make is not available"
    exit 1
fi

echo "✅ make is available"

# Create results directory
RESULTS_BASE_DIR="/tmp/nvmeof_perf_test"
mkdir -p "$RESULTS_BASE_DIR"

echo "✅ Results directory created: $RESULTS_BASE_DIR"

echo ""
echo "🎉 Performance test environment setup completed!"
echo "You can now run the performance test with:"
echo "  ./tests/ha/perf_test.sh"












