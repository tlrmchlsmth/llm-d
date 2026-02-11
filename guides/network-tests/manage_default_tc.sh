#!/bin/bash

usage() {
    echo "Usage: $0 set | reset"
    echo "  set   - set default RDMA traffic class to DEFAULT_RDMA_GLOBAL_TC on all HCAs"
    echo "  reset - clear default traffic class (-1) on all HCAs"
    exit 1
}

[[ $# -lt 1 || ! "$1" =~ ^(set|reset)$ ]] && usage
ACTION="$1"

# pods_namespace="varun-llm-d-wide-ep"
# pod_of_interest=(
#     "wide-ep-llm-d-prefill-0"
#     "wide-ep-llm-d-prefill-0-1"
# )

# pod_of_interest=(
#     "wide-ep-llm-d-decode-0"
#     "wide-ep-llm-d-decode-0-1"
# )



pods_namespace="raj-network-debug"
pod_of_interest=(
    "networking-debug-pod-10.0.65.77"
    "networking-debug-pod-10.0.66.42"
    "networking-debug-pod-10.0.67.106"
    "networking-debug-pod-10.0.69.254"
    "networking-debug-pod-10.0.73.241"
    "networking-debug-pod-10.0.73.3"
    "networking-debug-pod-10.0.74.185"
    "networking-debug-pod-10.0.76.69"
    "networking-debug-pod-10.0.78.230"
)



HCA_LIST="mlx5_0,mlx5_2,mlx5_3,mlx5_4,mlx5_5,mlx5_7,mlx5_8,mlx5_9"
DEFAULT_RDMA_GLOBAL_TC=41

# Build HCA array from comma-separated list
IFS=',' read -ra hcas <<< "$HCA_LIST"

echo "checking for pods in \"$pods_namespace\":"
for pod_name in "${pod_of_interest[@]}"; do
    echo -n "  $pod_name.. "
    kubectl get pod "$pod_name" -n "$pods_namespace" -o name &>/dev/null && echo "✓" || echo "✗ (not found)"
done

if [[ "$ACTION" == "set" ]]; then
    echo "Setting traffic_class=$DEFAULT_RDMA_GLOBAL_TC on all HCAs in each pod.."
    for pod_name in "${pod_of_interest[@]}"; do
        if ! kubectl get pod "$pod_name" -n "$pods_namespace" -o name &>/dev/null; then
            echo "  Skipping $pod_name (not found)"
            continue
        fi
        echo "  $pod_name:"
        kubectl exec -n "$pods_namespace" "$pod_name" -- bash -c "for hca in ${hcas[*]}; do echo $DEFAULT_RDMA_GLOBAL_TC > /sys/class/infiniband/\$hca/tc/1/traffic_class 2>/dev/null && { v=\$(cat /sys/class/infiniband/\$hca/tc/1/traffic_class 2>/dev/null); echo \"    \$hca: set -> \${v:-(blank)}\"; } || echo \"    \$hca: failed\"; done"
    done
else
    echo "Resetting traffic_class to -1 on all HCAs in each pod.."
    for pod_name in "${pod_of_interest[@]}"; do
        if ! kubectl get pod "$pod_name" -n "$pods_namespace" -o name &>/dev/null; then
            echo "  Skipping $pod_name (not found)"
            continue
        fi
        echo "  $pod_name:"
        kubectl exec -n "$pods_namespace" "$pod_name" -- bash -c "for hca in ${hcas[*]}; do echo -1 > /sys/class/infiniband/\$hca/tc/1/traffic_class 2>/dev/null && { v=\$(cat /sys/class/infiniband/\$hca/tc/1/traffic_class 2>/dev/null); echo \"    \$hca: reset -> \${v:-(blank)}\"; } || echo \"    \$hca: failed\"; done"
    done
fi

