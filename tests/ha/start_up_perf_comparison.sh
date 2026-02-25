#!/bin/sh
set -ex

# Phase 1 uses perf-test config (AsioContextWQ). Phase 2 restarts with SPDK WQ in perf_comparison.sh.
if [ -n "$GITHUB_WORKSPACE" ]; then
    test_dir="$GITHUB_WORKSPACE/tests/ha"
else
    test_dir=$(dirname $0)
fi
cd "$(dirname $0)/../.."

# Same pattern as other start_up_*.sh (e.g. start_up_spdk_wq.sh)
export NVMEOF_CONFIG=./tests/ceph-nvmeof.perf-test.conf
$test_dir/start_up.sh 1
