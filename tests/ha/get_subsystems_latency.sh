#!/bin/sh
set -e

# Configuration
NUM_NAMESPACES="${NUM_NAMESPACES:-1024}"  # Configurable, default 1k
NUM_GATEWAYS=3
MAX_NAMESPACES_PER_SUBSYSTEM=512  # Default from control/grpc.py
MAX_LATENCY_SECONDS="${MAX_LATENCY_SECONDS:-5}"  # Configurable max latency threshold
NQN_PREFIX="nqn.2016-06.io.spdk:cnode-latency"
LATENCY_LOG="/tmp/get_subsystems_latency.log"
GATEWAY_START_TIMES_FILE="/tmp/gateway_start_times.txt"
GATEWAY_LOGS_SNAPSHOT="/tmp/gateway_logs_snapshot.txt"

# Calculate number of subsystems needed
NUM_SUBSYSTEMS=$(( (NUM_NAMESPACES + MAX_NAMESPACES_PER_SUBSYSTEM - 1) / MAX_NAMESPACES_PER_SUBSYSTEM ))

# GW name by index
gw_name() {
  i=$1
  docker ps -a --format '{{.ID}}\t{{.Names}}' | awk '$2 ~ /nvmeof/ && $2 ~ /-'$i'$/ {print $1}'
}

gw_ip() {
  docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$(gw_name $1)"
}

# Get gateway start time (started at timestamp)
get_gateway_start_time() {
  gw_name=$1
  docker inspect -f '{{.State.StartedAt}}' "$gw_name"
}

# Save all gateway start times
save_gateway_start_times() {
  echo "ℹ️  Saving gateway start times to $GATEWAY_START_TIMES_FILE"
  > "$GATEWAY_START_TIMES_FILE"
  for i in $(seq $NUM_GATEWAYS); do
    gw=$(gw_name $i)
    start_time=$(get_gateway_start_time "$gw")
    echo "$gw:$start_time" >> "$GATEWAY_START_TIMES_FILE"
    echo "   Gateway $i ($gw): $start_time"
  done
}

# Check if any gateway has restarted by comparing start times
check_gateway_restarts() {
  echo "ℹ️  Checking for gateway restarts..."
  if [ ! -f "$GATEWAY_START_TIMES_FILE" ]; then
    echo "❌ Gateway start times file not found!"
    return 1
  fi
  
  restart_detected=0
  while IFS=: read -r gw_id original_start_time; do
    current_start_time=$(get_gateway_start_time "$gw_id")
    if [ "$original_start_time" != "$current_start_time" ]; then
      echo "❌ Gateway restart detected for $gw_id!"
      echo "   Original start time: $original_start_time"
      echo "   Current start time:  $current_start_time"
      restart_detected=1
    fi
  done < "$GATEWAY_START_TIMES_FILE"
  
  if [ $restart_detected -eq 0 ]; then
    echo "✅ No gateway restarts detected"
  fi
  
  return $restart_detected
}

# Measure get_subsystems latency and count namespaces
measure_get_subsystems_latency() {
  gw_ip=$1
  gw_index=$2
  
  start_time=$(date +%s.%N)
  subs=$(docker compose run -T --rm nvmeof-cli --server-address "$gw_ip" --server-port 5500 get_subsystems 2>&1 | grep -v Creating | sed '/^Get subsystems:/d' || echo "[]")
  end_time=$(date +%s.%N)
  
  # Calculate latency in seconds using awk (bc not available)
  latency=$(echo "$start_time $end_time" | awk '{printf "%.3f", $2 - $1}')
  
  # Count namespaces across all subsystems
  total_ns_count=0
  for sub_idx in $(seq 1 $NUM_SUBSYSTEMS); do
    nqn="${NQN_PREFIX}-${sub_idx}"
    ns_count=$(echo "$subs" | jq -r --arg nqn "$nqn" '[.subsystems[] | select(.nqn == $nqn) | .namespaces | length] | .[0] // 0' 2>/dev/null || echo "0")
    total_ns_count=$((total_ns_count + ns_count))
  done
  
  # Return format: "latency_seconds namespace_count"
  echo "$latency $total_ns_count"
}

# Check if gateway has restarted by comparing with snapshot
check_gateway_restart() {
  gw_name=$1
  # Use cut -d: -f2- to get everything after the first colon (timestamp has colons too)
  original_start_time=$(grep "^$gw_name:" "$GATEWAY_START_TIMES_FILE" | cut -d: -f2-)
  current_start_time=$(get_gateway_start_time "$gw_name")
  
  if [ "$original_start_time" != "$current_start_time" ]; then
    echo "RESTART_DETECTED"
    return 1
  fi
  return 0
}

# Check for panic in gateway logs
check_gateway_panic() {
  gw_name=$1
  
  # Get logs since the snapshot
  if docker logs "$gw_name" 2>&1 | grep -i "panic" > /dev/null; then
    echo "PANIC_DETECTED"
    return 1
  fi
  return 0
}

# Wait for all namespaces to be visible on a gateway (across all subsystems)
wait_for_namespaces() {
  gw_ip=$1
  expected_total_ns=$2
  timeout_seconds=600
  
  echo "ℹ️  Waiting for $expected_total_ns total namespaces on gateway at $gw_ip (timeout: ${timeout_seconds}s)..."
  
  start_time=$(date +%s)
  while true; do
    current_time=$(date +%s)
    elapsed=$((current_time - start_time))
    
    if [ $elapsed -ge $timeout_seconds ]; then
      echo "❌ Timeout waiting for namespaces after ${timeout_seconds}s"
      return 1
    fi
    
    # Get subsystems and count total namespaces across all our test subsystems
    subs=$(docker compose run -T --rm nvmeof-cli --server-address "$gw_ip" --server-port 5500 get_subsystems 2>&1 | grep -v Creating | sed '/^Get subsystems:/d' || echo "[]")
    
    # Count namespaces across all subsystems matching our prefix
    total_ns_count=0
    for sub_idx in $(seq 1 $NUM_SUBSYSTEMS); do
      nqn="${NQN_PREFIX}-${sub_idx}"
      ns_count=$(echo "$subs" | jq -r --arg nqn "$nqn" '[.subsystems[] | select(.nqn == $nqn) | .namespaces | length] | .[0] // 0' 2>/dev/null || echo "0")
      total_ns_count=$((total_ns_count + ns_count))
    done
    
    if [ "$total_ns_count" -eq "$expected_total_ns" ]; then
      echo "✅ All $expected_total_ns namespaces are visible on gateway (across $NUM_SUBSYSTEMS subsystems)"
      return 0
    fi
    
    echo "   Current: $total_ns_count namespaces, Expected: $expected_total_ns (elapsed: ${elapsed}s)"
    sleep 5
  done
}

# Create namespaces in batches for a specific subsystem
create_namespaces() {
  gw_ip=$1
  subsystem_nqn=$2
  start_ns=$3
  end_ns=$4
  ana_grp=$5
  
  echo "ℹ️  Creating namespaces $start_ns to $end_ns on subsystem $subsystem_nqn (ANA group $ana_grp)"
  
  for nsid in $(seq $start_ns $end_ns); do
    # Use global namespace ID for unique image names
    global_nsid=$(($start_ns + $nsid - $start_ns))
    image="latency_test_image_${global_nsid}"
    
    # NSID within subsystem (1-based, wrapping within MAX_NAMESPACES_PER_SUBSYSTEM)
    local_nsid=$(( (nsid - 1) % MAX_NAMESPACES_PER_SUBSYSTEM + 1 ))
    
    # Create namespace
    docker compose run -T --rm nvmeof-cli \
      --server-address "$gw_ip" \
      --server-port 5500 \
      namespace add \
      --subsystem "$subsystem_nqn" \
      --nsid "$local_nsid" \
      --rbd-pool rbd \
      --rbd-image "$image" \
      --size 10M \
      --rbd-create-image \
      -l "$ana_grp"
    
    # Progress indicator
    if [ $((nsid % 100)) -eq 0 ]; then
      echo "   Created $(($nsid - $start_ns + 1)) namespaces in this batch..."
    fi
  done
  
  echo "✅ Created namespaces $start_ns to $end_ns for $subsystem_nqn"
}

# Calculate and print statistics from latency measurements
calculate_statistics() {
  log_file=$1
  gateway_name=$2
  
  # Extract latency values (in seconds)
  latencies=$(awk '{print $1}' "$log_file" | grep -E '^[0-9.]+$' || echo "")
  
  if [ -z "$latencies" ]; then
    echo "  No measurements for $gateway_name"
    return 1
  fi
  
  count=$(echo "$latencies" | wc -l)
  min=$(echo "$latencies" | sort -n | head -n1)
  max=$(echo "$latencies" | sort -n | tail -n1)
  avg=$(echo "$latencies" | awk '{sum+=$1; sumsq+=$1*$1} END {print sum/NR}')
  
  # Calculate standard deviation
  stddev=$(echo "$latencies" | awk -v avg="$avg" '{sum+=($1-avg)^2} END {print sqrt(sum/NR)}')
  
  echo ""
  echo "Gateway $gateway_name Statistics:"
  echo "-----------------------------------"
  printf "  Samples:      %d\n" "$count"
  printf "  Min latency:  %.3f seconds\n" "$min"
  printf "  Max latency:  %.3f seconds\n" "$max"
  printf "  Avg latency:  %.3f seconds\n" "$avg"
  printf "  Std Dev:      %.3f seconds\n" "$stddev"
  
  # Check if max exceeds threshold using awk (bc not available)
  threshold_exceeded=$(echo "$max $MAX_LATENCY_SECONDS" | awk '{print ($1 > $2)}')
  if [ "$threshold_exceeded" = "1" ]; then
    echo "  ❌ FAILED: Max latency $max s exceeds threshold $MAX_LATENCY_SECONDS s"
    return 1
  else
    echo "  ✅ PASSED: Max latency within threshold"
    return 0
  fi
}

# Main test logic
main() {
  echo "════════════════════════════════════════════════════════════════"
  echo "  GET_SUBSYSTEMS LATENCY TEST"
  echo "════════════════════════════════════════════════════════════════"
  echo "Configuration:"
  echo "  Number of namespaces:          $NUM_NAMESPACES"
  echo "  Number of gateways:            $NUM_GATEWAYS"
  echo "  Max NS per subsystem:          $MAX_NAMESPACES_PER_SUBSYSTEM"
  echo "  Number of subsystems required: $NUM_SUBSYSTEMS"
  echo "  Subsystem NQN prefix:          $NQN_PREFIX"
  echo "  Max latency threshold:         $MAX_LATENCY_SECONDS seconds"
  echo "════════════════════════════════════════════════════════════════"
  echo ""
  
  # Clean up old log files
  rm -f ${LATENCY_LOG}.gw*
  rm -f "$GATEWAY_START_TIMES_FILE"
  
  # Step 1: Create subsystems
  echo "ℹ️  Step 1: Creating $NUM_SUBSYSTEMS subsystems"
  gw1_ip=$(gw_ip 1)
  
  for sub_idx in $(seq 1 $NUM_SUBSYSTEMS); do
    nqn="${NQN_PREFIX}-${sub_idx}"
    
    # Calculate max namespaces for this subsystem
    remaining_ns=$((NUM_NAMESPACES - (sub_idx - 1) * MAX_NAMESPACES_PER_SUBSYSTEM))
    if [ $remaining_ns -gt $MAX_NAMESPACES_PER_SUBSYSTEM ]; then
      max_ns=$MAX_NAMESPACES_PER_SUBSYSTEM
    else
      max_ns=$remaining_ns
    fi
    
    echo "   Creating subsystem $sub_idx/$NUM_SUBSYSTEMS: $nqn (max: $max_ns namespaces)"
    docker compose run -T --rm nvmeof-cli \
      --server-address "$gw1_ip" \
      --server-port 5500 \
      subsystem add \
      --subsystem "$nqn" \
      --max-namespaces "$max_ns" \
      --no-group-append
  done
  
  echo "✅ All $NUM_SUBSYSTEMS subsystems created"
  echo ""
  
  # Step 2: Create namespaces (split across subsystems and gateways)
  echo "ℹ️  Step 2: Creating $NUM_NAMESPACES namespaces across $NUM_SUBSYSTEMS subsystems"
  
  pids=""  # Space-separated list of PIDs instead of array
  global_ns_counter=1
  
  # Create namespaces for each subsystem
  for sub_idx in $(seq 1 $NUM_SUBSYSTEMS); do
    nqn="${NQN_PREFIX}-${sub_idx}"
    
    # Calculate how many namespaces for this subsystem
    remaining_total=$((NUM_NAMESPACES - global_ns_counter + 1))
    if [ $remaining_total -gt $MAX_NAMESPACES_PER_SUBSYSTEM ]; then
      ns_for_this_subsystem=$MAX_NAMESPACES_PER_SUBSYSTEM
    else
      ns_for_this_subsystem=$remaining_total
    fi
    
    # Split this subsystem's namespaces across gateways for parallel creation
    ns_per_gw=$((ns_for_this_subsystem / NUM_GATEWAYS))
    remainder=$((ns_for_this_subsystem % NUM_GATEWAYS))
    
    for gw_idx in $(seq 1 $NUM_GATEWAYS); do
      # Calculate range for this gateway
      start_offset=$(( (gw_idx - 1) * ns_per_gw ))
      end_offset=$(( gw_idx * ns_per_gw - 1 ))
      
      # Add remainder to last gateway
      if [ $gw_idx -eq $NUM_GATEWAYS ]; then
        end_offset=$((end_offset + remainder))
      fi
      
      # Skip if no namespaces for this gateway
      if [ $start_offset -gt $end_offset ]; then
        continue
      fi
      
      start_ns=$((global_ns_counter + start_offset))
      end_ns=$((global_ns_counter + end_offset))
      
      gw_ip=$(gw_ip $gw_idx)
      ana_grp=$gw_idx
      
      echo "   Subsystem $sub_idx, Gateway $gw_idx: namespaces $start_ns-$end_ns (ANA group $ana_grp)"
      
      # Create namespaces in parallel
      create_namespaces "$gw_ip" "$nqn" "$start_ns" "$end_ns" "$ana_grp" &
      pids="$pids $!"  # Append PID to space-separated list
    done
    
    global_ns_counter=$((global_ns_counter + ns_for_this_subsystem))
  done
  
  # Wait for all namespace creation to complete
  echo "ℹ️  Waiting for namespace creation to complete..."
  for pid in $pids; do
    wait "$pid" || true  # Don't fail if process already exited
  done
  
  echo "✅ All $NUM_NAMESPACES namespaces created across $NUM_SUBSYSTEMS subsystems"
  echo ""
  
  # Step 3: Restart all gateways
  echo "ℹ️  Step 3: Restarting all gateways"
  echo "   Stopping gateways..."
  for i in $(seq $NUM_GATEWAYS); do
    gw=$(gw_name $i)
    echo "     Gateway $i ($gw)..."
    docker stop "$gw"
  done
  
  sleep 3
  
  echo "   Starting gateways..."
  for i in $(seq $NUM_GATEWAYS); do
    gw=$(gw_name $i)
    echo "     Gateway $i ($gw)..."
    docker start "$gw"
  done
  echo "✅ All gateways restarted"
  echo ""
  
  # Wait for gateways to be operational
  echo "ℹ️  Step 4: Waiting for gateways to be operational"
  for i in $(seq $NUM_GATEWAYS); do
    while true; do
      gw=$(gw_name $i)
      container_status=$(docker inspect -f '{{.State.Status}}' "$gw" 2>/dev/null || echo "unknown")
      if [ "$container_status" = "running" ]; then
        break
      fi
      sleep 1
    done
    
    # Wait until gateway responds
    while true; do
      gw_ip=$(gw_ip $i)
      if docker compose run -T --rm nvmeof-cli --server-address "$gw_ip" --server-port 5500 get_subsystems > /dev/null 2>&1; then
        echo "   Gateway $i is operational"
        break
      fi
      sleep 2
    done
  done
  echo "✅ All gateways are operational"
  echo ""
  
  # Save gateway start times and log snapshots
  save_gateway_start_times
  echo ""
  
  # Step 5: Continuously monitor latency until all namespaces visible
  echo "ℹ️  Step 5: Continuously monitoring get_subsystems latency"
  echo "   Target: All $NUM_NAMESPACES namespaces visible on all gateways"
  echo "   Max latency threshold: $MAX_LATENCY_SECONDS seconds"
  echo ""
  
  # Clean up old log files
  rm -f ${LATENCY_LOG}.gw*.txt
  
  test_failed=0
  all_gateways_ready=0
  iteration=0
  
  while [ $all_gateways_ready -eq 0 ]; do
    iteration=$((iteration + 1))
    echo "--- Iteration $iteration ---"
    
    ready_count=0
    
    for i in $(seq $NUM_GATEWAYS); do
      gw=$(gw_name $i)
      gw_ip=$(gw_ip $i)
      log_file="${LATENCY_LOG}.gw${i}.txt"
      
      # Check for gateway restart
      if ! check_gateway_restart "$gw"; then
        echo "❌ FAILED: Gateway $i restarted!"
        test_failed=1
        break
      fi
      
      # Check for panic in logs
      if ! check_gateway_panic "$gw"; then
        echo "❌ FAILED: Panic detected in gateway $i logs!"
        docker logs --tail 50 "$gw" 2>&1 | grep -i "panic" || true
        test_failed=1
        break
      fi
      
      # Measure latency and count namespaces
      result=$(measure_get_subsystems_latency "$gw_ip" "$i")
      latency=$(echo "$result" | awk '{print $1}')
      ns_count=$(echo "$result" | awk '{print $2}')
      
      # Log the measurement
      echo "$latency $ns_count" >> "$log_file"
      
      printf "   GW%d: latency=%.3fs, namespaces=%d/%d" "$i" "$latency" "$ns_count" "$NUM_NAMESPACES"
      
      # Check latency threshold using awk (bc not available)
      threshold_exceeded=$(echo "$latency $MAX_LATENCY_SECONDS" | awk '{print ($1 > $2)}')
      if [ "$threshold_exceeded" = "1" ]; then
        echo " ❌ FAILED: Latency ${latency}s exceeds threshold ${MAX_LATENCY_SECONDS}s"
        test_failed=1
        break
      fi
      
      # Check if all namespaces visible
      if [ "$ns_count" -eq "$NUM_NAMESPACES" ]; then
        echo " ✅"
        ready_count=$((ready_count + 1))
      else
        echo ""
      fi
    done
    
    # Check if test failed
    if [ $test_failed -eq 1 ]; then
      break
    fi
    
    # Check if all gateways have all namespaces
    if [ $ready_count -eq $NUM_GATEWAYS ]; then
      echo ""
      echo "✅ All $NUM_GATEWAYS gateways show all $NUM_NAMESPACES namespaces!"
      all_gateways_ready=1
      break
    fi
    
    echo ""
    sleep 1
  done
  
  echo ""
  
  # Step 6: Calculate and display statistics
  echo "ℹ️  Step 6: Calculating statistics"
  echo "═══════════════════════════════════════════════════════════════"
  echo "                    LATENCY STATISTICS"
  echo "═══════════════════════════════════════════════════════════════"
  
  stats_failed=0
  for i in $(seq $NUM_GATEWAYS); do
    log_file="${LATENCY_LOG}.gw${i}.txt"
    if [ -f "$log_file" ]; then
      if ! calculate_statistics "$log_file" "$i"; then
        stats_failed=1
      fi
    fi
  done
  
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo ""
  
  # Final test result
  if [ $test_failed -eq 1 ] || [ $stats_failed -eq 1 ]; then
    echo "❌ TEST FAILED"
    exit 1
  fi
  
  echo "✅ TEST PASSED: All checks successful!"
  echo ""
  
  # Step 7: Cleanup
  echo "ℹ️  Step 7: Cleanup - Deleting $NUM_SUBSYSTEMS subsystems"
  for sub_idx in $(seq 1 $NUM_SUBSYSTEMS); do
    nqn="${NQN_PREFIX}-${sub_idx}"
    echo "   Deleting subsystem $sub_idx/$NUM_SUBSYSTEMS: $nqn"
    docker compose run -T --rm nvmeof-cli \
      --server-address "$gw1_ip" \
      --server-port 5500 \
      subsystem del \
      --subsystem "$nqn" \
      --force
  done
  echo "✅ Cleanup completed"
  echo ""
  
  echo "════════════════════════════════════════════════════════════════"
  echo "  TEST COMPLETED SUCCESSFULLY"
  echo "════════════════════════════════════════════════════════════════"
}

# Run main test
main

exit 0

