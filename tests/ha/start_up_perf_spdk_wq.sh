#!/bin/sh

set -ex

# Perf test with SPDK WQ enabled (rbd_with_spdk_wq = True)

if [ -n "$GITHUB_WORKSPACE" ]; then
    test_dir="$GITHUB_WORKSPACE/tests/ha"
else
    test_dir=$(dirname $0)
fi

export NVMEOF_CONFIG=./tests/ceph-nvmeof.spdk_wq.conf
$test_dir/start_up.sh 1
