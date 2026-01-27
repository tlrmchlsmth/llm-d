#!/bin/bash

# Usage: ./test_rx_prior1_buf_discards-wide_ep.sh <namespace>
# Example: ./test_rx_prior1_buf_discards-wide_ep.sh llm-d
#
# This script automatically discovers nodes running wide-ep-llm-d-decode* and 
# wide-ep-llm-d-prefill* pods in the given namespace.
# Tracks RX counters for priorities 0, 1, and 5, plus ECN and PFC pause counters.

if [ $# -lt 1 ]; then
    echo "Usage: $0 <namespace>"
    echo "Example: $0 llm-d"
    exit 1
fi

NAMESPACE=$1

echo ""
echo "=============================================="
echo "Discovering Wide-EP Pods in namespace: $NAMESPACE"
echo "=============================================="

# Find all wide-ep decode and prefill pods and get their node names
decode_pods=$(kubectl get pods -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}' | grep "^wide-ep-llm-d-decode")
prefill_pods=$(kubectl get pods -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeName}{"\n"}{end}' | grep "^wide-ep-llm-d-prefill")

# Print discovered pods
echo ""
echo "Discovered Decode Pods:"
echo "$decode_pods"
echo ""
echo "Discovered Prefill Pods:"
echo "$prefill_pods"

# Combine all pods and store pod names, node names
all_pods="$decode_pods
$prefill_pods"

# Arrays to store pod info
pod_names=()
node_names=()
networking_debug_pods=()

# Read each line and extract pod name and node name
while IFS= read -r line; do
    [ -z "$line" ] && continue
    pod_name=$(echo "$line" | awk '{print $1}')
    node_name=$(echo "$line" | awk '{print $2}')
    pod_names+=("$pod_name")
    node_names+=("$node_name")
    networking_debug_pods+=("networking-debug-pod-$node_name")
done <<< "$all_pods"

if [ ${#pod_names[@]} -eq 0 ]; then
    echo "ERROR: No wide-ep-llm-d-decode* or wide-ep-llm-d-prefill* pods found in namespace $NAMESPACE"
    exit 1
fi

# Print table showing pod names, node names and networking debug pod names
echo ""
printf "%-35s %-18s %-40s\n" "POD NAME" "NODE NAME" "NETWORKING DEBUG POD"
printf "%-35s %-18s %-40s\n" "-----------------------------------" "------------------" "----------------------------------------"
for i in "${!pod_names[@]}"; do
    printf "%-35s %-18s %-40s\n" "${pod_names[$i]}" "${node_names[$i]}" "${networking_debug_pods[$i]}"
done

# ============================================
# Arrays for priority packet/discard counters
# ============================================
before_prio0_packets=()
before_prio0_discards=()
before_prio1_packets=()
before_prio1_discards=()
before_prio5_packets=()
before_prio5_discards=()
before_phy_packets=()
before_rdma_unicast=()

after_prio0_packets=()
after_prio0_discards=()
after_prio1_packets=()
after_prio1_discards=()
after_prio5_packets=()
after_prio5_discards=()
after_phy_packets=()
after_rdma_unicast=()

# ============================================
# Arrays for PFC pause counters (prio0 and prio5)
# ============================================
before_tx_prio0_pause=()
before_rx_prio0_pause=()
before_tx_prio5_pause=()
before_rx_prio5_pause=()
before_tx_prio0_pause_duration=()
before_rx_prio0_pause_duration=()
before_tx_prio5_pause_duration=()
before_rx_prio5_pause_duration=()

after_tx_prio0_pause=()
after_rx_prio0_pause=()
after_tx_prio5_pause=()
after_rx_prio5_pause=()
after_tx_prio0_pause_duration=()
after_rx_prio0_pause_duration=()
after_tx_prio5_pause_duration=()
after_rx_prio5_pause_duration=()

# ============================================
# Arrays for ECN counters (per pod, summed across NICs)
# ============================================
before_ecn_marked=()
before_cnp_sent=()
before_cnp_handled=()

after_ecn_marked=()
after_cnp_sent=()
after_cnp_handled=()

# Maximum retries for fetching NIC counters
MAX_RETRIES=3
RETRY_DELAY=2

# Function to fetch ethtool stats with retry logic
fetch_ethtool_stats() {
    local pod=$1
    local nic=$2
    local retry=0
    local stats=""
    
    while [ $retry -lt $MAX_RETRIES ]; do
        stats=$(kubectl exec -n "$NAMESPACE" "$pod" -- ethtool -S "$nic" 2>/dev/null)
        
        if echo "$stats" | grep -q "rx_prio0_packets:"; then
            echo "$stats"
            return 0
        fi
        
        retry=$((retry + 1))
        if [ $retry -lt $MAX_RETRIES ]; then
            echo "  [WARN] Failed to get stats for $nic on $pod, retrying ($retry/$MAX_RETRIES)..." >&2
            sleep $RETRY_DELAY
        fi
    done
    
    echo "  [ERROR] Failed to get stats for $nic on $pod after $MAX_RETRIES attempts" >&2
    echo ""
    return 1
}

# Function to collect NIC counters into arrays
collect_nic_counters() {
    local pod=$1
    local pod_idx=$2
    local prefix=$3
    
    echo "  Collecting from $pod..."
    
    for nic_idx in $(seq 0 7); do
        local array_idx=$((pod_idx * 8 + nic_idx))
        local stats=$(fetch_ethtool_stats "$pod" "rdma${nic_idx}")
        
        if [ -z "$stats" ]; then
            echo "  [ERROR] No stats retrieved for rdma${nic_idx} on $pod - using -1 marker"
            if [ "$prefix" == "before" ]; then
                before_prio0_packets[$array_idx]=-1
                before_prio0_discards[$array_idx]=-1
                before_prio1_packets[$array_idx]=-1
                before_prio1_discards[$array_idx]=-1
                before_prio5_packets[$array_idx]=-1
                before_prio5_discards[$array_idx]=-1
                before_phy_packets[$array_idx]=-1
                before_rdma_unicast[$array_idx]=-1
                before_tx_prio0_pause[$array_idx]=-1
                before_rx_prio0_pause[$array_idx]=-1
                before_tx_prio5_pause[$array_idx]=-1
                before_rx_prio5_pause[$array_idx]=-1
                before_tx_prio0_pause_duration[$array_idx]=-1
                before_rx_prio0_pause_duration[$array_idx]=-1
                before_tx_prio5_pause_duration[$array_idx]=-1
                before_rx_prio5_pause_duration[$array_idx]=-1
            else
                after_prio0_packets[$array_idx]=-1
                after_prio0_discards[$array_idx]=-1
                after_prio1_packets[$array_idx]=-1
                after_prio1_discards[$array_idx]=-1
                after_prio5_packets[$array_idx]=-1
                after_prio5_discards[$array_idx]=-1
                after_phy_packets[$array_idx]=-1
                after_rdma_unicast[$array_idx]=-1
                after_tx_prio0_pause[$array_idx]=-1
                after_rx_prio0_pause[$array_idx]=-1
                after_tx_prio5_pause[$array_idx]=-1
                after_rx_prio5_pause[$array_idx]=-1
                after_tx_prio0_pause_duration[$array_idx]=-1
                after_rx_prio0_pause_duration[$array_idx]=-1
                after_tx_prio5_pause_duration[$array_idx]=-1
                after_rx_prio5_pause_duration[$array_idx]=-1
            fi
            continue
        fi
        
        # Parse priority packet/discard counters
        local prio0_packets=$(echo "$stats" | grep -E "^\s*rx_prio0_packets:" | awk '{print $2}')
        local prio0_discards=$(echo "$stats" | grep -E "^\s*rx_prio0_buf_discard:" | awk '{print $2}')
        local prio1_packets=$(echo "$stats" | grep -E "^\s*rx_prio1_packets:" | awk '{print $2}')
        local prio1_discards=$(echo "$stats" | grep -E "^\s*rx_prio1_buf_discard:" | awk '{print $2}')
        local prio5_packets=$(echo "$stats" | grep -E "^\s*rx_prio5_packets:" | awk '{print $2}')
        local prio5_discards=$(echo "$stats" | grep -E "^\s*rx_prio5_buf_discard:" | awk '{print $2}')
        local phy_packets=$(echo "$stats" | grep -E "^\s*rx_packets_phy:" | awk '{print $2}')
        local rdma_unicast=$(echo "$stats" | grep -E "^\s*rx_vport_rdma_unicast_packets:" | awk '{print $2}')
        
        # Parse PFC pause counters
        local tx_prio0_pause=$(echo "$stats" | grep -E "^\s*tx_prio0_pause:" | awk '{print $2}')
        local rx_prio0_pause=$(echo "$stats" | grep -E "^\s*rx_prio0_pause:" | awk '{print $2}')
        local tx_prio5_pause=$(echo "$stats" | grep -E "^\s*tx_prio5_pause:" | awk '{print $2}')
        local rx_prio5_pause=$(echo "$stats" | grep -E "^\s*rx_prio5_pause:" | awk '{print $2}')
        
        # Parse PFC pause duration counters
        local tx_prio0_pause_duration=$(echo "$stats" | grep -E "^\s*tx_prio0_pause_duration:" | awk '{print $2}')
        local rx_prio0_pause_duration=$(echo "$stats" | grep -E "^\s*rx_prio0_pause_duration:" | awk '{print $2}')
        local tx_prio5_pause_duration=$(echo "$stats" | grep -E "^\s*tx_prio5_pause_duration:" | awk '{print $2}')
        local rx_prio5_pause_duration=$(echo "$stats" | grep -E "^\s*rx_prio5_pause_duration:" | awk '{print $2}')
        
        if [ "$prefix" == "before" ]; then
            before_prio0_packets[$array_idx]=${prio0_packets:-0}
            before_prio0_discards[$array_idx]=${prio0_discards:-0}
            before_prio1_packets[$array_idx]=${prio1_packets:-0}
            before_prio1_discards[$array_idx]=${prio1_discards:-0}
            before_prio5_packets[$array_idx]=${prio5_packets:-0}
            before_prio5_discards[$array_idx]=${prio5_discards:-0}
            before_phy_packets[$array_idx]=${phy_packets:-0}
            before_rdma_unicast[$array_idx]=${rdma_unicast:-0}
            before_tx_prio0_pause[$array_idx]=${tx_prio0_pause:-0}
            before_rx_prio0_pause[$array_idx]=${rx_prio0_pause:-0}
            before_tx_prio5_pause[$array_idx]=${tx_prio5_pause:-0}
            before_rx_prio5_pause[$array_idx]=${rx_prio5_pause:-0}
            before_tx_prio0_pause_duration[$array_idx]=${tx_prio0_pause_duration:-0}
            before_rx_prio0_pause_duration[$array_idx]=${rx_prio0_pause_duration:-0}
            before_tx_prio5_pause_duration[$array_idx]=${tx_prio5_pause_duration:-0}
            before_rx_prio5_pause_duration[$array_idx]=${rx_prio5_pause_duration:-0}
        else
            after_prio0_packets[$array_idx]=${prio0_packets:-0}
            after_prio0_discards[$array_idx]=${prio0_discards:-0}
            after_prio1_packets[$array_idx]=${prio1_packets:-0}
            after_prio1_discards[$array_idx]=${prio1_discards:-0}
            after_prio5_packets[$array_idx]=${prio5_packets:-0}
            after_prio5_discards[$array_idx]=${prio5_discards:-0}
            after_phy_packets[$array_idx]=${phy_packets:-0}
            after_rdma_unicast[$array_idx]=${rdma_unicast:-0}
            after_tx_prio0_pause[$array_idx]=${tx_prio0_pause:-0}
            after_rx_prio0_pause[$array_idx]=${rx_prio0_pause:-0}
            after_tx_prio5_pause[$array_idx]=${tx_prio5_pause:-0}
            after_rx_prio5_pause[$array_idx]=${rx_prio5_pause:-0}
            after_tx_prio0_pause_duration[$array_idx]=${tx_prio0_pause_duration:-0}
            after_rx_prio0_pause_duration[$array_idx]=${rx_prio0_pause_duration:-0}
            after_tx_prio5_pause_duration[$array_idx]=${tx_prio5_pause_duration:-0}
            after_rx_prio5_pause_duration[$array_idx]=${rx_prio5_pause_duration:-0}
        fi
    done
}

# Function to collect ECN hardware counters (summed across all mlx5 devices)
collect_ecn_counters() {
    local pod=$1
    local pod_idx=$2
    local prefix=$3
    
    # Sum ECN counters across all mlx5 devices
    local total_ecn_marked=0
    local total_cnp_sent=0
    local total_cnp_handled=0
    
    local ecn_data=$(kubectl exec -n "$NAMESPACE" "$pod" -- bash -c '
        for dev in /sys/class/infiniband/mlx5_*; do
            if [ -d "$dev/ports/1/hw_counters" ]; then
                ecn=$(cat "$dev/ports/1/hw_counters/np_ecn_marked_roce_packets" 2>/dev/null || echo 0)
                cnp_sent=$(cat "$dev/ports/1/hw_counters/np_cnp_sent" 2>/dev/null || echo 0)
                cnp_handled=$(cat "$dev/ports/1/hw_counters/rp_cnp_handled" 2>/dev/null || echo 0)
                echo "$ecn $cnp_sent $cnp_handled"
            fi
        done
    ' 2>/dev/null)
    
    while read -r ecn cnp_sent cnp_handled; do
        [ -z "$ecn" ] && continue
        total_ecn_marked=$((total_ecn_marked + ecn))
        total_cnp_sent=$((total_cnp_sent + cnp_sent))
        total_cnp_handled=$((total_cnp_handled + cnp_handled))
    done <<< "$ecn_data"
    
    if [ "$prefix" == "before" ]; then
        before_ecn_marked[$pod_idx]=$total_ecn_marked
        before_cnp_sent[$pod_idx]=$total_cnp_sent
        before_cnp_handled[$pod_idx]=$total_cnp_handled
    else
        after_ecn_marked[$pod_idx]=$total_ecn_marked
        after_cnp_sent[$pod_idx]=$total_cnp_sent
        after_cnp_handled[$pod_idx]=$total_cnp_handled
    fi
}

# Function to format counter value (show FAILED for -1)
format_counter() {
    local val=$1
    if [ "$val" == "-1" ]; then
        echo "FAILED"
    else
        echo "$val"
    fi
}

# Function to print NIC counters table (priority packets/discards)
print_nic_counters() {
    local pod=$1
    local node=$2
    local pod_idx=$3
    local prefix=$4
    
    echo ""
    echo "=================================================================================================================================="
    echo "NIC Counters ($prefix) for: $pod (Node: $node)"
    echo "=================================================================================================================================="
    printf "%-8s %-12s %-12s %-12s %-12s %-12s %-12s %-14s %-14s\n" \
           "NIC" "p0_pkts" "p0_disc" "p1_pkts" "p1_disc" "p5_pkts" "p5_disc" "phy_pkts" "rdma_uni"
    printf "%-8s %-12s %-12s %-12s %-12s %-12s %-12s %-14s %-14s\n" \
           "--------" "------------" "------------" "------------" "------------" "------------" "------------" "--------------" "--------------"
    
    for nic_idx in $(seq 0 7); do
        local array_idx=$((pod_idx * 8 + nic_idx))
        if [ "$prefix" == "BEFORE" ]; then
            printf "%-8s %-12s %-12s %-12s %-12s %-12s %-12s %-14s %-14s\n" \
                   "rdma${nic_idx}" \
                   "$(format_counter "${before_prio0_packets[$array_idx]}")" "$(format_counter "${before_prio0_discards[$array_idx]}")" \
                   "$(format_counter "${before_prio1_packets[$array_idx]}")" "$(format_counter "${before_prio1_discards[$array_idx]}")" \
                   "$(format_counter "${before_prio5_packets[$array_idx]}")" "$(format_counter "${before_prio5_discards[$array_idx]}")" \
                   "$(format_counter "${before_phy_packets[$array_idx]}")" "$(format_counter "${before_rdma_unicast[$array_idx]}")"
        else
            printf "%-8s %-12s %-12s %-12s %-12s %-12s %-12s %-14s %-14s\n" \
                   "rdma${nic_idx}" \
                   "$(format_counter "${after_prio0_packets[$array_idx]}")" "$(format_counter "${after_prio0_discards[$array_idx]}")" \
                   "$(format_counter "${after_prio1_packets[$array_idx]}")" "$(format_counter "${after_prio1_discards[$array_idx]}")" \
                   "$(format_counter "${after_prio5_packets[$array_idx]}")" "$(format_counter "${after_prio5_discards[$array_idx]}")" \
                   "$(format_counter "${after_phy_packets[$array_idx]}")" "$(format_counter "${after_rdma_unicast[$array_idx]}")"
        fi
    done
}

# Function to print PFC pause counters table
print_pfc_counters() {
    local pod=$1
    local node=$2
    local pod_idx=$3
    local prefix=$4
    
    echo ""
    echo "PFC Pause Counters ($prefix) - Priorities 0 and 5:"
    printf "%-8s %-12s %-12s %-12s %-12s %-14s %-14s %-14s %-14s\n" \
           "NIC" "tx_p0_paus" "rx_p0_paus" "tx_p5_paus" "rx_p5_paus" "tx_p0_dur" "rx_p0_dur" "tx_p5_dur" "rx_p5_dur"
    printf "%-8s %-12s %-12s %-12s %-12s %-14s %-14s %-14s %-14s\n" \
           "--------" "------------" "------------" "------------" "------------" "--------------" "--------------" "--------------" "--------------"
    
    for nic_idx in $(seq 0 7); do
        local array_idx=$((pod_idx * 8 + nic_idx))
        if [ "$prefix" == "BEFORE" ]; then
            printf "%-8s %-12s %-12s %-12s %-12s %-14s %-14s %-14s %-14s\n" \
                   "rdma${nic_idx}" \
                   "$(format_counter "${before_tx_prio0_pause[$array_idx]}")" "$(format_counter "${before_rx_prio0_pause[$array_idx]}")" \
                   "$(format_counter "${before_tx_prio5_pause[$array_idx]}")" "$(format_counter "${before_rx_prio5_pause[$array_idx]}")" \
                   "$(format_counter "${before_tx_prio0_pause_duration[$array_idx]}")" "$(format_counter "${before_rx_prio0_pause_duration[$array_idx]}")" \
                   "$(format_counter "${before_tx_prio5_pause_duration[$array_idx]}")" "$(format_counter "${before_rx_prio5_pause_duration[$array_idx]}")"
        else
            printf "%-8s %-12s %-12s %-12s %-12s %-14s %-14s %-14s %-14s\n" \
                   "rdma${nic_idx}" \
                   "$(format_counter "${after_tx_prio0_pause[$array_idx]}")" "$(format_counter "${after_rx_prio0_pause[$array_idx]}")" \
                   "$(format_counter "${after_tx_prio5_pause[$array_idx]}")" "$(format_counter "${after_rx_prio5_pause[$array_idx]}")" \
                   "$(format_counter "${after_tx_prio0_pause_duration[$array_idx]}")" "$(format_counter "${after_rx_prio0_pause_duration[$array_idx]}")" \
                   "$(format_counter "${after_tx_prio5_pause_duration[$array_idx]}")" "$(format_counter "${after_rx_prio5_pause_duration[$array_idx]}")"
        fi
    done
}

# Function to print NIC counter differences
print_nic_counter_diff() {
    local pod=$1
    local node=$2
    local pod_idx=$3
    
    echo ""
    echo "=================================================================================================================================="
    echo "NIC Counter DIFFERENCE for: $pod (Node: $node)"
    echo "=================================================================================================================================="
    printf "%-8s %-12s %-12s %-12s %-12s %-12s %-12s %-14s %-14s\n" \
           "NIC" "p0_pkts" "p0_disc" "p1_pkts" "p1_disc" "p5_pkts" "p5_disc" "phy_pkts" "rdma_uni"
    printf "%-8s %-12s %-12s %-12s %-12s %-12s %-12s %-14s %-14s\n" \
           "--------" "------------" "------------" "------------" "------------" "------------" "------------" "--------------" "--------------"
    
    for nic_idx in $(seq 0 7); do
        local array_idx=$((pod_idx * 8 + nic_idx))
        
        if [ "${before_prio0_packets[$array_idx]}" == "-1" ] || [ "${after_prio0_packets[$array_idx]}" == "-1" ]; then
            printf "%-8s %-12s %-12s %-12s %-12s %-12s %-12s %-14s %-14s\n" \
                   "rdma${nic_idx}" "SKIPPED" "SKIPPED" "SKIPPED" "SKIPPED" "SKIPPED" "SKIPPED" "SKIPPED" "SKIPPED"
            continue
        fi
        
        local prio0_diff=$((${after_prio0_packets[$array_idx]:-0} - ${before_prio0_packets[$array_idx]:-0}))
        local prio0_disc_diff=$((${after_prio0_discards[$array_idx]:-0} - ${before_prio0_discards[$array_idx]:-0}))
        local prio1_diff=$((${after_prio1_packets[$array_idx]:-0} - ${before_prio1_packets[$array_idx]:-0}))
        local prio1_disc_diff=$((${after_prio1_discards[$array_idx]:-0} - ${before_prio1_discards[$array_idx]:-0}))
        local prio5_diff=$((${after_prio5_packets[$array_idx]:-0} - ${before_prio5_packets[$array_idx]:-0}))
        local prio5_disc_diff=$((${after_prio5_discards[$array_idx]:-0} - ${before_prio5_discards[$array_idx]:-0}))
        local phy_diff=$((${after_phy_packets[$array_idx]:-0} - ${before_phy_packets[$array_idx]:-0}))
        local rdma_diff=$((${after_rdma_unicast[$array_idx]:-0} - ${before_rdma_unicast[$array_idx]:-0}))
        printf "%-8s %-12s %-12s %-12s %-12s %-12s %-12s %-14s %-14s\n" \
               "rdma${nic_idx}" "$prio0_diff" "$prio0_disc_diff" "$prio1_diff" "$prio1_disc_diff" "$prio5_diff" "$prio5_disc_diff" "$phy_diff" "$rdma_diff"
    done
}

# Function to print PFC pause counter differences
print_pfc_counter_diff() {
    local pod=$1
    local node=$2
    local pod_idx=$3
    
    echo ""
    echo "PFC Pause Counter DIFFERENCE - Priorities 0 and 5:"
    printf "%-8s %-12s %-12s %-12s %-12s %-14s %-14s %-14s %-14s\n" \
           "NIC" "tx_p0_paus" "rx_p0_paus" "tx_p5_paus" "rx_p5_paus" "tx_p0_dur" "rx_p0_dur" "tx_p5_dur" "rx_p5_dur"
    printf "%-8s %-12s %-12s %-12s %-12s %-14s %-14s %-14s %-14s\n" \
           "--------" "------------" "------------" "------------" "------------" "--------------" "--------------" "--------------" "--------------"
    
    for nic_idx in $(seq 0 7); do
        local array_idx=$((pod_idx * 8 + nic_idx))
        
        if [ "${before_tx_prio0_pause[$array_idx]}" == "-1" ] || [ "${after_tx_prio0_pause[$array_idx]}" == "-1" ]; then
            printf "%-8s %-12s %-12s %-12s %-12s %-14s %-14s %-14s %-14s\n" \
                   "rdma${nic_idx}" "SKIPPED" "SKIPPED" "SKIPPED" "SKIPPED" "SKIPPED" "SKIPPED" "SKIPPED" "SKIPPED"
            continue
        fi
        
        local tx_p0_diff=$((${after_tx_prio0_pause[$array_idx]:-0} - ${before_tx_prio0_pause[$array_idx]:-0}))
        local rx_p0_diff=$((${after_rx_prio0_pause[$array_idx]:-0} - ${before_rx_prio0_pause[$array_idx]:-0}))
        local tx_p5_diff=$((${after_tx_prio5_pause[$array_idx]:-0} - ${before_tx_prio5_pause[$array_idx]:-0}))
        local rx_p5_diff=$((${after_rx_prio5_pause[$array_idx]:-0} - ${before_rx_prio5_pause[$array_idx]:-0}))
        local tx_p0_dur_diff=$((${after_tx_prio0_pause_duration[$array_idx]:-0} - ${before_tx_prio0_pause_duration[$array_idx]:-0}))
        local rx_p0_dur_diff=$((${after_rx_prio0_pause_duration[$array_idx]:-0} - ${before_rx_prio0_pause_duration[$array_idx]:-0}))
        local tx_p5_dur_diff=$((${after_tx_prio5_pause_duration[$array_idx]:-0} - ${before_tx_prio5_pause_duration[$array_idx]:-0}))
        local rx_p5_dur_diff=$((${after_rx_prio5_pause_duration[$array_idx]:-0} - ${before_rx_prio5_pause_duration[$array_idx]:-0}))
        printf "%-8s %-12s %-12s %-12s %-12s %-14s %-14s %-14s %-14s\n" \
               "rdma${nic_idx}" "$tx_p0_diff" "$rx_p0_diff" "$tx_p5_diff" "$rx_p5_diff" "$tx_p0_dur_diff" "$rx_p0_dur_diff" "$tx_p5_dur_diff" "$rx_p5_dur_diff"
    done
}

# ============================================
# MAIN SCRIPT EXECUTION
# ============================================

# Collect and print BEFORE counters
echo ""
echo "=============================================="
echo "Collecting NIC Counters BEFORE Test"
echo "=============================================="
for i in "${!networking_debug_pods[@]}"; do
    collect_nic_counters "${networking_debug_pods[$i]}" "$i" "before"
    collect_ecn_counters "${networking_debug_pods[$i]}" "$i" "before"
    print_nic_counters "${pod_names[$i]}" "${node_names[$i]}" "$i" "BEFORE"
    print_pfc_counters "${pod_names[$i]}" "${node_names[$i]}" "$i" "BEFORE"
done

# Print ECN counters before
echo ""
echo "=============================================="
echo "ECN Hardware Counters BEFORE Test"
echo "=============================================="
printf "%-35s %-18s %-18s %-18s\n" "POD" "ecn_marked" "cnp_sent" "cnp_handled"
printf "%-35s %-18s %-18s %-18s\n" "-----------------------------------" "------------------" "------------------" "------------------"
for i in "${!pod_names[@]}"; do
    printf "%-35s %-18s %-18s %-18s\n" "${pod_names[$i]}" "${before_ecn_marked[$i]}" "${before_cnp_sent[$i]}" "${before_cnp_handled[$i]}"
done

# Run the benchmark test via the poker pod
echo ""
echo "=============================================="
echo "Running Benchmark Test via Poker Pod"
echo "=============================================="
echo ""
echo "Running: just benchmark 4096 4096 256 128"
echo ""

kubectl exec -n "$NAMESPACE" poker -- /bin/zsh -c "cd /app && just benchmark 4096 4096 256 128" 2>&1

echo ""
echo "=============================================="
echo "Benchmark Test Completed"
echo "=============================================="

# Collect and print AFTER counters
echo ""
echo "=============================================="
echo "Collecting NIC Counters AFTER Test"
echo "=============================================="
for i in "${!networking_debug_pods[@]}"; do
    collect_nic_counters "${networking_debug_pods[$i]}" "$i" "after"
    collect_ecn_counters "${networking_debug_pods[$i]}" "$i" "after"
    print_nic_counters "${pod_names[$i]}" "${node_names[$i]}" "$i" "AFTER"
    print_pfc_counters "${pod_names[$i]}" "${node_names[$i]}" "$i" "AFTER"
done

# Print ECN counters after
echo ""
echo "=============================================="
echo "ECN Hardware Counters AFTER Test"
echo "=============================================="
printf "%-35s %-18s %-18s %-18s\n" "POD" "ecn_marked" "cnp_sent" "cnp_handled"
printf "%-35s %-18s %-18s %-18s\n" "-----------------------------------" "------------------" "------------------" "------------------"
for i in "${!pod_names[@]}"; do
    printf "%-35s %-18s %-18s %-18s\n" "${pod_names[$i]}" "${after_ecn_marked[$i]}" "${after_cnp_sent[$i]}" "${after_cnp_handled[$i]}"
done

# Print NIC counter differences
echo ""
echo "=============================================="
echo "NIC Counter DIFFERENCES (After - Before)"
echo "=============================================="
for i in "${!networking_debug_pods[@]}"; do
    print_nic_counter_diff "${pod_names[$i]}" "${node_names[$i]}" "$i"
    print_pfc_counter_diff "${pod_names[$i]}" "${node_names[$i]}" "$i"
done

# ============================================
# SUMMARY SECTION
# ============================================
echo ""
echo "=================================================================================================================================="
echo "SUMMARY: Priority Packet Counter Differences"
echo "=================================================================================================================================="
printf "%-30s %-11s %-11s %-11s %-11s %-11s %-11s %-13s %-13s\n" \
       "POD" "p0_pkts" "p0_disc" "p1_pkts" "p1_disc" "p5_pkts" "p5_disc" "phy_pkts" "rdma_uni"
printf "%-30s %-11s %-11s %-11s %-11s %-11s %-11s %-13s %-13s\n" \
       "------------------------------" "-----------" "-----------" "-----------" "-----------" "-----------" "-----------" "-------------" "-------------"

total_prio0_diff=0; total_prio0_disc_diff=0
total_prio1_diff=0; total_prio1_disc_diff=0
total_prio5_diff=0; total_prio5_disc_diff=0
total_phy_diff=0; total_rdma_diff=0
skipped_nics=0

for i in "${!pod_names[@]}"; do
    pod_prio0_diff=0; pod_prio0_disc_diff=0
    pod_prio1_diff=0; pod_prio1_disc_diff=0
    pod_prio5_diff=0; pod_prio5_disc_diff=0
    pod_phy_diff=0; pod_rdma_diff=0
    pod_skipped=0
    
    for nic_idx in $(seq 0 7); do
        array_idx=$((i * 8 + nic_idx))
        
        if [ "${before_prio0_packets[$array_idx]}" == "-1" ] || [ "${after_prio0_packets[$array_idx]}" == "-1" ]; then
            pod_skipped=$((pod_skipped + 1))
            skipped_nics=$((skipped_nics + 1))
            continue
        fi
        
        prio0_diff=$((${after_prio0_packets[$array_idx]:-0} - ${before_prio0_packets[$array_idx]:-0}))
        prio0_disc_diff=$((${after_prio0_discards[$array_idx]:-0} - ${before_prio0_discards[$array_idx]:-0}))
        prio1_diff=$((${after_prio1_packets[$array_idx]:-0} - ${before_prio1_packets[$array_idx]:-0}))
        prio1_disc_diff=$((${after_prio1_discards[$array_idx]:-0} - ${before_prio1_discards[$array_idx]:-0}))
        prio5_diff=$((${after_prio5_packets[$array_idx]:-0} - ${before_prio5_packets[$array_idx]:-0}))
        prio5_disc_diff=$((${after_prio5_discards[$array_idx]:-0} - ${before_prio5_discards[$array_idx]:-0}))
        phy_diff=$((${after_phy_packets[$array_idx]:-0} - ${before_phy_packets[$array_idx]:-0}))
        rdma_diff=$((${after_rdma_unicast[$array_idx]:-0} - ${before_rdma_unicast[$array_idx]:-0}))
        
        pod_prio0_diff=$((pod_prio0_diff + prio0_diff))
        pod_prio0_disc_diff=$((pod_prio0_disc_diff + prio0_disc_diff))
        pod_prio1_diff=$((pod_prio1_diff + prio1_diff))
        pod_prio1_disc_diff=$((pod_prio1_disc_diff + prio1_disc_diff))
        pod_prio5_diff=$((pod_prio5_diff + prio5_diff))
        pod_prio5_disc_diff=$((pod_prio5_disc_diff + prio5_disc_diff))
        pod_phy_diff=$((pod_phy_diff + phy_diff))
        pod_rdma_diff=$((pod_rdma_diff + rdma_diff))
    done
    
    total_prio0_diff=$((total_prio0_diff + pod_prio0_diff))
    total_prio0_disc_diff=$((total_prio0_disc_diff + pod_prio0_disc_diff))
    total_prio1_diff=$((total_prio1_diff + pod_prio1_diff))
    total_prio1_disc_diff=$((total_prio1_disc_diff + pod_prio1_disc_diff))
    total_prio5_diff=$((total_prio5_diff + pod_prio5_diff))
    total_prio5_disc_diff=$((total_prio5_disc_diff + pod_prio5_disc_diff))
    total_phy_diff=$((total_phy_diff + pod_phy_diff))
    total_rdma_diff=$((total_rdma_diff + pod_rdma_diff))
    
    if [ $pod_skipped -gt 0 ]; then
        printf "%-30s %-11d %-11d %-11d %-11d %-11d %-11d %-13d %-13d (%d skip)\n" \
               "${pod_names[$i]}" "$pod_prio0_diff" "$pod_prio0_disc_diff" "$pod_prio1_diff" "$pod_prio1_disc_diff" "$pod_prio5_diff" "$pod_prio5_disc_diff" "$pod_phy_diff" "$pod_rdma_diff" "$pod_skipped"
    else
        printf "%-30s %-11d %-11d %-11d %-11d %-11d %-11d %-13d %-13d\n" \
               "${pod_names[$i]}" "$pod_prio0_diff" "$pod_prio0_disc_diff" "$pod_prio1_diff" "$pod_prio1_disc_diff" "$pod_prio5_diff" "$pod_prio5_disc_diff" "$pod_phy_diff" "$pod_rdma_diff"
    fi
done

printf "%-30s %-11s %-11s %-11s %-11s %-11s %-11s %-13s %-13s\n" \
       "------------------------------" "-----------" "-----------" "-----------" "-----------" "-----------" "-----------" "-------------" "-------------"
printf "%-30s %-11d %-11d %-11d %-11d %-11d %-11d %-13d %-13d\n" \
       "TOTAL" "$total_prio0_diff" "$total_prio0_disc_diff" "$total_prio1_diff" "$total_prio1_disc_diff" "$total_prio5_diff" "$total_prio5_disc_diff" "$total_phy_diff" "$total_rdma_diff"

# PFC Pause Summary
echo ""
echo "=================================================================================================================================="
echo "SUMMARY: PFC Pause Counter Differences (Priorities 0 and 5)"
echo "=================================================================================================================================="
printf "%-25s %-10s %-10s %-10s %-10s %-12s %-12s %-12s %-12s\n" \
       "POD" "tx_p0" "rx_p0" "tx_p5" "rx_p5" "tx_p0_dur" "rx_p0_dur" "tx_p5_dur" "rx_p5_dur"
printf "%-25s %-10s %-10s %-10s %-10s %-12s %-12s %-12s %-12s\n" \
       "-------------------------" "----------" "----------" "----------" "----------" "------------" "------------" "------------" "------------"

total_tx_p0=0; total_rx_p0=0; total_tx_p5=0; total_rx_p5=0
total_tx_p0_dur=0; total_rx_p0_dur=0; total_tx_p5_dur=0; total_rx_p5_dur=0

for i in "${!pod_names[@]}"; do
    pod_tx_p0=0; pod_rx_p0=0; pod_tx_p5=0; pod_rx_p5=0
    pod_tx_p0_dur=0; pod_rx_p0_dur=0; pod_tx_p5_dur=0; pod_rx_p5_dur=0
    
    for nic_idx in $(seq 0 7); do
        array_idx=$((i * 8 + nic_idx))
        
        if [ "${before_tx_prio0_pause[$array_idx]}" == "-1" ] || [ "${after_tx_prio0_pause[$array_idx]}" == "-1" ]; then
            continue
        fi
        
        tx_p0_diff=$((${after_tx_prio0_pause[$array_idx]:-0} - ${before_tx_prio0_pause[$array_idx]:-0}))
        rx_p0_diff=$((${after_rx_prio0_pause[$array_idx]:-0} - ${before_rx_prio0_pause[$array_idx]:-0}))
        tx_p5_diff=$((${after_tx_prio5_pause[$array_idx]:-0} - ${before_tx_prio5_pause[$array_idx]:-0}))
        rx_p5_diff=$((${after_rx_prio5_pause[$array_idx]:-0} - ${before_rx_prio5_pause[$array_idx]:-0}))
        tx_p0_dur_diff=$((${after_tx_prio0_pause_duration[$array_idx]:-0} - ${before_tx_prio0_pause_duration[$array_idx]:-0}))
        rx_p0_dur_diff=$((${after_rx_prio0_pause_duration[$array_idx]:-0} - ${before_rx_prio0_pause_duration[$array_idx]:-0}))
        tx_p5_dur_diff=$((${after_tx_prio5_pause_duration[$array_idx]:-0} - ${before_tx_prio5_pause_duration[$array_idx]:-0}))
        rx_p5_dur_diff=$((${after_rx_prio5_pause_duration[$array_idx]:-0} - ${before_rx_prio5_pause_duration[$array_idx]:-0}))
        
        pod_tx_p0=$((pod_tx_p0 + tx_p0_diff))
        pod_rx_p0=$((pod_rx_p0 + rx_p0_diff))
        pod_tx_p5=$((pod_tx_p5 + tx_p5_diff))
        pod_rx_p5=$((pod_rx_p5 + rx_p5_diff))
        pod_tx_p0_dur=$((pod_tx_p0_dur + tx_p0_dur_diff))
        pod_rx_p0_dur=$((pod_rx_p0_dur + rx_p0_dur_diff))
        pod_tx_p5_dur=$((pod_tx_p5_dur + tx_p5_dur_diff))
        pod_rx_p5_dur=$((pod_rx_p5_dur + rx_p5_dur_diff))
    done
    
    total_tx_p0=$((total_tx_p0 + pod_tx_p0))
    total_rx_p0=$((total_rx_p0 + pod_rx_p0))
    total_tx_p5=$((total_tx_p5 + pod_tx_p5))
    total_rx_p5=$((total_rx_p5 + pod_rx_p5))
    total_tx_p0_dur=$((total_tx_p0_dur + pod_tx_p0_dur))
    total_rx_p0_dur=$((total_rx_p0_dur + pod_rx_p0_dur))
    total_tx_p5_dur=$((total_tx_p5_dur + pod_tx_p5_dur))
    total_rx_p5_dur=$((total_rx_p5_dur + pod_rx_p5_dur))
    
    printf "%-25s %-10d %-10d %-10d %-10d %-12d %-12d %-12d %-12d\n" \
           "${pod_names[$i]}" "$pod_tx_p0" "$pod_rx_p0" "$pod_tx_p5" "$pod_rx_p5" "$pod_tx_p0_dur" "$pod_rx_p0_dur" "$pod_tx_p5_dur" "$pod_rx_p5_dur"
done

printf "%-25s %-10s %-10s %-10s %-10s %-12s %-12s %-12s %-12s\n" \
       "-------------------------" "----------" "----------" "----------" "----------" "------------" "------------" "------------" "------------"
printf "%-25s %-10d %-10d %-10d %-10d %-12d %-12d %-12d %-12d\n" \
       "TOTAL" "$total_tx_p0" "$total_rx_p0" "$total_tx_p5" "$total_rx_p5" "$total_tx_p0_dur" "$total_rx_p0_dur" "$total_tx_p5_dur" "$total_rx_p5_dur"

# ECN Summary
echo ""
echo "=================================================================================================================================="
echo "SUMMARY: ECN Counter Differences"
echo "=================================================================================================================================="
printf "%-35s %-18s %-18s %-18s\n" "POD" "ecn_marked" "cnp_sent" "cnp_handled"
printf "%-35s %-18s %-18s %-18s\n" "-----------------------------------" "------------------" "------------------" "------------------"

total_ecn=0; total_cnp_sent=0; total_cnp_handled=0

for i in "${!pod_names[@]}"; do
    ecn_diff=$((${after_ecn_marked[$i]:-0} - ${before_ecn_marked[$i]:-0}))
    cnp_sent_diff=$((${after_cnp_sent[$i]:-0} - ${before_cnp_sent[$i]:-0}))
    cnp_handled_diff=$((${after_cnp_handled[$i]:-0} - ${before_cnp_handled[$i]:-0}))
    
    total_ecn=$((total_ecn + ecn_diff))
    total_cnp_sent=$((total_cnp_sent + cnp_sent_diff))
    total_cnp_handled=$((total_cnp_handled + cnp_handled_diff))
    
    printf "%-35s %-18d %-18d %-18d\n" "${pod_names[$i]}" "$ecn_diff" "$cnp_sent_diff" "$cnp_handled_diff"
done

printf "%-35s %-18s %-18s %-18s\n" "-----------------------------------" "------------------" "------------------" "------------------"
printf "%-35s %-18d %-18d %-18d\n" "TOTAL" "$total_ecn" "$total_cnp_sent" "$total_cnp_handled"

# Final notes
echo ""
echo "=============================================="
echo "Notes:"
echo "=============================================="
echo "- PFC is enabled for priorities 0 and 5"
echo "- Traffic uses: Priority 0 (NCCL bootstrap), Priority 5 (rocSHMEM/DeepEP)"
echo "- ECN counters: ecn_marked=packets marked by network, cnp_sent/handled=congestion notifications"
echo "- PFC pause: tx=sent pause frames, rx=received pause frames"
echo "- PFC pause_duration: cumulative time paused (in device-specific units, often μs)"
if [ $skipped_nics -gt 0 ]; then
    echo "- WARNING: $skipped_nics NIC(s) had data fetch failures and were excluded from totals"
fi
