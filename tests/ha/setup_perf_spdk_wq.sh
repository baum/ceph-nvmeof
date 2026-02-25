#!/bin/sh
set -xe

# Single gateway setup for perf_spdk_wq test (exclude discovery)
# Idempotent: ignore "already exists" (can happen when state persists across gateway restart)
GW1_NAME=$(docker ps --format '{{.ID}}\t{{.Names}}' | grep -v discovery | awk '$2 ~ /nvmeof/ && $2 ~ /1/ {print $1}' | head -1)
GW1_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$GW1_NAME")"
NQN="nqn.2016-06.io.spdk:cnode1"

run_or_ignore_exists() {
  set +e
  out=$(docker compose run --rm nvmeof-cli --server-address "$GW1_IP" --server-port 5500 "$@" 2>&1)
  ret=$?
  set -e
  if [ $ret -ne 0 ] && echo "$out" | grep -qiE "already (exists|used|added|allowed|listens)"; then
    echo "($*) - already exists, skipping"
    return 0
  fi
  echo "$out"
  return $ret
}

run_or_ignore_exists subsystem add --subsystem "$NQN" --no-group-append
run_or_ignore_exists namespace add --subsystem "$NQN" --rbd-pool rbd --rbd-image demo_image1 --size 10M --rbd-create-image -l 1
run_or_ignore_exists namespace add --subsystem "$NQN" --rbd-pool rbd --rbd-image demo_image2 --size 10M --rbd-create-image -l 1
run_or_ignore_exists listener add --subsystem "$NQN" --host-name "$GW1_NAME" --traddr "$GW1_IP" --trsvcid 4420
run_or_ignore_exists host add --subsystem "$NQN" --host-nqn "*"
docker compose run --rm nvmeof-cli --server-address "$GW1_IP" --server-port 5500 get_subsystems
