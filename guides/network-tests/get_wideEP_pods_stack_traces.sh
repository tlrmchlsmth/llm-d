#!/bin/bash
# Get stack traces from EngineCore processes in wide-ep decode and prefill pods.
# Usage: ./get_wideEP_pods_stack_traces.sh [namespace]
# If namespace is omitted, uses the current kubectl context namespace.

set -e

NAMESPACE="${1:-$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null)}"
if [ -z "$NAMESPACE" ]; then
    echo "Usage: $0 <namespace>"
    echo "Example: $0 varun-llm-d-wide-ep"
    exit 1
fi

echo "Using namespace: $NAMESPACE"
echo ""

# Find decode pods
decode_pods=()
while IFS= read -r name; do
    [ -z "$name" ] && continue
    decode_pods+=("$name")
done < <(kubectl get pods -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep "^wide-ep-llm-d-decode")

# Find prefill pods
prefill_pods=()
while IFS= read -r name; do
    [ -z "$name" ] && continue
    prefill_pods+=("$name")
done < <(kubectl get pods -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep "^wide-ep-llm-d-prefill")

if [ ${#decode_pods[@]} -eq 0 ] && [ ${#prefill_pods[@]} -eq 0 ]; then
    echo "No wide-ep-llm-d-decode* or wide-ep-llm-d-prefill* pods found in namespace $NAMESPACE"
    exit 1
fi

echo "Found ${#decode_pods[@]} decode pod(s): ${decode_pods[*]}"
echo "Found ${#prefill_pods[@]} prefill pod(s): ${prefill_pods[*]}"
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/results"
mkdir -p "$OUTPUT_DIR"

output_files=()

run_pystack_for_pod() {
    local pod="$1"
    local safe_name="${pod//[^a-zA-Z0-9_-]/_}"
    local out_file="${OUTPUT_DIR}/wideep_stack_trace_${safe_name}.txt"
    output_files+=("$out_file")

    echo "=============================================="
    echo "Pod: $pod -> $out_file"
    echo "=============================================="

    kubectl exec -n "$NAMESPACE" "$pod" -- bash -c '
        set -e
        echo "=== pip install pystack ==="
        pip install pystack -q 2>/dev/null || pip install pystack
        echo ""
        echo "=== ps aux (EngineCore processes) ==="
        ps aux | grep -E "EngineCore_DP" || true
        echo ""
        pids=$(ps aux | grep -E "EngineCore_DP[0-9]" | grep -v grep | awk "{print \$2}")
        if [ -z "$pids" ]; then
            echo "No EngineCore PIDs found."
            exit 0
        fi
        for pid in $pids; do
            echo "=== pystack remote $pid ==="
            pystack remote "$pid" 2>&1 || true
            echo ""
        done
    ' > "$out_file" 2>&1

    echo "  Written: $out_file"
    echo ""
}

for pod in "${decode_pods[@]}"; do
    run_pystack_for_pod "$pod"
done

for pod in "${prefill_pods[@]}"; do
    run_pystack_for_pod "$pod"
done

echo "=============================================="
echo "Output files:"
echo "=============================================="
for f in "${output_files[@]}"; do
    echo "  $f"
done
