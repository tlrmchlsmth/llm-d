#!/bin/bash

# NIC Counter Utilities
# Shared functions for collecting and reporting NIC counters across test scripts
#
# Usage: Source this file in your test script:
#   source "$(dirname "$0")/nic_counter_utils.sh"
#
# Required environment variables:
#   NET_DEBUG_NS - Namespace where networking-debug-pods are deployed
#
# Required variables to set before calling functions:
#   POD_NAME_WIDTH - Width for pod name column in printf (default: 25)
#
# Workflow:
#   1. Set NET_DEBUG_NS environment variable
#   2. Source this file
#   3. Create your pods array (e.g., deepep_pods)
#   4. Call: init_nic_counter_utils <pods_array_name> <pods_namespace>
#   5. Call: collect_all_counters <pods_array_name> "before"
#   6. Run your test
#   7. Call: collect_all_counters <pods_array_name> "after"
#   8. Call print functions with <pods_array_name>

# ============================================
# Configuration
# ============================================
MAX_RETRIES=${MAX_RETRIES:-3}
RETRY_DELAY=${RETRY_DELAY:-2}
POD_NAME_WIDTH=25  # Will be auto-calculated during init

# ============================================
# Internal arrays (populated by init function)
# ============================================
declare -a _node_names
declare -a _networking_debug_pods

# ============================================
# Arrays for RX priority packet counters
# ============================================
declare -a before_rx_prio0_packets
declare -a before_rx_prio1_packets
declare -a before_rx_prio5_packets
declare -a before_rx_packets_phy

declare -a after_rx_prio0_packets
declare -a after_rx_prio1_packets
declare -a after_rx_prio5_packets
declare -a after_rx_packets_phy

# ============================================
# Arrays for TX priority packet counters
# ============================================
declare -a before_tx_prio0_packets
declare -a before_tx_prio1_packets
declare -a before_tx_prio5_packets
declare -a before_tx_packets_phy

declare -a after_tx_prio0_packets
declare -a after_tx_prio1_packets
declare -a after_tx_prio5_packets
declare -a after_tx_packets_phy

# ============================================
# Arrays for RX priority discard counters
# ============================================
declare -a before_rx_prio0_buf_discard
declare -a before_rx_prio1_buf_discard
declare -a before_rx_prio5_buf_discard

declare -a after_rx_prio0_buf_discard
declare -a after_rx_prio1_buf_discard
declare -a after_rx_prio5_buf_discard

# ============================================
# Arrays for PFC pause counters (prio0 and prio5)
# ============================================
declare -a before_tx_prio0_pause
declare -a before_rx_prio0_pause
declare -a before_tx_prio5_pause
declare -a before_rx_prio5_pause
declare -a before_tx_prio0_pause_duration
declare -a before_rx_prio0_pause_duration
declare -a before_tx_prio5_pause_duration
declare -a before_rx_prio5_pause_duration

declare -a after_tx_prio0_pause
declare -a after_rx_prio0_pause
declare -a after_tx_prio5_pause
declare -a after_rx_prio5_pause
declare -a after_tx_prio0_pause_duration
declare -a after_rx_prio0_pause_duration
declare -a after_tx_prio5_pause_duration
declare -a after_rx_prio5_pause_duration

# ============================================
# Arrays for ECN counters (per pod, summed across NICs)
# ============================================
declare -a before_ecn_marked
declare -a before_cnp_sent
declare -a before_cnp_handled

declare -a after_ecn_marked
declare -a after_cnp_sent
declare -a after_cnp_handled

# ============================================
# Initialization function
# Arguments: $1=pod_names_array_ref, $2=pods_namespace
# Discovers nodes and builds networking-debug-pods array
# Auto-calculates POD_NAME_WIDTH based on longest pod name
# ============================================
init_nic_counter_utils() {
    local -n pods_ref=$1
    local pods_namespace=$2
    
    # Validate NET_DEBUG_NS is set
    if [ -z "$NET_DEBUG_NS" ]; then
        echo "ERROR: NET_DEBUG_NS environment variable is not set."
        echo "Please set it to the namespace where networking-debug-pods are deployed."
        echo "Example: export NET_DEBUG_NS=kube-system"
        return 1
    fi
    
    echo ""
    echo "=============================================="
    echo "Initializing NIC Counter Utils"
    echo "=============================================="
    echo "Pods namespace: $pods_namespace"
    echo "Networking debug pods namespace: $NET_DEBUG_NS"
    echo ""
    
    # Clear internal arrays
    _node_names=()
    _networking_debug_pods=()
    
    # Discover nodes for each pod and calculate max pod name width
    echo "Discovering nodes for pods..."
    local max_width=10  # Minimum width
    for pod in "${pods_ref[@]}"; do
        local node_name=$(kubectl get pod -n "$pods_namespace" "$pod" -o jsonpath='{.spec.nodeName}' 2>/dev/null)
        
        if [ -z "$node_name" ]; then
            echo "  [ERROR] Could not find node for pod: $pod"
            return 1
        fi
        
        _node_names+=("$node_name")
        _networking_debug_pods+=("networking-debug-pod-$node_name")
        echo "  $pod -> $node_name -> networking-debug-pod-$node_name"
        
        # Track max width
        local pod_len=${#pod}
        [ $pod_len -gt $max_width ] && max_width=$pod_len
    done
    
    # Set POD_NAME_WIDTH with some padding
    POD_NAME_WIDTH=$((max_width + 2))
    
    # Verify networking-debug-pods exist
    echo ""
    echo "Verifying networking-debug-pods in namespace $NET_DEBUG_NS..."
    for debug_pod in "${_networking_debug_pods[@]}"; do
        if ! kubectl get pod -n "$NET_DEBUG_NS" "$debug_pod" &>/dev/null; then
            echo "  [ERROR] Networking debug pod not found: $debug_pod in namespace $NET_DEBUG_NS"
            return 1
        fi
        echo "  Found: $debug_pod"
    done
    
    echo ""
    echo "Pod name column width: $POD_NAME_WIDTH"
    echo "Initialization complete."
    return 0
}

# ============================================
# Get node name for a pod index
# Arguments: $1=pod_idx
# ============================================
get_node_name() {
    local pod_idx=$1
    echo "${_node_names[$pod_idx]}"
}

# ============================================
# Function to fetch ethtool stats with retry logic
# Arguments: $1=networking_debug_pod, $2=nic
# ============================================
_fetch_ethtool_stats() {
    local pod=$1
    local nic=$2
    local retry=0
    local stats=""
    
    while [ $retry -lt $MAX_RETRIES ]; do
        stats=$(kubectl exec -n "$NET_DEBUG_NS" "$pod" -- ethtool -S "$nic" 2>/dev/null)
        
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

# ============================================
# Internal function to collect NIC counters for a single pod
# Arguments: $1=networking_debug_pod, $2=pod_idx, $3=prefix (before|after)
# ============================================
_collect_nic_counters_for_pod() {
    local debug_pod=$1
    local pod_idx=$2
    local prefix=$3
    
    for nic_idx in $(seq 0 7); do
        local array_idx=$((pod_idx * 8 + nic_idx))
        local stats=$(_fetch_ethtool_stats "$debug_pod" "rdma${nic_idx}")
        
        if [ -z "$stats" ]; then
            echo "  [ERROR] No stats retrieved for rdma${nic_idx} on $debug_pod - using -1 marker"
            if [ "$prefix" == "before" ]; then
                # RX packets
                before_rx_prio0_packets[$array_idx]=-1
                before_rx_prio1_packets[$array_idx]=-1
                before_rx_prio5_packets[$array_idx]=-1
                before_rx_packets_phy[$array_idx]=-1
                # TX packets
                before_tx_prio0_packets[$array_idx]=-1
                before_tx_prio1_packets[$array_idx]=-1
                before_tx_prio5_packets[$array_idx]=-1
                before_tx_packets_phy[$array_idx]=-1
                # RX discards
                before_rx_prio0_buf_discard[$array_idx]=-1
                before_rx_prio1_buf_discard[$array_idx]=-1
                before_rx_prio5_buf_discard[$array_idx]=-1
                # PFC pause
                before_tx_prio0_pause[$array_idx]=-1
                before_rx_prio0_pause[$array_idx]=-1
                before_tx_prio5_pause[$array_idx]=-1
                before_rx_prio5_pause[$array_idx]=-1
                before_tx_prio0_pause_duration[$array_idx]=-1
                before_rx_prio0_pause_duration[$array_idx]=-1
                before_tx_prio5_pause_duration[$array_idx]=-1
                before_rx_prio5_pause_duration[$array_idx]=-1
            else
                # RX packets
                after_rx_prio0_packets[$array_idx]=-1
                after_rx_prio1_packets[$array_idx]=-1
                after_rx_prio5_packets[$array_idx]=-1
                after_rx_packets_phy[$array_idx]=-1
                # TX packets
                after_tx_prio0_packets[$array_idx]=-1
                after_tx_prio1_packets[$array_idx]=-1
                after_tx_prio5_packets[$array_idx]=-1
                after_tx_packets_phy[$array_idx]=-1
                # RX discards
                after_rx_prio0_buf_discard[$array_idx]=-1
                after_rx_prio1_buf_discard[$array_idx]=-1
                after_rx_prio5_buf_discard[$array_idx]=-1
                # PFC pause
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
        
        # Parse RX priority packet counters
        local rx_prio0_packets=$(echo "$stats" | grep -E "^\s*rx_prio0_packets:" | awk '{print $2}')
        local rx_prio1_packets=$(echo "$stats" | grep -E "^\s*rx_prio1_packets:" | awk '{print $2}')
        local rx_prio5_packets=$(echo "$stats" | grep -E "^\s*rx_prio5_packets:" | awk '{print $2}')
        local rx_packets_phy=$(echo "$stats" | grep -E "^\s*rx_packets_phy:" | awk '{print $2}')
        
        # Parse TX priority packet counters
        local tx_prio0_packets=$(echo "$stats" | grep -E "^\s*tx_prio0_packets:" | awk '{print $2}')
        local tx_prio1_packets=$(echo "$stats" | grep -E "^\s*tx_prio1_packets:" | awk '{print $2}')
        local tx_prio5_packets=$(echo "$stats" | grep -E "^\s*tx_prio5_packets:" | awk '{print $2}')
        local tx_packets_phy=$(echo "$stats" | grep -E "^\s*tx_packets_phy:" | awk '{print $2}')
        
        # Parse RX priority discard counters
        local rx_prio0_buf_discard=$(echo "$stats" | grep -E "^\s*rx_prio0_buf_discard:" | awk '{print $2}')
        local rx_prio1_buf_discard=$(echo "$stats" | grep -E "^\s*rx_prio1_buf_discard:" | awk '{print $2}')
        local rx_prio5_buf_discard=$(echo "$stats" | grep -E "^\s*rx_prio5_buf_discard:" | awk '{print $2}')
        
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
            # RX packets
            before_rx_prio0_packets[$array_idx]=${rx_prio0_packets:-0}
            before_rx_prio1_packets[$array_idx]=${rx_prio1_packets:-0}
            before_rx_prio5_packets[$array_idx]=${rx_prio5_packets:-0}
            before_rx_packets_phy[$array_idx]=${rx_packets_phy:-0}
            # TX packets
            before_tx_prio0_packets[$array_idx]=${tx_prio0_packets:-0}
            before_tx_prio1_packets[$array_idx]=${tx_prio1_packets:-0}
            before_tx_prio5_packets[$array_idx]=${tx_prio5_packets:-0}
            before_tx_packets_phy[$array_idx]=${tx_packets_phy:-0}
            # RX discards
            before_rx_prio0_buf_discard[$array_idx]=${rx_prio0_buf_discard:-0}
            before_rx_prio1_buf_discard[$array_idx]=${rx_prio1_buf_discard:-0}
            before_rx_prio5_buf_discard[$array_idx]=${rx_prio5_buf_discard:-0}
            # PFC pause
            before_tx_prio0_pause[$array_idx]=${tx_prio0_pause:-0}
            before_rx_prio0_pause[$array_idx]=${rx_prio0_pause:-0}
            before_tx_prio5_pause[$array_idx]=${tx_prio5_pause:-0}
            before_rx_prio5_pause[$array_idx]=${rx_prio5_pause:-0}
            before_tx_prio0_pause_duration[$array_idx]=${tx_prio0_pause_duration:-0}
            before_rx_prio0_pause_duration[$array_idx]=${rx_prio0_pause_duration:-0}
            before_tx_prio5_pause_duration[$array_idx]=${tx_prio5_pause_duration:-0}
            before_rx_prio5_pause_duration[$array_idx]=${rx_prio5_pause_duration:-0}
        else
            # RX packets
            after_rx_prio0_packets[$array_idx]=${rx_prio0_packets:-0}
            after_rx_prio1_packets[$array_idx]=${rx_prio1_packets:-0}
            after_rx_prio5_packets[$array_idx]=${rx_prio5_packets:-0}
            after_rx_packets_phy[$array_idx]=${rx_packets_phy:-0}
            # TX packets
            after_tx_prio0_packets[$array_idx]=${tx_prio0_packets:-0}
            after_tx_prio1_packets[$array_idx]=${tx_prio1_packets:-0}
            after_tx_prio5_packets[$array_idx]=${tx_prio5_packets:-0}
            after_tx_packets_phy[$array_idx]=${tx_packets_phy:-0}
            # RX discards
            after_rx_prio0_buf_discard[$array_idx]=${rx_prio0_buf_discard:-0}
            after_rx_prio1_buf_discard[$array_idx]=${rx_prio1_buf_discard:-0}
            after_rx_prio5_buf_discard[$array_idx]=${rx_prio5_buf_discard:-0}
            # PFC pause
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

# ============================================
# Internal function to collect ECN counters for a single pod
# Arguments: $1=networking_debug_pod, $2=pod_idx, $3=prefix (before|after)
# ============================================
_collect_ecn_counters_for_pod() {
    local debug_pod=$1
    local pod_idx=$2
    local prefix=$3
    
    # Sum ECN counters across all mlx5 devices
    local total_ecn_marked=0
    local total_cnp_sent=0
    local total_cnp_handled=0
    
    local ecn_data=$(kubectl exec -n "$NET_DEBUG_NS" "$debug_pod" -- bash -c '
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

# ============================================
# Collect NIC counters for all pods
# Arguments: $1=pod_names_array_ref, $2=prefix (before|after)
# ============================================
collect_nic_counters() {
    local -n pods_ref=$1
    local prefix=$2
    
    for i in "${!pods_ref[@]}"; do
        echo "  Collecting NIC counters from ${_networking_debug_pods[$i]} (for ${pods_ref[$i]})..."
        _collect_nic_counters_for_pod "${_networking_debug_pods[$i]}" "$i" "$prefix"
    done
}

# ============================================
# Collect ECN counters for all pods
# Arguments: $1=pod_names_array_ref, $2=prefix (before|after)
# ============================================
collect_ecn_counters() {
    local -n pods_ref=$1
    local prefix=$2
    
    for i in "${!pods_ref[@]}"; do
        echo "  Collecting ECN counters from ${_networking_debug_pods[$i]} (for ${pods_ref[$i]})..."
        _collect_ecn_counters_for_pod "${_networking_debug_pods[$i]}" "$i" "$prefix"
    done
}

# ============================================
# Collect all counters (NIC + ECN) for all pods
# Arguments: $1=pod_names_array_ref, $2=prefix (before|after)
# ============================================
collect_all_counters() {
    local -n pods_ref=$1
    local prefix=$2
    local prefix_upper=$(echo "$prefix" | tr '[:lower:]' '[:upper:]')
    
    echo ""
    echo "=============================================="
    echo "Collecting NIC Counters ${prefix_upper} Test"
    echo "=============================================="
    
    for i in "${!pods_ref[@]}"; do
        echo "  Collecting from ${_networking_debug_pods[$i]} (for ${pods_ref[$i]})..."
        _collect_nic_counters_for_pod "${_networking_debug_pods[$i]}" "$i" "$prefix"
        _collect_ecn_counters_for_pod "${_networking_debug_pods[$i]}" "$i" "$prefix"
    done
}

# ============================================
# Function to format counter value (show FAILED for -1)
# Arguments: $1=value
# ============================================
format_counter() {
    local val=$1
    if [ "$val" == "-1" ]; then
        echo "FAILED"
    else
        echo "$val"
    fi
}

# ============================================
# Function to print Packet Counters tables
# Arguments: $1=pod_names_array_ref, $2=prefix (before|after)
# ============================================
print_nic_counters() {
    local -n pods_ref=$1
    local prefix=$2
    local prefix_upper=$(echo "$prefix" | tr '[:lower:]' '[:upper:]')
    
    for i in "${!pods_ref[@]}"; do
        local pod="${pods_ref[$i]}"
        local node="${_node_names[$i]}"
        
        # Main heading: Packet Counters
        echo ""
        echo "=============================================================================="
        echo "Packet Counters ($prefix_upper) for: $pod (Node: $node)"
        echo "=============================================================================="
        
        # Sub-heading: RX Packets
        echo ""
        echo "RX Packets:"
        printf "%-8s %-20s %-20s %-20s %-18s\n" \
               "NIC" "rx_prio0_packets" "rx_prio1_packets" "rx_prio5_packets" "rx_packets_phy"
        printf "%-8s %-20s %-20s %-20s %-18s\n" \
               "--------" "--------------------" "--------------------" "--------------------" "------------------"
        
        for nic_idx in $(seq 0 7); do
            local array_idx=$((i * 8 + nic_idx))
            if [ "$prefix" == "before" ]; then
                printf "%-8s %-20s %-20s %-20s %-18s\n" \
                       "rdma${nic_idx}" \
                       "$(format_counter "${before_rx_prio0_packets[$array_idx]}")" \
                       "$(format_counter "${before_rx_prio1_packets[$array_idx]}")" \
                       "$(format_counter "${before_rx_prio5_packets[$array_idx]}")" \
                       "$(format_counter "${before_rx_packets_phy[$array_idx]}")"
            else
                printf "%-8s %-20s %-20s %-20s %-18s\n" \
                       "rdma${nic_idx}" \
                       "$(format_counter "${after_rx_prio0_packets[$array_idx]}")" \
                       "$(format_counter "${after_rx_prio1_packets[$array_idx]}")" \
                       "$(format_counter "${after_rx_prio5_packets[$array_idx]}")" \
                       "$(format_counter "${after_rx_packets_phy[$array_idx]}")"
            fi
        done
        
        # Sub-heading: TX Packets
        echo ""
        echo "TX Packets:"
        printf "%-8s %-20s %-20s %-20s %-18s\n" \
               "NIC" "tx_prio0_packets" "tx_prio1_packets" "tx_prio5_packets" "tx_packets_phy"
        printf "%-8s %-20s %-20s %-20s %-18s\n" \
               "--------" "--------------------" "--------------------" "--------------------" "------------------"
        
        for nic_idx in $(seq 0 7); do
            local array_idx=$((i * 8 + nic_idx))
            if [ "$prefix" == "before" ]; then
                printf "%-8s %-20s %-20s %-20s %-18s\n" \
                       "rdma${nic_idx}" \
                       "$(format_counter "${before_tx_prio0_packets[$array_idx]}")" \
                       "$(format_counter "${before_tx_prio1_packets[$array_idx]}")" \
                       "$(format_counter "${before_tx_prio5_packets[$array_idx]}")" \
                       "$(format_counter "${before_tx_packets_phy[$array_idx]}")"
            else
                printf "%-8s %-20s %-20s %-20s %-18s\n" \
                       "rdma${nic_idx}" \
                       "$(format_counter "${after_tx_prio0_packets[$array_idx]}")" \
                       "$(format_counter "${after_tx_prio1_packets[$array_idx]}")" \
                       "$(format_counter "${after_tx_prio5_packets[$array_idx]}")" \
                       "$(format_counter "${after_tx_packets_phy[$array_idx]}")"
            fi
        done
        
        # Sub-heading: RX Discards
        echo ""
        echo "RX Discards:"
        printf "%-8s %-24s %-24s %-24s\n" \
               "NIC" "rx_prio0_buf_discard" "rx_prio1_buf_discard" "rx_prio5_buf_discard"
        printf "%-8s %-24s %-24s %-24s\n" \
               "--------" "------------------------" "------------------------" "------------------------"
        
        for nic_idx in $(seq 0 7); do
            local array_idx=$((i * 8 + nic_idx))
            if [ "$prefix" == "before" ]; then
                printf "%-8s %-24s %-24s %-24s\n" \
                       "rdma${nic_idx}" \
                       "$(format_counter "${before_rx_prio0_buf_discard[$array_idx]}")" \
                       "$(format_counter "${before_rx_prio1_buf_discard[$array_idx]}")" \
                       "$(format_counter "${before_rx_prio5_buf_discard[$array_idx]}")"
            else
                printf "%-8s %-24s %-24s %-24s\n" \
                       "rdma${nic_idx}" \
                       "$(format_counter "${after_rx_prio0_buf_discard[$array_idx]}")" \
                       "$(format_counter "${after_rx_prio1_buf_discard[$array_idx]}")" \
                       "$(format_counter "${after_rx_prio5_buf_discard[$array_idx]}")"
            fi
        done
    done
}

# ============================================
# Function to print PFC Counters tables
# Arguments: $1=pod_names_array_ref, $2=prefix (before|after)
# ============================================
print_pfc_counters() {
    local -n pods_ref=$1
    local prefix=$2
    local prefix_upper=$(echo "$prefix" | tr '[:lower:]' '[:upper:]')
    
    for i in "${!pods_ref[@]}"; do
        local pod="${pods_ref[$i]}"
        local node="${_node_names[$i]}"
        
        # Main heading: PFC Counters
        echo ""
        echo "=============================================================================="
        echo "PFC Counters ($prefix_upper) for: $pod (Node: $node) - Priorities 0 and 5"
        echo "=============================================================================="
        
        # Sub-heading: Pause Counts
        echo ""
        echo "Pause Counts:"
        printf "%-8s %-18s %-18s %-18s %-18s\n" \
               "NIC" "tx_prio0_pause" "rx_prio0_pause" "tx_prio5_pause" "rx_prio5_pause"
        printf "%-8s %-18s %-18s %-18s %-18s\n" \
               "--------" "------------------" "------------------" "------------------" "------------------"
        
        for nic_idx in $(seq 0 7); do
            local array_idx=$((i * 8 + nic_idx))
            if [ "$prefix" == "before" ]; then
                printf "%-8s %-18s %-18s %-18s %-18s\n" \
                       "rdma${nic_idx}" \
                       "$(format_counter "${before_tx_prio0_pause[$array_idx]}")" \
                       "$(format_counter "${before_rx_prio0_pause[$array_idx]}")" \
                       "$(format_counter "${before_tx_prio5_pause[$array_idx]}")" \
                       "$(format_counter "${before_rx_prio5_pause[$array_idx]}")"
            else
                printf "%-8s %-18s %-18s %-18s %-18s\n" \
                       "rdma${nic_idx}" \
                       "$(format_counter "${after_tx_prio0_pause[$array_idx]}")" \
                       "$(format_counter "${after_rx_prio0_pause[$array_idx]}")" \
                       "$(format_counter "${after_tx_prio5_pause[$array_idx]}")" \
                       "$(format_counter "${after_rx_prio5_pause[$array_idx]}")"
            fi
        done
        
        # Sub-heading: Pause Durations
        echo ""
        echo "Pause Durations:"
        printf "%-8s %-26s %-26s %-26s %-26s\n" \
               "NIC" "tx_prio0_pause_duration" "rx_prio0_pause_duration" "tx_prio5_pause_duration" "rx_prio5_pause_duration"
        printf "%-8s %-26s %-26s %-26s %-26s\n" \
               "--------" "--------------------------" "--------------------------" "--------------------------" "--------------------------"
        
        for nic_idx in $(seq 0 7); do
            local array_idx=$((i * 8 + nic_idx))
            if [ "$prefix" == "before" ]; then
                printf "%-8s %-26s %-26s %-26s %-26s\n" \
                       "rdma${nic_idx}" \
                       "$(format_counter "${before_tx_prio0_pause_duration[$array_idx]}")" \
                       "$(format_counter "${before_rx_prio0_pause_duration[$array_idx]}")" \
                       "$(format_counter "${before_tx_prio5_pause_duration[$array_idx]}")" \
                       "$(format_counter "${before_rx_prio5_pause_duration[$array_idx]}")"
            else
                printf "%-8s %-26s %-26s %-26s %-26s\n" \
                       "rdma${nic_idx}" \
                       "$(format_counter "${after_tx_prio0_pause_duration[$array_idx]}")" \
                       "$(format_counter "${after_rx_prio0_pause_duration[$array_idx]}")" \
                       "$(format_counter "${after_tx_prio5_pause_duration[$array_idx]}")" \
                       "$(format_counter "${after_rx_prio5_pause_duration[$array_idx]}")"
            fi
        done
    done
}

# ============================================
# Function to print Packet Counter differences
# Arguments: $1=pod_names_array_ref
# ============================================
print_nic_counter_diff() {
    local -n pods_ref=$1
    
    for i in "${!pods_ref[@]}"; do
        local pod="${pods_ref[$i]}"
        local node="${_node_names[$i]}"
        
        # Main heading: Packet Counters DIFF
        echo ""
        echo "=============================================================================="
        echo "Packet Counters DIFF for: $pod (Node: $node)"
        echo "=============================================================================="
        
        # Sub-heading: RX Packets
        echo ""
        echo "RX Packets:"
        printf "%-8s %-20s %-20s %-20s %-18s\n" \
               "NIC" "rx_prio0_packets" "rx_prio1_packets" "rx_prio5_packets" "rx_packets_phy"
        printf "%-8s %-20s %-20s %-20s %-18s\n" \
               "--------" "--------------------" "--------------------" "--------------------" "------------------"
        
        for nic_idx in $(seq 0 7); do
            local array_idx=$((i * 8 + nic_idx))
            
            if [ "${before_rx_prio0_packets[$array_idx]}" == "-1" ] || [ "${after_rx_prio0_packets[$array_idx]}" == "-1" ]; then
                printf "%-8s %-20s %-20s %-20s %-18s\n" \
                       "rdma${nic_idx}" "SKIPPED" "SKIPPED" "SKIPPED" "SKIPPED"
                continue
            fi
            
            local rx_p0_diff=$((${after_rx_prio0_packets[$array_idx]:-0} - ${before_rx_prio0_packets[$array_idx]:-0}))
            local rx_p1_diff=$((${after_rx_prio1_packets[$array_idx]:-0} - ${before_rx_prio1_packets[$array_idx]:-0}))
            local rx_p5_diff=$((${after_rx_prio5_packets[$array_idx]:-0} - ${before_rx_prio5_packets[$array_idx]:-0}))
            local rx_phy_diff=$((${after_rx_packets_phy[$array_idx]:-0} - ${before_rx_packets_phy[$array_idx]:-0}))
            printf "%-8s %-20s %-20s %-20s %-18s\n" \
                   "rdma${nic_idx}" "$rx_p0_diff" "$rx_p1_diff" "$rx_p5_diff" "$rx_phy_diff"
        done
        
        # Sub-heading: TX Packets
        echo ""
        echo "TX Packets:"
        printf "%-8s %-20s %-20s %-20s %-18s\n" \
               "NIC" "tx_prio0_packets" "tx_prio1_packets" "tx_prio5_packets" "tx_packets_phy"
        printf "%-8s %-20s %-20s %-20s %-18s\n" \
               "--------" "--------------------" "--------------------" "--------------------" "------------------"
        
        for nic_idx in $(seq 0 7); do
            local array_idx=$((i * 8 + nic_idx))
            
            if [ "${before_tx_prio0_packets[$array_idx]}" == "-1" ] || [ "${after_tx_prio0_packets[$array_idx]}" == "-1" ]; then
                printf "%-8s %-20s %-20s %-20s %-18s\n" \
                       "rdma${nic_idx}" "SKIPPED" "SKIPPED" "SKIPPED" "SKIPPED"
                continue
            fi
            
            local tx_p0_diff=$((${after_tx_prio0_packets[$array_idx]:-0} - ${before_tx_prio0_packets[$array_idx]:-0}))
            local tx_p1_diff=$((${after_tx_prio1_packets[$array_idx]:-0} - ${before_tx_prio1_packets[$array_idx]:-0}))
            local tx_p5_diff=$((${after_tx_prio5_packets[$array_idx]:-0} - ${before_tx_prio5_packets[$array_idx]:-0}))
            local tx_phy_diff=$((${after_tx_packets_phy[$array_idx]:-0} - ${before_tx_packets_phy[$array_idx]:-0}))
            printf "%-8s %-20s %-20s %-20s %-18s\n" \
                   "rdma${nic_idx}" "$tx_p0_diff" "$tx_p1_diff" "$tx_p5_diff" "$tx_phy_diff"
        done
        
        # Sub-heading: RX Discards
        echo ""
        echo "RX Discards:"
        printf "%-8s %-24s %-24s %-24s\n" \
               "NIC" "rx_prio0_buf_discard" "rx_prio1_buf_discard" "rx_prio5_buf_discard"
        printf "%-8s %-24s %-24s %-24s\n" \
               "--------" "------------------------" "------------------------" "------------------------"
        
        for nic_idx in $(seq 0 7); do
            local array_idx=$((i * 8 + nic_idx))
            
            if [ "${before_rx_prio0_buf_discard[$array_idx]}" == "-1" ] || [ "${after_rx_prio0_buf_discard[$array_idx]}" == "-1" ]; then
                printf "%-8s %-24s %-24s %-24s\n" \
                       "rdma${nic_idx}" "SKIPPED" "SKIPPED" "SKIPPED"
                continue
            fi
            
            local disc_p0_diff=$((${after_rx_prio0_buf_discard[$array_idx]:-0} - ${before_rx_prio0_buf_discard[$array_idx]:-0}))
            local disc_p1_diff=$((${after_rx_prio1_buf_discard[$array_idx]:-0} - ${before_rx_prio1_buf_discard[$array_idx]:-0}))
            local disc_p5_diff=$((${after_rx_prio5_buf_discard[$array_idx]:-0} - ${before_rx_prio5_buf_discard[$array_idx]:-0}))
            printf "%-8s %-24s %-24s %-24s\n" \
                   "rdma${nic_idx}" "$disc_p0_diff" "$disc_p1_diff" "$disc_p5_diff"
        done
    done
}

# ============================================
# Function to print PFC Counter differences
# Arguments: $1=pod_names_array_ref
# ============================================
print_pfc_counter_diff() {
    local -n pods_ref=$1
    
    for i in "${!pods_ref[@]}"; do
        local pod="${pods_ref[$i]}"
        local node="${_node_names[$i]}"
        
        # Main heading: PFC Counters DIFF
        echo ""
        echo "=============================================================================="
        echo "PFC Counters DIFF for: $pod (Node: $node) - Priorities 0 and 5"
        echo "=============================================================================="
        
        # Sub-heading: Pause Counts
        echo ""
        echo "Pause Counts:"
        printf "%-8s %-18s %-18s %-18s %-18s\n" \
               "NIC" "tx_prio0_pause" "rx_prio0_pause" "tx_prio5_pause" "rx_prio5_pause"
        printf "%-8s %-18s %-18s %-18s %-18s\n" \
               "--------" "------------------" "------------------" "------------------" "------------------"
        
        for nic_idx in $(seq 0 7); do
            local array_idx=$((i * 8 + nic_idx))
            
            if [ "${before_tx_prio0_pause[$array_idx]}" == "-1" ] || [ "${after_tx_prio0_pause[$array_idx]}" == "-1" ]; then
                printf "%-8s %-18s %-18s %-18s %-18s\n" \
                       "rdma${nic_idx}" "SKIPPED" "SKIPPED" "SKIPPED" "SKIPPED"
                continue
            fi
            
            local tx_p0_diff=$((${after_tx_prio0_pause[$array_idx]:-0} - ${before_tx_prio0_pause[$array_idx]:-0}))
            local rx_p0_diff=$((${after_rx_prio0_pause[$array_idx]:-0} - ${before_rx_prio0_pause[$array_idx]:-0}))
            local tx_p5_diff=$((${after_tx_prio5_pause[$array_idx]:-0} - ${before_tx_prio5_pause[$array_idx]:-0}))
            local rx_p5_diff=$((${after_rx_prio5_pause[$array_idx]:-0} - ${before_rx_prio5_pause[$array_idx]:-0}))
            printf "%-8s %-18s %-18s %-18s %-18s\n" \
                   "rdma${nic_idx}" "$tx_p0_diff" "$rx_p0_diff" "$tx_p5_diff" "$rx_p5_diff"
        done
        
        # Sub-heading: Pause Durations
        echo ""
        echo "Pause Durations:"
        printf "%-8s %-26s %-26s %-26s %-26s\n" \
               "NIC" "tx_prio0_pause_duration" "rx_prio0_pause_duration" "tx_prio5_pause_duration" "rx_prio5_pause_duration"
        printf "%-8s %-26s %-26s %-26s %-26s\n" \
               "--------" "--------------------------" "--------------------------" "--------------------------" "--------------------------"
        
        for nic_idx in $(seq 0 7); do
            local array_idx=$((i * 8 + nic_idx))
            
            if [ "${before_tx_prio0_pause_duration[$array_idx]}" == "-1" ] || [ "${after_tx_prio0_pause_duration[$array_idx]}" == "-1" ]; then
                printf "%-8s %-26s %-26s %-26s %-26s\n" \
                       "rdma${nic_idx}" "SKIPPED" "SKIPPED" "SKIPPED" "SKIPPED"
                continue
            fi
            
            local tx_p0_dur_diff=$((${after_tx_prio0_pause_duration[$array_idx]:-0} - ${before_tx_prio0_pause_duration[$array_idx]:-0}))
            local rx_p0_dur_diff=$((${after_rx_prio0_pause_duration[$array_idx]:-0} - ${before_rx_prio0_pause_duration[$array_idx]:-0}))
            local tx_p5_dur_diff=$((${after_tx_prio5_pause_duration[$array_idx]:-0} - ${before_tx_prio5_pause_duration[$array_idx]:-0}))
            local rx_p5_dur_diff=$((${after_rx_prio5_pause_duration[$array_idx]:-0} - ${before_rx_prio5_pause_duration[$array_idx]:-0}))
            printf "%-8s %-26s %-26s %-26s %-26s\n" \
                   "rdma${nic_idx}" "$tx_p0_dur_diff" "$rx_p0_dur_diff" "$tx_p5_dur_diff" "$rx_p5_dur_diff"
        done
    done
}

# ============================================
# Function to print ECN counters table
# Arguments: $1=pod_names_array_ref, $2=prefix (before|after)
# ============================================
print_ecn_counters() {
    local -n pods_ref=$1
    local prefix=$2
    local prefix_upper=$(echo "$prefix" | tr '[:lower:]' '[:upper:]')
    
    # Main heading: ECN Counters (no sub-headings needed)
    echo ""
    echo "=============================================================================="
    echo "ECN Counters ($prefix_upper)"
    echo "=============================================================================="
    printf "%-${POD_NAME_WIDTH}s %-28s %-18s %-18s\n" "POD" "np_ecn_marked_roce_packets" "np_cnp_sent" "rp_cnp_handled"
    printf "%-${POD_NAME_WIDTH}s %-28s %-18s %-18s\n" "$(printf '%0.s-' $(seq 1 $POD_NAME_WIDTH))" "----------------------------" "------------------" "------------------"
    
    for i in "${!pods_ref[@]}"; do
        if [ "$prefix" == "before" ]; then
            printf "%-${POD_NAME_WIDTH}s %-28s %-18s %-18s\n" "${pods_ref[$i]}" "${before_ecn_marked[$i]}" "${before_cnp_sent[$i]}" "${before_cnp_handled[$i]}"
        else
            printf "%-${POD_NAME_WIDTH}s %-28s %-18s %-18s\n" "${pods_ref[$i]}" "${after_ecn_marked[$i]}" "${after_cnp_sent[$i]}" "${after_cnp_handled[$i]}"
        fi
    done
}

# ============================================
# Function to print all counters (NIC + PFC + ECN)
# Arguments: $1=pod_names_array_ref, $2=prefix (before|after)
# ============================================
print_all_counters() {
    local -n pods_ref=$1
    local prefix=$2
    
    print_nic_counters "$1" "$prefix"
    print_pfc_counters "$1" "$prefix"
    print_ecn_counters "$1" "$prefix"
}

# ============================================
# Function to print all counter differences
# Arguments: $1=pod_names_array_ref
# ============================================
print_all_counter_diff() {
    local -n pods_ref=$1
    
    echo ""
    echo "=============================================="
    echo "NIC Counter DIFFERENCES (After - Before)"
    echo "=============================================="
    
    print_nic_counter_diff "$1"
    print_pfc_counter_diff "$1"
}

# ============================================
# Function to print priority packet counter summary (split by category)
# Arguments: $1=pod_names_array_ref
# Returns: Sets global skipped_nics variable
# ============================================
print_priority_packet_summary() {
    local -n pods_ref=$1
    
    # Calculate totals for all categories first
    local total_rx_p0=0 total_rx_p1=0 total_rx_p5=0 total_rx_phy=0
    local total_tx_p0=0 total_tx_p1=0 total_tx_p5=0 total_tx_phy=0
    local total_disc_p0=0 total_disc_p1=0 total_disc_p5=0
    skipped_nics=0
    
    # Arrays to hold per-pod totals
    declare -a pod_rx_p0 pod_rx_p1 pod_rx_p5 pod_rx_phy
    declare -a pod_tx_p0 pod_tx_p1 pod_tx_p5 pod_tx_phy
    declare -a pod_disc_p0 pod_disc_p1 pod_disc_p5
    declare -a pod_skipped
    
    for i in "${!pods_ref[@]}"; do
        pod_rx_p0[$i]=0; pod_rx_p1[$i]=0; pod_rx_p5[$i]=0; pod_rx_phy[$i]=0
        pod_tx_p0[$i]=0; pod_tx_p1[$i]=0; pod_tx_p5[$i]=0; pod_tx_phy[$i]=0
        pod_disc_p0[$i]=0; pod_disc_p1[$i]=0; pod_disc_p5[$i]=0
        pod_skipped[$i]=0
        
        for nic_idx in $(seq 0 7); do
            local array_idx=$((i * 8 + nic_idx))
            
            if [ "${before_rx_prio0_packets[$array_idx]}" == "-1" ] || [ "${after_rx_prio0_packets[$array_idx]}" == "-1" ]; then
                pod_skipped[$i]=$((${pod_skipped[$i]} + 1))
                skipped_nics=$((skipped_nics + 1))
                continue
            fi
            
            # RX packets
            pod_rx_p0[$i]=$((${pod_rx_p0[$i]} + ${after_rx_prio0_packets[$array_idx]:-0} - ${before_rx_prio0_packets[$array_idx]:-0}))
            pod_rx_p1[$i]=$((${pod_rx_p1[$i]} + ${after_rx_prio1_packets[$array_idx]:-0} - ${before_rx_prio1_packets[$array_idx]:-0}))
            pod_rx_p5[$i]=$((${pod_rx_p5[$i]} + ${after_rx_prio5_packets[$array_idx]:-0} - ${before_rx_prio5_packets[$array_idx]:-0}))
            pod_rx_phy[$i]=$((${pod_rx_phy[$i]} + ${after_rx_packets_phy[$array_idx]:-0} - ${before_rx_packets_phy[$array_idx]:-0}))
            # TX packets
            pod_tx_p0[$i]=$((${pod_tx_p0[$i]} + ${after_tx_prio0_packets[$array_idx]:-0} - ${before_tx_prio0_packets[$array_idx]:-0}))
            pod_tx_p1[$i]=$((${pod_tx_p1[$i]} + ${after_tx_prio1_packets[$array_idx]:-0} - ${before_tx_prio1_packets[$array_idx]:-0}))
            pod_tx_p5[$i]=$((${pod_tx_p5[$i]} + ${after_tx_prio5_packets[$array_idx]:-0} - ${before_tx_prio5_packets[$array_idx]:-0}))
            pod_tx_phy[$i]=$((${pod_tx_phy[$i]} + ${after_tx_packets_phy[$array_idx]:-0} - ${before_tx_packets_phy[$array_idx]:-0}))
            # RX discards
            pod_disc_p0[$i]=$((${pod_disc_p0[$i]} + ${after_rx_prio0_buf_discard[$array_idx]:-0} - ${before_rx_prio0_buf_discard[$array_idx]:-0}))
            pod_disc_p1[$i]=$((${pod_disc_p1[$i]} + ${after_rx_prio1_buf_discard[$array_idx]:-0} - ${before_rx_prio1_buf_discard[$array_idx]:-0}))
            pod_disc_p5[$i]=$((${pod_disc_p5[$i]} + ${after_rx_prio5_buf_discard[$array_idx]:-0} - ${before_rx_prio5_buf_discard[$array_idx]:-0}))
        done
        
        total_rx_p0=$((total_rx_p0 + ${pod_rx_p0[$i]}))
        total_rx_p1=$((total_rx_p1 + ${pod_rx_p1[$i]}))
        total_rx_p5=$((total_rx_p5 + ${pod_rx_p5[$i]}))
        total_rx_phy=$((total_rx_phy + ${pod_rx_phy[$i]}))
        total_tx_p0=$((total_tx_p0 + ${pod_tx_p0[$i]}))
        total_tx_p1=$((total_tx_p1 + ${pod_tx_p1[$i]}))
        total_tx_p5=$((total_tx_p5 + ${pod_tx_p5[$i]}))
        total_tx_phy=$((total_tx_phy + ${pod_tx_phy[$i]}))
        total_disc_p0=$((total_disc_p0 + ${pod_disc_p0[$i]}))
        total_disc_p1=$((total_disc_p1 + ${pod_disc_p1[$i]}))
        total_disc_p5=$((total_disc_p5 + ${pod_disc_p5[$i]}))
    done
    
    # Main heading: SUMMARY - Packet Counters
    echo ""
    echo "=============================================================================="
    echo "SUMMARY: Packet Counters"
    echo "=============================================================================="
    
    # Sub-heading: RX Packets
    echo ""
    echo "RX Packets:"
    printf "%-${POD_NAME_WIDTH}s %-20s %-20s %-20s %-18s\n" \
           "POD" "rx_prio0_packets" "rx_prio1_packets" "rx_prio5_packets" "rx_packets_phy"
    printf "%-${POD_NAME_WIDTH}s %-20s %-20s %-20s %-18s\n" \
           "$(printf '%0.s-' $(seq 1 $POD_NAME_WIDTH))" "--------------------" "--------------------" "--------------------" "------------------"
    
    for i in "${!pods_ref[@]}"; do
        if [ ${pod_skipped[$i]} -gt 0 ]; then
            printf "%-${POD_NAME_WIDTH}s %-20d %-20d %-20d %-18d (%d skip)\n" \
                   "${pods_ref[$i]}" "${pod_rx_p0[$i]}" "${pod_rx_p1[$i]}" "${pod_rx_p5[$i]}" "${pod_rx_phy[$i]}" "${pod_skipped[$i]}"
        else
            printf "%-${POD_NAME_WIDTH}s %-20d %-20d %-20d %-18d\n" \
                   "${pods_ref[$i]}" "${pod_rx_p0[$i]}" "${pod_rx_p1[$i]}" "${pod_rx_p5[$i]}" "${pod_rx_phy[$i]}"
        fi
    done
    printf "%-${POD_NAME_WIDTH}s %-20s %-20s %-20s %-18s\n" \
           "$(printf '%0.s-' $(seq 1 $POD_NAME_WIDTH))" "--------------------" "--------------------" "--------------------" "------------------"
    printf "%-${POD_NAME_WIDTH}s %-20d %-20d %-20d %-18d\n" \
           "TOTAL" "$total_rx_p0" "$total_rx_p1" "$total_rx_p5" "$total_rx_phy"
    
    # Sub-heading: TX Packets
    echo ""
    echo "TX Packets:"
    printf "%-${POD_NAME_WIDTH}s %-20s %-20s %-20s %-18s\n" \
           "POD" "tx_prio0_packets" "tx_prio1_packets" "tx_prio5_packets" "tx_packets_phy"
    printf "%-${POD_NAME_WIDTH}s %-20s %-20s %-20s %-18s\n" \
           "$(printf '%0.s-' $(seq 1 $POD_NAME_WIDTH))" "--------------------" "--------------------" "--------------------" "------------------"
    
    for i in "${!pods_ref[@]}"; do
        printf "%-${POD_NAME_WIDTH}s %-20d %-20d %-20d %-18d\n" \
               "${pods_ref[$i]}" "${pod_tx_p0[$i]}" "${pod_tx_p1[$i]}" "${pod_tx_p5[$i]}" "${pod_tx_phy[$i]}"
    done
    printf "%-${POD_NAME_WIDTH}s %-20s %-20s %-20s %-18s\n" \
           "$(printf '%0.s-' $(seq 1 $POD_NAME_WIDTH))" "--------------------" "--------------------" "--------------------" "------------------"
    printf "%-${POD_NAME_WIDTH}s %-20d %-20d %-20d %-18d\n" \
           "TOTAL" "$total_tx_p0" "$total_tx_p1" "$total_tx_p5" "$total_tx_phy"
    
    # Sub-heading: RX Discards
    echo ""
    echo "RX Discards:"
    printf "%-${POD_NAME_WIDTH}s %-24s %-24s %-24s\n" \
           "POD" "rx_prio0_buf_discard" "rx_prio1_buf_discard" "rx_prio5_buf_discard"
    printf "%-${POD_NAME_WIDTH}s %-24s %-24s %-24s\n" \
           "$(printf '%0.s-' $(seq 1 $POD_NAME_WIDTH))" "------------------------" "------------------------" "------------------------"
    
    for i in "${!pods_ref[@]}"; do
        printf "%-${POD_NAME_WIDTH}s %-24d %-24d %-24d\n" \
               "${pods_ref[$i]}" "${pod_disc_p0[$i]}" "${pod_disc_p1[$i]}" "${pod_disc_p5[$i]}"
    done
    printf "%-${POD_NAME_WIDTH}s %-24s %-24s %-24s\n" \
           "$(printf '%0.s-' $(seq 1 $POD_NAME_WIDTH))" "------------------------" "------------------------" "------------------------"
    printf "%-${POD_NAME_WIDTH}s %-24d %-24d %-24d\n" \
           "TOTAL" "$total_disc_p0" "$total_disc_p1" "$total_disc_p5"
}

# ============================================
# Function to print PFC pause counter summary (split by counts and durations)
# Arguments: $1=pod_names_array_ref
# ============================================
print_pfc_pause_summary() {
    local -n pods_ref=$1
    
    # Calculate totals first
    local total_tx_p0=0 total_rx_p0=0 total_tx_p5=0 total_rx_p5=0
    local total_tx_p0_dur=0 total_rx_p0_dur=0 total_tx_p5_dur=0 total_rx_p5_dur=0
    
    # Arrays to hold per-pod totals
    declare -a pod_tx_p0 pod_rx_p0 pod_tx_p5 pod_rx_p5
    declare -a pod_tx_p0_dur pod_rx_p0_dur pod_tx_p5_dur pod_rx_p5_dur
    
    for i in "${!pods_ref[@]}"; do
        pod_tx_p0[$i]=0; pod_rx_p0[$i]=0; pod_tx_p5[$i]=0; pod_rx_p5[$i]=0
        pod_tx_p0_dur[$i]=0; pod_rx_p0_dur[$i]=0; pod_tx_p5_dur[$i]=0; pod_rx_p5_dur[$i]=0
        
        for nic_idx in $(seq 0 7); do
            local array_idx=$((i * 8 + nic_idx))
            
            if [ "${before_tx_prio0_pause[$array_idx]}" == "-1" ] || [ "${after_tx_prio0_pause[$array_idx]}" == "-1" ]; then
                continue
            fi
            
            pod_tx_p0[$i]=$((${pod_tx_p0[$i]} + ${after_tx_prio0_pause[$array_idx]:-0} - ${before_tx_prio0_pause[$array_idx]:-0}))
            pod_rx_p0[$i]=$((${pod_rx_p0[$i]} + ${after_rx_prio0_pause[$array_idx]:-0} - ${before_rx_prio0_pause[$array_idx]:-0}))
            pod_tx_p5[$i]=$((${pod_tx_p5[$i]} + ${after_tx_prio5_pause[$array_idx]:-0} - ${before_tx_prio5_pause[$array_idx]:-0}))
            pod_rx_p5[$i]=$((${pod_rx_p5[$i]} + ${after_rx_prio5_pause[$array_idx]:-0} - ${before_rx_prio5_pause[$array_idx]:-0}))
            pod_tx_p0_dur[$i]=$((${pod_tx_p0_dur[$i]} + ${after_tx_prio0_pause_duration[$array_idx]:-0} - ${before_tx_prio0_pause_duration[$array_idx]:-0}))
            pod_rx_p0_dur[$i]=$((${pod_rx_p0_dur[$i]} + ${after_rx_prio0_pause_duration[$array_idx]:-0} - ${before_rx_prio0_pause_duration[$array_idx]:-0}))
            pod_tx_p5_dur[$i]=$((${pod_tx_p5_dur[$i]} + ${after_tx_prio5_pause_duration[$array_idx]:-0} - ${before_tx_prio5_pause_duration[$array_idx]:-0}))
            pod_rx_p5_dur[$i]=$((${pod_rx_p5_dur[$i]} + ${after_rx_prio5_pause_duration[$array_idx]:-0} - ${before_rx_prio5_pause_duration[$array_idx]:-0}))
        done
        
        total_tx_p0=$((total_tx_p0 + ${pod_tx_p0[$i]}))
        total_rx_p0=$((total_rx_p0 + ${pod_rx_p0[$i]}))
        total_tx_p5=$((total_tx_p5 + ${pod_tx_p5[$i]}))
        total_rx_p5=$((total_rx_p5 + ${pod_rx_p5[$i]}))
        total_tx_p0_dur=$((total_tx_p0_dur + ${pod_tx_p0_dur[$i]}))
        total_rx_p0_dur=$((total_rx_p0_dur + ${pod_rx_p0_dur[$i]}))
        total_tx_p5_dur=$((total_tx_p5_dur + ${pod_tx_p5_dur[$i]}))
        total_rx_p5_dur=$((total_rx_p5_dur + ${pod_rx_p5_dur[$i]}))
    done
    
    # Main heading: SUMMARY - PFC Counters
    echo ""
    echo "=============================================================================="
    echo "SUMMARY: PFC Counters (Priorities 0 and 5)"
    echo "=============================================================================="
    
    # Sub-heading: Pause Counts
    echo ""
    echo "Pause Counts:"
    printf "%-${POD_NAME_WIDTH}s %-18s %-18s %-18s %-18s\n" \
           "POD" "tx_prio0_pause" "rx_prio0_pause" "tx_prio5_pause" "rx_prio5_pause"
    printf "%-${POD_NAME_WIDTH}s %-18s %-18s %-18s %-18s\n" \
           "$(printf '%0.s-' $(seq 1 $POD_NAME_WIDTH))" "------------------" "------------------" "------------------" "------------------"
    
    for i in "${!pods_ref[@]}"; do
        printf "%-${POD_NAME_WIDTH}s %-18d %-18d %-18d %-18d\n" \
               "${pods_ref[$i]}" "${pod_tx_p0[$i]}" "${pod_rx_p0[$i]}" "${pod_tx_p5[$i]}" "${pod_rx_p5[$i]}"
    done
    printf "%-${POD_NAME_WIDTH}s %-18s %-18s %-18s %-18s\n" \
           "$(printf '%0.s-' $(seq 1 $POD_NAME_WIDTH))" "------------------" "------------------" "------------------" "------------------"
    printf "%-${POD_NAME_WIDTH}s %-18d %-18d %-18d %-18d\n" \
           "TOTAL" "$total_tx_p0" "$total_rx_p0" "$total_tx_p5" "$total_rx_p5"
    
    # Sub-heading: Pause Durations
    echo ""
    echo "Pause Durations:"
    printf "%-${POD_NAME_WIDTH}s %-26s %-26s %-26s %-26s\n" \
           "POD" "tx_prio0_pause_duration" "rx_prio0_pause_duration" "tx_prio5_pause_duration" "rx_prio5_pause_duration"
    printf "%-${POD_NAME_WIDTH}s %-26s %-26s %-26s %-26s\n" \
           "$(printf '%0.s-' $(seq 1 $POD_NAME_WIDTH))" "--------------------------" "--------------------------" "--------------------------" "--------------------------"
    
    for i in "${!pods_ref[@]}"; do
        printf "%-${POD_NAME_WIDTH}s %-26d %-26d %-26d %-26d\n" \
               "${pods_ref[$i]}" "${pod_tx_p0_dur[$i]}" "${pod_rx_p0_dur[$i]}" "${pod_tx_p5_dur[$i]}" "${pod_rx_p5_dur[$i]}"
    done
    printf "%-${POD_NAME_WIDTH}s %-26s %-26s %-26s %-26s\n" \
           "$(printf '%0.s-' $(seq 1 $POD_NAME_WIDTH))" "--------------------------" "--------------------------" "--------------------------" "--------------------------"
    printf "%-${POD_NAME_WIDTH}s %-26d %-26d %-26d %-26d\n" \
           "TOTAL" "$total_tx_p0_dur" "$total_rx_p0_dur" "$total_tx_p5_dur" "$total_rx_p5_dur"
}

# ============================================
# Function to print ECN counter summary
# Arguments: $1=pod_names_array_ref
# ============================================
print_ecn_summary() {
    local -n pods_ref=$1
    
    # Main heading: SUMMARY - ECN Counters (no sub-headings)
    echo ""
    echo "=============================================================================="
    echo "SUMMARY: ECN Counters"
    echo "=============================================================================="
    printf "%-${POD_NAME_WIDTH}s %-28s %-18s %-18s\n" "POD" "np_ecn_marked_roce_packets" "np_cnp_sent" "rp_cnp_handled"
    printf "%-${POD_NAME_WIDTH}s %-28s %-18s %-18s\n" "$(printf '%0.s-' $(seq 1 $POD_NAME_WIDTH))" "----------------------------" "------------------" "------------------"
    
    local total_ecn=0 total_cnp_sent=0 total_cnp_handled=0
    
    for i in "${!pods_ref[@]}"; do
        local ecn_diff=$((${after_ecn_marked[$i]:-0} - ${before_ecn_marked[$i]:-0}))
        local cnp_sent_diff=$((${after_cnp_sent[$i]:-0} - ${before_cnp_sent[$i]:-0}))
        local cnp_handled_diff=$((${after_cnp_handled[$i]:-0} - ${before_cnp_handled[$i]:-0}))
        
        total_ecn=$((total_ecn + ecn_diff))
        total_cnp_sent=$((total_cnp_sent + cnp_sent_diff))
        total_cnp_handled=$((total_cnp_handled + cnp_handled_diff))
        
        printf "%-${POD_NAME_WIDTH}s %-28d %-18d %-18d\n" "${pods_ref[$i]}" "$ecn_diff" "$cnp_sent_diff" "$cnp_handled_diff"
    done
    
    printf "%-${POD_NAME_WIDTH}s %-28s %-18s %-18s\n" "$(printf '%0.s-' $(seq 1 $POD_NAME_WIDTH))" "----------------------------" "------------------" "------------------"
    printf "%-${POD_NAME_WIDTH}s %-28d %-18d %-18d\n" "TOTAL" "$total_ecn" "$total_cnp_sent" "$total_cnp_handled"
}

# ============================================
# Function to print all summaries
# Arguments: $1=pod_names_array_ref
# ============================================
print_all_summaries() {
    print_priority_packet_summary "$1"
    print_pfc_pause_summary "$1"
    print_ecn_summary "$1"
}

# ============================================
# Function to print final notes
# ============================================
print_final_notes() {
    echo ""
    echo "=============================================="
    echo "Notes:"
    echo "=============================================="
    echo "- PFC is enabled for priorities 0 and 5"
    echo "- ECN counters: ecn_marked=packets marked by network, cnp_sent/handled=congestion notifications"
    echo "- PFC pause_duration: cumulative time paused (in device-specific units, often μs)"
    if [ "${skipped_nics:-0}" -gt 0 ]; then
        echo "- WARNING: $skipped_nics NIC(s) had data fetch failures and were excluded from totals"
    fi
}
