#!/bin/sh
set -xe

GW1_NAME=$(docker ps --format '{{.ID}}\t{{.Names}}' | awk '$2 ~ /nvmeof/ && $2 ~ /1/ {print $1}')
GW1_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$GW1_NAME")"
NQN="nqn.2016-06.io.spdk:cnode17"
NS_COUNT=400
MAX_NS=1024
cephnvmf="docker compose run -T --remove-orphans --rm nvmeof-cli --server-address $GW1_IP --server-port 5500"

# Add subsystem
$cephnvmf subsystem add --subsystem $NQN --max-namespaces $MAX_NS

# Arrays to track PIDs and NSIDs
PIDS=""
NSIDS=""

# Function to create namespace and set QoS
create_ns_and_set_qos() {
    i=$1
    $cephnvmf namespace add -n $NQN --rbd-pool rbd --rbd-image image$i --rbd-create-image --size 1MB
    if [ $? -ne 0 ]; then
        echo "‼️  ERROR: Namespace creation failed for NSID=$i" >&2
        exit 1
    fi

    $cephnvmf namespace set_qos -n $NQN --nsid $i --rw-ios-per-second 1000 --rw-megabytes-per-second 19 --r-megabytes-per-second 19 --w-megabytes-per-second 19
    if [ $? -ne 0 ]; then
        echo "‼️  ERROR: QoS setup failed for NSID=$i" >&2
        exit 1
    fi
}

# Run tasks in parallel and store PIDs & NSIDs in memory
for i in $(seq $NS_COUNT); do
    create_ns_and_set_qos $i &
    PIDS="$PIDS $!"  # Append PID to list
    NSIDS="$NSIDS $i"  # Append NSID to list
done

# Convert strings to arrays
set -- $PIDS  # `$1, $2, ...` now store PIDs
NSID_ARRAY=$NSIDS  # Preserve NSIDs separately

# Wait for all jobs and verify their exit codes
FAILED=0
i=1
for pid in "$@"; do
    wait "$pid"
    if [ $? -ne 0 ]; then
        NSID=$(echo $NSID_ARRAY | cut -d' ' -f$i)  # Extract matching NSID
        echo "ERROR: Task for NSID=$NSID failed!" >&2
        FAILED=1
    fi
    i=$((i + 1))
done

# Exit with error if any task failed
if [ $FAILED -ne 0 ]; then
    echo "‼️  One or more namespace or QoS setup tasks failed!" >&2
    exit 1
fi

echo "✅ All namespace and QoS setup tasks completed successfully."
exit 0

