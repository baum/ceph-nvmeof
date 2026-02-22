#!/bin/sh

set -ex

# Perf test with default gateway config (no SPDK WQ)
# Uses default NVMEOF_CONFIG from .env (ceph-nvmeof.conf)

if [ -n "$GITHUB_WORKSPACE" ]; then
    test_dir="$GITHUB_WORKSPACE/tests/ha"
else
    test_dir=$(dirname $0)
fi

$test_dir/start_up.sh 1
