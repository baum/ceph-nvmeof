#!/bin/sh
# perf_comparison.sh - Run both perf_default and perf_spdk_wq on the SAME runner
# Phase 1: Default (AsioContextWQ) config
# Phase 2: SPDK WQ (SpdkContextWQ) config
# Ensures fair comparison by eliminating runner-to-runner variance.

set -xe

REPO_ROOT="${GITHUB_WORKSPACE:-$(cd "$(dirname "$0")/../.." && pwd)}"
test_dir="$REPO_ROOT/tests/ha"
cd "$REPO_ROOT"

. "./.env"
POOL="${RBD_POOL:-rbd}"

echo "========== Phase 1: perf_default (AsioContextWQ) =========="
export NVMEOF_CONFIG=./tests/ceph-nvmeof.perf-test.conf
./tests/ha/perf_record_during_io.sh perf_default 10

echo "========== Phase 2: Restart gateway with SPDK WQ config =========="
# Delete old gateway from ceph before removing container
GW_OLD=$(docker ps -q --filter name=nvmeof | head -1)
if [ -n "$GW_OLD" ]; then
  echo "Deleting old gateway $GW_OLD from ceph"
  docker compose exec -T ceph ceph nvme-gw delete "$GW_OLD" "$POOL" '' 2>/dev/null || true
fi
# Stop and remove nvmeof/discovery so we can recreate with new config (keep ceph)
docker compose stop nvmeof discovery bdevperf 2>/dev/null || true
docker compose rm -f nvmeof discovery 2>/dev/null || true

# Start with SPDK WQ config (same pattern as other tests)
export NVMEOF_CONFIG=./tests/ceph-nvmeof.perf-test.spdk_wq.conf
echo "Starting 1 nvmeof gateway with rbd_with_spdk_wq=True"
docker compose up -d --remove-orphans --scale nvmeof=1 nvmeof discovery

# Register gateway with ceph (same as start_up.sh)
GW_GROUP=$(grep '^group' "$NVMEOF_CONFIG" 2>/dev/null | sed 's/^[^=]*=//' | sed 's/^ *//' | sed 's/ *$//' || true)
GW_GROUP="${GW_GROUP:-}"
for i in 1; do
  for wait in $(seq 30); do
    GW_NAME=$(docker ps --format '{{.ID}}\t{{.Names}}' | grep -v discovery | awk -v i=$i '$2 ~ /nvmeof/ && $2 ~ i {print $1}')
    [ -n "$GW_NAME" ] && break
    sleep 1
  done
  echo "nvme-gw create gateway: '$GW_NAME' pool: '$POOL', group: '$GW_GROUP'"
  docker compose exec -T ceph ceph nvme-gw create "$GW_NAME" "$POOL" "$GW_GROUP"
done

echo "Waiting for gateway to be ready..."
"$test_dir/wait_gateways.sh" 1

# New gateway has fresh state - need to set up target again (subsystem, namespaces, listener)
echo "Setting up target (subsystem, namespaces, listener)..."
"$test_dir/setup_perf_spdk_wq.sh"

echo "========== Phase 2: perf_spdk_wq (SpdkContextWQ) =========="
./tests/ha/perf_record_during_io.sh perf_spdk_wq 10

echo "========== perf_comparison complete =========="
echo "Artifacts: artifacts/perf_ci_perf_default_* and artifacts/perf_ci_perf_spdk_wq_*"
ls -la artifacts/perf_ci_perf_default_* 2>/dev/null || true
ls -la artifacts/perf_ci_perf_spdk_wq_* 2>/dev/null || true
