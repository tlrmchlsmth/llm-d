#!/bin/bash
# Download /var/log/vllm/nccl_debug.txt from all wide-ep decode and prefill pods.
# Usage: ./get_nccl_debug_logs.sh [namespace]
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
all_pods=("${decode_pods[@]}" "${prefill_pods[@]}")

echo "=============================================="
echo "Downloading nccl_debug.txt from all pods"
echo "=============================================="
for pod in "${all_pods[@]}"; do
    safe_name="${pod//[^a-zA-Z0-9_-]/_}"
    out_file="${OUTPUT_DIR}/nccl_debug_${safe_name}.txt"
    echo -n "  $pod -> $out_file ... "
    if kubectl exec -n "$NAMESPACE" "$pod" -- cat /var/log/vllm/nccl_debug.txt > "$out_file" 2>/dev/null; then
        echo "ok"
        output_files+=("$out_file")
    else
        echo "failed (file may not exist)"
        rm -f "$out_file"
    fi
done
echo ""

echo "=============================================="
echo "Output files:"
echo "=============================================="
for f in "${output_files[@]}"; do
    echo "  $f"
done
