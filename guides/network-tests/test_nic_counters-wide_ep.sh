#!/bin/bash

# Wide-EP Test with NIC Counter Tracking
# Usage: NET_DEBUG_NS=<debug-ns> ./test_nic_counters-wide_ep.sh <namespace>
# Example: NET_DEBUG_NS=kube-system ./test_nic_counters-wide_ep.sh llm-d
#
# This script automatically discovers nodes running wide-ep-llm-d-decode* and 
# wide-ep-llm-d-prefill* pods in the given namespace.
# Tracks RX counters for priorities 0, 1, and 5, plus ECN and PFC pause counters.
#
# Required environment variables:
#   NET_DEBUG_NS - Namespace where networking-debug-pods are deployed

# Source the shared NIC counter utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/nic_counter_utils.sh"

if [ $# -lt 1 ]; then
    echo "Usage: NET_DEBUG_NS=<debug-ns> $0 <namespace>"
    echo "Example: NET_DEBUG_NS=kube-system $0 llm-d"
    exit 1
fi

NAMESPACE=$1

echo ""
echo "=============================================="
echo "Discovering Wide-EP Pods in namespace: $NAMESPACE"
echo "=============================================="

# Find all wide-ep decode and prefill pods
pod_names=()

echo ""
echo "Discovered Decode Pods:"
while IFS= read -r pod_name; do
    [ -z "$pod_name" ] && continue
    pod_names+=("$pod_name")
    echo "  - $pod_name"
done < <(kubectl get pods -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep "^wide-ep-llm-d-decode")

echo ""
echo "Discovered Prefill Pods:"
while IFS= read -r pod_name; do
    [ -z "$pod_name" ] && continue
    pod_names+=("$pod_name")
    echo "  - $pod_name"
done < <(kubectl get pods -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep "^wide-ep-llm-d-prefill")

if [ ${#pod_names[@]} -eq 0 ]; then
    echo "ERROR: No wide-ep-llm-d-decode* or wide-ep-llm-d-prefill* pods found in namespace $NAMESPACE"
    exit 1
fi

# Initialize NIC counter utils (discovers nodes and networking-debug-pods)
init_nic_counter_utils pod_names "$NAMESPACE" || exit 1

# ============================================
# MAIN SCRIPT EXECUTION
# ============================================

# Collect and print BEFORE counters
collect_all_counters pod_names "before"
print_all_counters pod_names "before"

# Run the benchmark test via the poker pod (foreground, max 10 minutes)
BENCHMARK_TIMEOUT_SEC=900  # 15 minutes
echo ""
echo "=============================================="
echo "Running Benchmark Test via Poker Pod (timeout: ${BENCHMARK_TIMEOUT_SEC}s)"
echo "=============================================="
echo ""
echo "Running: just benchmark 4096 4096 256 128"
echo ""

timeout "$BENCHMARK_TIMEOUT_SEC" kubectl exec -n "$NAMESPACE" poker -- /bin/zsh -c "cd /app && just benchmark 4096 4096 256 128" 2>&1
BENCH_EXIT=$?

echo ""
if [ "$BENCH_EXIT" -eq 124 ]; then
    echo "=============================================="
    echo "Benchmark did not finish within ${BENCHMARK_TIMEOUT_SEC}s; killed. Proceeding with counter collection."
    echo "=============================================="
else
    echo "=============================================="
    echo "Benchmark Test Completed (exit $BENCH_EXIT)"
    echo "=============================================="
fi
echo ""

# Collect and print AFTER counters
collect_all_counters pod_names "after"
print_all_counters pod_names "after"

# Print counter differences
print_all_counter_diff pod_names

# Print summaries
print_all_summaries pod_names
# print_final_notes
