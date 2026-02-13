# GPU trace for wide-ep decode hang (smoking gun)

When decode pods are **hung** (e.g. stuck at `paged_kv_indices = block_table_tensor[mask]` in Python while the real hang is GPU-side), use this to get evidence of what the GPU is doing.

## Quick run

```bash
# From guides/network-tests (or pass namespace)
./get_wideEP_pods_gpu_trace.sh varun-llm-d-wide-ep 10
```

Output: `results/gpu_trace_wide-ep-llm-d-decode-0.txt` (and `-0-1.txt` if present).

- **First argument**: Kubernetes namespace (default from `kubectl config`).
- **Second argument**: How many seconds to attach `rocprofv3` to one EngineCore process (default 10). Use `0` to skip rocprofv3 and only collect `rocm-smi`.

## What it captures

1. **rocm-smi**  
   - GPU utilization: **0%** while the process is “stuck” → GPU is likely **idle/waiting** (e.g. on an NCCL collective or barrier).  
   - **High %** → some kernel is running (could be a long kernel or one stuck in a loop).

2. **rocm-smi --showpids**  
   - Which PIDs are using the GPU (should include the EngineCore PIDs).

3. **rocprofv3 attach** (if available and `attach_seconds` > 0)  
   - Attaches to the **first** EngineCore PID for the chosen duration.  
   - `--sys-trace`: HIP API + kernel dispatches.  
   - **kernel_trace CSV**: last kernel names (e.g. `nccl*`, `rccl*`, or vLLM kernels).  
   - **hip_api_trace CSV**: last HIP calls; look for `hipStreamSynchronize` / `hipDeviceSynchronize` (sync points where the CPU blocks on the GPU).

## How to interpret (when decode is hung)

| Observation | Likely meaning |
|-------------|----------------|
| GPU use **0%** + process running | GPU waiting (e.g. NCCL/RCCL collective or barrier); CPU blocked on a later sync. |
| **kernel_trace** shows an NCCL/rccl kernel with no End_Timestamp or very long duration | That kernel (collective) is stuck. |
| **hip_api_trace** shows long `hipStreamSynchronize` / `hipDeviceSynchronize` | CPU is blocked on GPU completion; GPU may be stuck in a kernel/collective. |

## Empty rocprofv3 output

If attach succeeds but **no CSV files** appear (or the script shows no kernel/HIP trace):

1. **Output location**: rocprofv3 may write under a subdir (e.g. `hostname/` or `pid/`) inside the requested `-d` directory. The script now runs `find` and `ls -laR` so any files under `/tmp/rocprof_attach` or `/tmp` are listed.
2. **No events during attach**: If the process is **stuck** (e.g. GPU in a kernel that never completes, CPU blocked), no *new* HIP or kernel events may occur during the attach window, so the tool may write no or empty files. That itself is evidence: **100% GPU use + no new dispatches in 10–15 s** ⇒ likely stuck in a long-running or spinning kernel.
3. **Try rocpd format**: Some builds write more reliably in rocpd (SQLite) form. To try manually:
   ```bash
   rocprofv3 --attach <PID> --attach-duration-msec 15000 --sys-trace -d /tmp/rocprof_attach --output-format rocpd
   find /tmp/rocprof_attach /tmp -name '*.db' -o -name '*.csv' 2>/dev/null
   ```

## Requirements

- **ROCm** in the pod: `rocm-smi` (and ideally `rocprofv3` in `PATH` or `/opt/rocm/bin`).
- **rocprofv3 attach**: Uses `ptrace`. If attach fails with a permission error, add to the **decode** (and prefill if you trace them) pod’s securityContext:
  ```yaml
          securityContext:
            capabilities:
              add:
              - SYS_PTRACE
  ```
  (Your decode pod may already be `privileged: true`, which usually allows ptrace; if not, add `SYS_PTRACE`.)

## Optional: attach longer or only one pod

```bash
# Attach for 30 seconds
./get_wideEP_pods_gpu_trace.sh varun-llm-d-wide-ep 30

# Only rocm-smi (no rocprofv3)
./get_wideEP_pods_gpu_trace.sh varun-llm-d-wide-ep 0
```

To trace a single pod, you can run the same `kubectl exec` block from the script manually, targeting that pod and PID.
