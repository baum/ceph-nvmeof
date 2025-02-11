# Check if GITHUB_WORKSPACE is defined
if [ -n "$GITHUB_WORKSPACE" ]; then
    test_dir="$GITHUB_WORKSPACE/tests/ha"
else
    test_dir=$(dirname $0)
fi

# Get the number of available CPU cores
CPU_CORES=$(grep -c ^processor /proc/cpuinfo)

# Check if there are at least 8 cores
if [ "$CPU_CORES" -ge 8 ]; then
    echo "Sufficient CPU cores available: $CPU_CORES"
else
    echo "Insufficient CPU cores: Only $CPU_CORES cores available."
    exit 1
fi

export NVMEOF_CONFIG=./tests/ceph-nvmeof.librbd_qos.conf
$test_dir/start_up.sh 2
