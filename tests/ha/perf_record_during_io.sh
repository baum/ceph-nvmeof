#!/bin/bash

# perf_record_during_io.sh - Record perf data during bdevperf I/O for CI
# Usage: ./perf_record_during_io.sh VARIANT [DURATION]
#   VARIANT: perf_default | perf_spdk_wq (for artifact naming)
#   DURATION: perf recording seconds (default 10)
#
# Runs bdevperf for 1 second (BDEVPERF_TEST_DURATION=1) while recording perf
# on reactor_0. Generates perf.data, reports, and flame graphs.

set -e

VARIANT="${1:?Usage: $0 VARIANT [DURATION]}"
PERF_DURATION="${2:-10}"

# Ensure we run from repo root (CI or local)
REPO_ROOT="${GITHUB_WORKSPACE:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$REPO_ROOT"

RESULTS_DIR="$REPO_ROOT/artifacts/perf_ci_${VARIANT}_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULTS_DIR"

echo "ℹ️  Perf recording: variant=$VARIANT duration=${PERF_DURATION}s, results=$RESULTS_DIR"

# Copy config for reference
NVMEOF_CONFIG="${NVMEOF_CONFIG:-./ceph-nvmeof.conf}"
if [ -f "$NVMEOF_CONFIG" ]; then
    cp "$NVMEOF_CONFIG" "$RESULTS_DIR/gateway_config.conf"
fi

# Get nvmeof container (gateway 1)
CONTAINER_ID=$(docker ps --format '{{.ID}}\t{{.Names}}' | awk '$2 ~ /nvmeof/ && $2 ~ /1/ {print $1}' | head -1)
if [ -z "$CONTAINER_ID" ]; then
    echo "❌ No nvmeof container found"
    exit 1
fi

# Allow perf to profile
sudo sysctl -w kernel.perf_event_paranoid=-1 2>/dev/null || true

# Find reactor_0 PID
nvmf_pid=$(docker exec "$CONTAINER_ID" sh -c 'for pid in /proc/[0-9]*; do if [ -f "$pid/comm" ] && grep -q "reactor_0" "$pid/comm" 2>/dev/null; then basename "$pid"; break; fi; done')
if [ -z "$nvmf_pid" ]; then
    echo "❌ reactor_0 not found in container"
    exit 1
fi

echo "ℹ️  Recording perf on reactor_0 (PID $nvmf_pid) for ${PERF_DURATION}s..."

# Start perf recording in background
docker exec "$CONTAINER_ID" /usr/bin/perf record -p "$nvmf_pid" -g -o /tmp/perf.data sleep "$PERF_DURATION" &
perf_pid=$!

# Wait for perf to start
sleep 3

# Run bdevperf (1 second) - same flow as sanity.sh but with 1s duration
GW1_NAME=$(docker ps --format '{{.ID}}\t{{.Names}}' | awk '$2 ~ /nvmeof/ && $2 ~ /1/ {print $1}')
ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$GW1_NAME")

echo "ℹ️  Starting bdevperf container (1s test duration for perf recording)"
export BDEVPERF_TEST_DURATION=1
docker compose up -d bdevperf
sleep 5

eval $(make run SVC=bdevperf OPTS="--entrypoint=env" | grep BDEVPERF_SOCKET | tr -d '\n\r')
rpc="/usr/libexec/spdk/scripts/rpc.py"
NVMEOF_DISC_PORT=8009

make exec SVC=bdevperf OPTS=-T CMD="$rpc -v -s $BDEVPERF_SOCKET bdev_nvme_set_options -r -1"
make exec SVC=bdevperf OPTS=-T CMD="$rpc -v -s $BDEVPERF_SOCKET bdev_nvme_start_discovery -b Nvme0 -t tcp -a $ip -s $NVMEOF_DISC_PORT -f ipv4 -w"
make exec SVC=bdevperf OPTS=-T CMD="$rpc -v -s $BDEVPERF_SOCKET bdev_nvme_get_discovery_info"

# Run perform_tests (duration=1s set via BDEVPERF_TEST_DURATION at container start)
bdevperf="/usr/libexec/spdk/scripts/bdevperf.py"
eval $(make run SVC=bdevperf OPTS="--entrypoint=env" | grep BDEVPERF_TEST_DURATION | tr -d '\n\r')
timeout=$(expr ${BDEVPERF_TEST_DURATION:-1} \* 2)
make exec SVC=bdevperf OPTS=-T CMD="$bdevperf -v -t $timeout -s $BDEVPERF_SOCKET perform_tests"

# Wait for perf to finish
wait $perf_pid 2>/dev/null || true

# Copy and generate reports
docker cp "$CONTAINER_ID:/tmp/perf.data" "$RESULTS_DIR/perf.data"
docker exec "$CONTAINER_ID" /usr/bin/perf script -i /tmp/perf.data > "$RESULTS_DIR/perf_script.txt" 2>/dev/null || true
docker exec "$CONTAINER_ID" /usr/bin/perf report -i /tmp/perf.data > "$RESULTS_DIR/perf_report.txt" 2>&1 || true

# Flame graphs
if [ ! -f "./bin/flamegraph.pl" ] || [ ! -f "./bin/stackcollapse-perf.pl" ]; then
    echo "ℹ️  Installing FlameGraph tools..."
    mkdir -p ./bin
    (cd /tmp && [ ! -d FlameGraph ] && git clone --depth 1 https://github.com/brendangregg/FlameGraph.git)
    ln -sf /tmp/FlameGraph/flamegraph.pl ./bin/flamegraph.pl 2>/dev/null || true
    ln -sf /tmp/FlameGraph/stackcollapse-perf.pl ./bin/stackcollapse-perf.pl 2>/dev/null || true
fi

if [ -f "./bin/stackcollapse-perf.pl" ] && [ -f "$RESULTS_DIR/perf_script.txt" ]; then
    ./bin/stackcollapse-perf.pl "$RESULTS_DIR/perf_script.txt" > "$RESULTS_DIR/stack_collapse.txt" 2>/dev/null || true
    if [ -s "$RESULTS_DIR/stack_collapse.txt" ] && [ -f "./bin/flamegraph.pl" ]; then
        ./bin/flamegraph.pl --width=100000 --minwidth=0 "$RESULTS_DIR/stack_collapse.txt" > "$RESULTS_DIR/flame_graph.svg" 2>/dev/null || true
        ./bin/flamegraph.pl --width=100000 --minwidth=0 --countname=cpu "$RESULTS_DIR/stack_collapse.txt" > "$RESULTS_DIR/cpu_flame_graph.svg" 2>/dev/null || true
        ./bin/flamegraph.pl --width=100000 --minwidth=0 --countname=memory "$RESULTS_DIR/stack_collapse.txt" > "$RESULTS_DIR/memory_flame_graph.svg" 2>/dev/null || true
        echo "✅ Flame graphs generated"
    fi
fi

# Metadata
{
    echo "=== Perf CI Recording ==="
    echo "Variant: $VARIANT"
    echo "Date: $(date)"
    echo "Perf duration: ${PERF_DURATION}s"
    echo "Bdevperf duration: 1s"
    echo "Results: $RESULTS_DIR"
} > "$RESULTS_DIR/metadata.txt"

echo "✅ Perf recording complete: $RESULTS_DIR"
ls -la "$RESULTS_DIR"
