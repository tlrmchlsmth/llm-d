# NIC Counter Utils Usage Guide

This guide shows how to use `nic_counter_utils.sh` to track NIC counters before and after running a test.

## Prerequisites

1. **Networking debug pods** must be deployed in a namespace (e.g., `kube-system` or dedicated namespace)
2. Debug pods must be named `networking-debug-pod-<node_name>` where `<node_name>` matches the Kubernetes node name
3. Set the `NET_DEBUG_NS` environment variable to the namespace where debug pods are deployed

## Basic Usage Template

```bash
#!/bin/bash

# Source the NIC counter utilities
source "$(dirname "$0")/nic_counter_utils.sh"

# Define the pods you want to monitor
# These are YOUR APPLICATION pods (not the networking-debug-pods)
pods_of_interest=(
    "my-app-pod-0"
    "my-app-pod-1"
)

# Namespace where your application pods are running
pods_namespace="my-app-namespace"

# Initialize the utility (discovers nodes and maps to networking-debug-pods)
init_nic_counter_utils pods_of_interest "$pods_namespace" || exit 1

# Collect counters BEFORE the test
collect_all_counters pods_of_interest "before"

# ============================================
# Run your test here
# ============================================
echo ""
echo "=============================================="
echo "Running My Test"
echo "=============================================="
echo ""

# Example: run your test command
# ./my_test_script.sh --some-args

# ============================================
# End of test
# ============================================

# Collect counters AFTER the test
collect_all_counters pods_of_interest "after"

# Print the counter differences (per-NIC breakdown)
print_all_counter_diff pods_of_interest

# Print the summaries (aggregated per-pod totals)
print_all_summaries pods_of_interest
```

## Running the Script

```bash
# Set the namespace where networking-debug-pods are deployed
export NET_DEBUG_NS=kube-system

# Run your test script
./my_test_script.sh
```

## Available Functions

| Function | Description |
|----------|-------------|
| `init_nic_counter_utils <pods_array> <namespace>` | Initialize utility, discover nodes, verify debug pods |
| `collect_all_counters <pods_array> "before\|after"` | Collect all NIC, PFC, and ECN counters |
| `print_all_counters <pods_array> "before\|after"` | Print raw counter values (optional) |
| `print_all_counter_diff <pods_array>` | Print per-NIC counter differences |
| `print_all_summaries <pods_array>` | Print aggregated summary tables |
| `print_final_notes` | Print explanatory notes about counters |

## Counters Tracked

### Packet Counters
- **RX Packets**: `rx_prio0_packets`, `rx_prio1_packets`, `rx_prio5_packets`, `rx_packets_phy`
- **TX Packets**: `tx_prio0_packets`, `tx_prio1_packets`, `tx_prio5_packets`, `tx_packets_phy`
- **RX Discards**: `rx_prio0_buf_discard`, `rx_prio1_buf_discard`, `rx_prio5_buf_discard`

### PFC Counters (Priorities 0 and 5)
- **Pause Counts**: `tx_prio0_pause`, `rx_prio0_pause`, `tx_prio5_pause`, `rx_prio5_pause`
- **Pause Durations**: `tx_prio0_pause_duration`, `rx_prio0_pause_duration`, `tx_prio5_pause_duration`, `rx_prio5_pause_duration`

### ECN Counters
- `np_ecn_marked_roce_packets` - Packets marked with ECN by the network
- `np_cnp_sent` - Congestion Notification Packets sent
- `rp_cnp_handled` - CNPs handled (received and processed)

## Output Structure

The output is organized into three main sections:

1. **Packet Counters** - Sub-tables: RX Packets, TX Packets, RX Discards
2. **PFC Counters** - Sub-tables: Pause Counts, Pause Durations
3. **ECN Counters** - Single table (no sub-sections)

Each section shows per-pod totals with a TOTAL row at the bottom.
