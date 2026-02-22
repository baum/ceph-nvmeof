#!/bin/bash
set -xe

# Perf test with default gateway config (no SPDK WQ)
# Records perf during 1s bdevperf run, generates flame graphs

./tests/ha/perf_record_during_io.sh perf_default 10
