#!/bin/bash
set -xe

# Perf test with SPDK WQ enabled (rbd_with_spdk_wq = True)
# Records perf during 1s bdevperf run, generates flame graphs

./tests/ha/perf_record_during_io.sh perf_spdk_wq 10
