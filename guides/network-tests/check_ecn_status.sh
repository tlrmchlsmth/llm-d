#!/bin/bash

# check_ecn_status.sh - Check if ECN is enabled on a RoCE NIC
# Usage: ./check_ecn_status.sh <interface_name>
# Example: ./check_ecn_status.sh rdma0

set -e

if [ $# -lt 1 ]; then
    echo "Usage: $0 <interface_name>"
    echo "Example: $0 rdma0"
    exit 1
fi

IFACE=$1

echo ""
echo "=============================================="
echo "ECN Status Check for Interface: $IFACE"
echo "=============================================="

# Check if interface exists
if [ ! -d "/sys/class/net/$IFACE" ]; then
    echo "ERROR: Interface $IFACE not found"
    exit 1
fi

# Find the associated mlx5 InfiniBand device
MLX5_DEV=""
for dev in /sys/class/infiniband/mlx5_*; do
    if [ -d "$dev" ]; then
        dev_name=$(basename "$dev")
        # Check if this mlx5 device is associated with our interface
        net_dev=$(ls "$dev/device/net/" 2>/dev/null | head -1)
        if [ "$net_dev" == "$IFACE" ]; then
            MLX5_DEV=$dev_name
            break
        fi
    fi
done

if [ -z "$MLX5_DEV" ]; then
    echo "WARNING: Could not find mlx5 device for $IFACE"
    echo "         Attempting to find via PCI device..."
    # Try alternative method
    PCI_PATH=$(readlink -f /sys/class/net/$IFACE/device 2>/dev/null)
    if [ -n "$PCI_PATH" ]; then
        MLX5_DEV=$(ls "$PCI_PATH/infiniband/" 2>/dev/null | head -1)
    fi
fi

echo ""
echo "Interface: $IFACE"
echo "MLX5 Device: ${MLX5_DEV:-Not Found}"

# ============================================
# Section 1: ECN Configuration
# ============================================
echo ""
echo "----------------------------------------------"
echo "1. ECN CONFIGURATION"
echo "----------------------------------------------"

ECN_PATH="/sys/class/net/$IFACE/ecn"

if [ -d "$ECN_PATH" ]; then
    echo "ECN sysfs path found: $ECN_PATH"
    echo ""
    
    # RoCE NP (Notification Point) - Receiver side
    echo "  RoCE NP (Notification Point - Receiver):"
    NP_PATH="$ECN_PATH/roce_np"
    if [ -d "$NP_PATH" ]; then
        for param in enable cnp_dscp cnp_802p_prio min_time_between_cnps cnp_prio_mode; do
            val=$(cat "$NP_PATH/$param" 2>/dev/null || echo "N/A")
            printf "    %-30s: %s\n" "$param" "$val"
        done
    else
        echo "    (roce_np directory not found)"
    fi
    
    echo ""
    
    # RoCE RP (Reaction Point) - Sender side
    echo "  RoCE RP (Reaction Point - Sender):"
    RP_PATH="$ECN_PATH/roce_rp"
    if [ -d "$RP_PATH" ]; then
        for param in enable clamp_tgt_rate clamp_tgt_rate_after_time_inc rate_reduce_monitor_period \
                     initial_alpha_value rate_to_set_on_first_cnp dce_tcp_g dce_tcp_rtt; do
            val=$(cat "$RP_PATH/$param" 2>/dev/null || echo "N/A")
            printf "    %-35s: %s\n" "$param" "$val"
        done
    else
        echo "    (roce_rp directory not found)"
    fi
else
    echo "WARNING: ECN sysfs path not found at $ECN_PATH"
fi

# ============================================
# Section 2: ECN Hardware Counters
# ============================================
echo ""
echo "----------------------------------------------"
echo "2. ECN HARDWARE COUNTERS"
echo "----------------------------------------------"

if [ -n "$MLX5_DEV" ]; then
    HW_COUNTERS="/sys/class/infiniband/$MLX5_DEV/ports/1/hw_counters"
    
    if [ -d "$HW_COUNTERS" ]; then
        echo "Reading from: $HW_COUNTERS"
        echo ""
        
        # ECN-related counters
        declare -A counter_desc=(
            ["np_ecn_marked_roce_packets"]="RoCE packets received with ECN CE marking"
            ["np_cnp_sent"]="CNP packets sent (congestion notifications)"
            ["rp_cnp_handled"]="CNP packets received and handled"
            ["rp_cnp_ignored"]="CNP packets received but ignored"
            ["roce_slow_restart_cnps"]="Slow restart events triggered by CNP"
        )
        
        echo "  Counter                              Value         Description"
        echo "  ------------------------------------ ------------- ----------------------------------------"
        
        total_ecn_activity=0
        for counter in np_ecn_marked_roce_packets np_cnp_sent rp_cnp_handled rp_cnp_ignored roce_slow_restart_cnps; do
            val=$(cat "$HW_COUNTERS/$counter" 2>/dev/null || echo "0")
            desc="${counter_desc[$counter]:-""}"
            printf "  %-36s %13s   %s\n" "$counter" "$val" "$desc"
            if [ "$val" != "0" ] && [ "$val" != "N/A" ]; then
                total_ecn_activity=$((total_ecn_activity + val))
            fi
        done
    else
        echo "WARNING: Hardware counters not found at $HW_COUNTERS"
    fi
else
    echo "WARNING: Cannot read hardware counters - mlx5 device not found"
fi

# ============================================
# Section 3: ethtool ECN counters
# ============================================
echo ""
echo "----------------------------------------------"
echo "3. ETHTOOL ECN COUNTERS"
echo "----------------------------------------------"

ethtool_ecn=$(ethtool -S "$IFACE" 2>/dev/null | grep -iE "ecn|cnp" | head -10)
if [ -n "$ethtool_ecn" ]; then
    echo "$ethtool_ecn"
else
    echo "  No ECN counters found in ethtool -S output"
fi

# ============================================
# Section 4: QoS/Trust Configuration
# ============================================
echo ""
echo "----------------------------------------------"
echo "4. QOS TRUST CONFIGURATION"
echo "----------------------------------------------"

mlnx_qos_output=$(mlnx_qos -i "$IFACE" 2>/dev/null)
if [ -n "$mlnx_qos_output" ]; then
    echo "$mlnx_qos_output" | grep -E "trust|dscp2prio|DSCP" | head -10
else
    echo "  mlnx_qos not available or failed"
fi

# ============================================
# Section 5: ECN Status Summary
# ============================================
echo ""
echo "=============================================="
echo "ECN STATUS SUMMARY"
echo "=============================================="

# Determine ECN status based on evidence
ecn_enabled="UNKNOWN"
ecn_evidence=""

# Check 1: Hardware counters show ECN activity
if [ -n "$MLX5_DEV" ]; then
    ecn_marked=$(cat "/sys/class/infiniband/$MLX5_DEV/ports/1/hw_counters/np_ecn_marked_roce_packets" 2>/dev/null || echo "0")
    cnp_sent=$(cat "/sys/class/infiniband/$MLX5_DEV/ports/1/hw_counters/np_cnp_sent" 2>/dev/null || echo "0")
    cnp_handled=$(cat "/sys/class/infiniband/$MLX5_DEV/ports/1/hw_counters/rp_cnp_handled" 2>/dev/null || echo "0")
    
    if [ "$ecn_marked" -gt 0 ] 2>/dev/null || [ "$cnp_sent" -gt 0 ] 2>/dev/null || [ "$cnp_handled" -gt 0 ] 2>/dev/null; then
        ecn_enabled="YES"
        ecn_evidence="Hardware counters show ECN/CNP activity"
    fi
fi

# Check 2: ECN sysfs exists
if [ -d "/sys/class/net/$IFACE/ecn" ]; then
    if [ "$ecn_enabled" == "UNKNOWN" ]; then
        ecn_enabled="LIKELY"
        ecn_evidence="ECN sysfs configuration exists"
    fi
fi

echo ""
case $ecn_enabled in
    "YES")
        echo "  ✓ ECN IS ENABLED AND ACTIVE"
        echo ""
        echo "  Evidence:"
        echo "    - $ecn_evidence"
        echo "    - ECN-marked packets received: $ecn_marked"
        echo "    - CNP packets sent: $cnp_sent"
        echo "    - CNP packets handled: $cnp_handled"
        echo ""
        echo "  This means:"
        echo "    - Traffic IS being sent with ECN capability bits set (ECT)"
        echo "    - Network switches ARE marking packets during congestion (ECN CE)"
        echo "    - Endpoints ARE exchanging CNP for DCQCN congestion control"
        ;;
    "LIKELY")
        echo "  ~ ECN LIKELY ENABLED (but no activity observed yet)"
        echo ""
        echo "  Evidence:"
        echo "    - $ecn_evidence"
        echo "    - No ECN-marked packets or CNPs observed (traffic may be idle)"
        echo ""
        echo "  Run traffic and check again to confirm ECN is working."
        ;;
    *)
        echo "  ? ECN STATUS UNKNOWN"
        echo ""
        echo "  Could not determine ECN status. Possible reasons:"
        echo "    - Interface is not a Mellanox/NVIDIA NIC"
        echo "    - Driver doesn't expose ECN counters"
        echo "    - ECN may be disabled"
        ;;
esac

echo ""
echo "=============================================="
