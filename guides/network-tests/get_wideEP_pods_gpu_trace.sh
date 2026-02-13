#!/bin/bash
# Capture GPU state and (optionally) kernel/HIP trace from wide-ep decode pods when hung.
# Use this to get "smoking gun" evidence that the GPU is stuck in a collective or kernel.
#
# When decode pods are hung:
#   1. rocm-smi: GPU utilization (0% = GPU idle/waiting, e.g. on NCCL; 100% = kernel running).
#   2. rocprofv3 attach: short kernel/HIP trace to see last dispatched kernels or idle queues.
#
# Requirements:
#   - ROCm in the pod (rocm-smi, optionally /opt/rocm/bin/rocprofv3).
#   - For rocprofv3 attach: container must have SYS_PTRACE (add to securityContext if needed).
#
# Usage: ./get_wideEP_pods_gpu_trace.sh [namespace] [attach_seconds]
#   namespace: e.g. varun-llm-d-wide-ep (default from kubectl context).
#   attach_seconds: how long to attach rocprofv3 (default 10). Use 0 to skip rocprofv3.
#
# Output: results/gpu_trace_<pod>.txt (rocm-smi + optional rocprofv3 CSV snippets).

set -e

NAMESPACE="${1:-$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null)}"
ATTACH_SEC="${2:-10}"

if [ -z "$NAMESPACE" ]; then
    echo "Usage: $0 <namespace> [attach_seconds]"
    echo "Example: $0 varun-llm-d-wide-ep 10"
    exit 1
fi

echo "Using namespace: $NAMESPACE  attach_seconds: $ATTACH_SEC"
echo ""

decode_pods=()
while IFS= read -r name; do
    [ -z "$name" ] && continue
    decode_pods+=("$name")
done < <(kubectl get pods -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep "^wide-ep-llm-d-decode")

if [ ${#decode_pods[@]} -eq 0 ]; then
    echo "No wide-ep-llm-d-decode* pods found in namespace $NAMESPACE"
    exit 1
fi

echo "Found ${#decode_pods[@]} decode pod(s): ${decode_pods[*]}"
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/results"
mkdir -p "$OUTPUT_DIR"

run_gpu_trace_for_pod() {
    local pod="$1"
    local safe_name="${pod//[^a-zA-Z0-9_-]/_}"
    local out_file="${OUTPUT_DIR}/gpu_trace_${safe_name}.txt"
    local attach_msec=$((ATTACH_SEC * 1000))

    echo "=============================================="
    echo "Pod: $pod -> $out_file"
    echo "=============================================="

    kubectl exec -n "$NAMESPACE" "$pod" -- bash -c "
        set -e
        export PATH=\${PATH}:/opt/rocm/bin

        echo '=== rocm-smi (GPU utilization, memory, etc.) ==='
        rocm-smi 2>&1 || true
        echo ''
        echo '=== rocm-smi --showuse (utilization) ==='
        rocm-smi --showuse 2>&1 || true
        echo ''
        echo '=== rocm-smi --showpids (processes using GPU) ==='
        rocm-smi --showpids 2>&1 || true
        echo ''

        pids=\$(ps aux | grep -E 'EngineCore_DP[0-9]' | grep -v grep | awk '{print \$2}' | head -1)
        if [ -z \"\$pids\" ]; then
            echo 'No EngineCore PIDs found; skipping rocprofv3.'
            exit 0
        fi
        pid=\$(echo \"\$pids\" | head -1)
        echo \"=== Using first EngineCore PID for attach: \$pid ===\"
        echo ''

        if [ '$attach_msec' -le 0 ]; then
            echo 'attach_seconds=0: skipping rocprofv3.'
            exit 0
        fi

        if ! command -v rocprofv3 &>/dev/null; then
            echo 'rocprofv3 not found (e.g. not in PATH or /opt/rocm/bin). Skip kernel trace.'
            echo 'If attach fails, ensure container has SYS_PTRACE capability.'
            exit 0
        fi

        echo \"=== rocprofv3 attach to PID \$pid for ${ATTACH_SEC}s (kernel + HIP trace) ===\"
        rp_dir=\"/tmp/rocprof_attach\"
        mkdir -p \"\$rp_dir\"
        cd /tmp
        if rocprofv3 --attach \"\$pid\" --attach-duration-msec $attach_msec --sys-trace -d \"\$rp_dir\" --output-format csv 2>&1; then
            echo ''
            echo '=== rocprofv3 output: find all files (tool may write to subdirs, e.g. hostname/pid) ==='
            find \"\$rp_dir\" /tmp -maxdepth 4 -type f \\( -name '*.csv' -o -name '*.db' -o -name '*trace*' \\) 2>/dev/null | head -50
            echo ''
            echo '=== listing \$rp_dir recursively ==='
            ls -laR \"\$rp_dir\" 2>/dev/null || true
            echo ''
            echo '=== rocprofv3 kernel_trace (any *kernel*.csv under \$rp_dir) ==='
            find \"\$rp_dir\" -name '*kernel*.csv' -type f 2>/dev/null | while read -r f; do echo \"--- \$f ---\"; head -100 \"\$f\"; done
            echo ''
            echo '=== rocprofv3 hip_api_trace (any *hip*.csv under \$rp_dir) ==='
            find \"\$rp_dir\" -name '*hip*.csv' -type f 2>/dev/null | while read -r f; do echo \"--- \$f ---\"; tail -80 \"\$f\"; done
            echo ''
            echo '=== any CSV in \$rp_dir (first 50 lines each) ==='
            find \"\$rp_dir\" -name '*.csv' -type f 2>/dev/null | while read -r f; do echo \"--- \$f ---\"; head -50 \"\$f\"; done
        else
            echo 'rocprofv3 attach failed (e.g. need SYS_PTRACE or same user).'
        fi
        rm -rf \"\$rp_dir\"
    " > "$out_file" 2>&1

    echo "  Written: $out_file"
    echo ""
}

for pod in "${decode_pods[@]}"; do
    run_gpu_trace_for_pod "$pod"
done

echo "=============================================="
echo "Interpretation (when decode is hung):"
echo "  - rocm-smi GPU use 0% + process running => GPU likely waiting (e.g. NCCL collective)."
echo "  - rocprofv3 kernel_trace: last Kernel_Name shows what was running or stuck."
echo "  - rocprofv3 hip_api_trace: look for hipStreamSynchronize / hipDeviceSynchronize (sync points)."
echo "=============================================="
