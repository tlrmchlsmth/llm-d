#!/bin/bash

# DeepEP Low Latency Test with NIC Counter Tracking
# Usage: NET_DEBUG_NS=<debug-ns> ./test_nic_counters-deepep_ll.sh <namespace>
# Example: NET_DEBUG_NS=kube-system ./test_nic_counters-deepep_ll.sh raj-network-debug
#
# This script automatically discovers pods matching "deepep-test-ll-lws*" pattern
# in the given namespace.
# Tracks RX counters for priorities 0, 1, and 5, plus ECN and PFC pause counters.
#
# Required environment variables:
#   NET_DEBUG_NS - Namespace where networking-debug-pods are deployed

# Source the shared NIC counter utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/nic_counter_utils.sh"

if [ $# -lt 1 ]; then
    echo "Usage: NET_DEBUG_NS=<debug-ns> $0 <namespace>"
    echo "Example: NET_DEBUG_NS=raj-network-debug $0 deepep-ll"
    exit 1
fi

NAMESPACE=$1

echo ""
echo "=============================================="
echo "Discovering DeepEP LWS Pods in namespace: $NAMESPACE"
echo "=============================================="

# Find all deepep-test-ll-lws pods
deepep_pods=()
while IFS= read -r pod_name; do
    [ -z "$pod_name" ] && continue
    deepep_pods+=("$pod_name")
done < <(kubectl get pods -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep "^deepep-test-ll-lws")

if [ ${#deepep_pods[@]} -eq 0 ]; then
    echo "ERROR: No deepep-test-ll-lws* pods found in namespace $NAMESPACE"
    exit 1
fi

if [ ${#deepep_pods[@]} -lt 2 ]; then
    echo "ERROR: Found only ${#deepep_pods[@]} pod(s), but need at least 2 (leader + worker) for DeepEP test"
    exit 1
fi

echo ""
echo "Found ${#deepep_pods[@]} DeepEP pods:"
for pod in "${deepep_pods[@]}"; do
    echo "  - $pod"
done

# Initialize NIC counter utils (discovers nodes and networking-debug-pods)
init_nic_counter_utils deepep_pods "$NAMESPACE" || exit 1

# ============================================
# MAIN SCRIPT EXECUTION
# ============================================

# Collect and print BEFORE counters
collect_all_counters deepep_pods "before"
# print_all_counters deepep_pods "before"

# Now run the deepep low latency test
echo ""
echo "=============================================="
echo "Running DeepEP Low Latency Test"
echo "=============================================="
echo ""

# Run on leader pod (master) in background first
# Remove "sleep infinity" line on-the-fly before running
echo "[Leader] Starting on ${deepep_pods[0]}..."
kubectl exec -n "$NAMESPACE" "${deepep_pods[0]}" -- bash -c "sed '/sleep infinity/d' /root/run-test-ll.sh | bash" 2>&1 | sed 's/^/[Leader] /' &
LEADER_PID=$!

# Small delay to let leader/master start first
sleep 2

# Run on worker pod in foreground
echo "[Worker] Starting on ${deepep_pods[1]}..."
kubectl exec -n "$NAMESPACE" "${deepep_pods[1]}" -- bash -c "sed '/sleep infinity/d' /root/run-test-ll.sh | bash" 2>&1 | sed 's/^/[Worker] /'

# Wait for leader to complete
echo ""
echo "Waiting for leader to complete..."
wait $LEADER_PID

echo ""
echo "=============================================="
echo "DeepEP Low Latency Test Completed"
echo "=============================================="

# Collect and print AFTER counters
collect_all_counters deepep_pods "after"
# print_all_counters deepep_pods "after"

# Print counter differences
print_all_counter_diff deepep_pods

# Print summaries
print_all_summaries deepep_pods
# print_final_notes
