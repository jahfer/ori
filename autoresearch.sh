#!/bin/bash
set -euo pipefail

# Quick syntax check
ruby -c lib/ori/scope.rb > /dev/null 2>&1
ruby -c lib/ori/task.rb > /dev/null 2>&1

# Run benchmark 5 times and take the median for stability
declare -a ops_results
declare -a total_results

for i in {1..5}; do
  output=$(ruby bench/ori_benchmark.rb 2>/dev/null)
  ops=$(echo "$output" | grep "METRIC ops_per_sec=" | sed 's/METRIC ops_per_sec=//')
  total=$(echo "$output" | grep "METRIC total_ms=" | sed 's/METRIC total_ms=//')
  ops_results+=("$ops")
  total_results+=("$total")
done

# Sort and take median (index 2 of 5)
IFS=$'\n' sorted_ops=($(sort -n <<<"${ops_results[*]}")); unset IFS
IFS=$'\n' sorted_total=($(sort -n <<<"${total_results[*]}")); unset IFS

median_ops=${sorted_ops[2]}
median_total=${sorted_total[2]}

# Run once more to get per-benchmark breakdown
last_output=$(ruby bench/ori_benchmark.rb 2>/dev/null)

echo "METRIC ops_per_sec=$median_ops"
echo "METRIC total_ms=$median_total"
echo "$last_output" | grep -E "METRIC (fork_join|channel|promise|semaphore|broadcast|select|nested_scopes|mixed)_ms="
