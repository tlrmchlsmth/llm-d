#!/bin/bash

source "/home/rajjoshi/workspace/llm-d/guides/network-tests/nic_counter_utils.sh"

pods_of_interest=(
    "networking-debug-pod-10.0.65.77"
    "networking-debug-pod-10.0.66.42"
)

pods_namespace="raj-network-debug" 

init_nic_counter_utils pods_of_interest "$pods_namespace" || exit 1 

collect_all_counters pods_of_interest "before"


# Now run the GDR test
echo ""
echo "=============================================="
echo "Running GDR Test"
echo "=============================================="
echo ""

script_to_run="/home/rajjoshi/workspace/networking-debug-container/inter_node_tests/single_nic_ib_write_bw/single_nic_ib_write_bw.sh" 

$script_to_run --namespace raj-network-debug --src networking-debug-pod-10.0.65.77:mlx5_3:rocm:2 --dst networking-debug-pod-10.0.66.42:mlx5_9:rocm:7 --msg-size 1048576 --tos 41

collect_all_counters pods_of_interest "after"


# print the counter differences
print_all_counter_diff pods_of_interest

# print the summaries
print_all_summaries pods_of_interest

