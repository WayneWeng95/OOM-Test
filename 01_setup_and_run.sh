#!/bin/bash
# ============================================================================
# OOM Killer Determinism Experiment
# ============================================================================
#
# GOAL: Prove that given the same memory state, the OOM killer always picks
#       the same victim process.
#
# APPROACH:
#   1. Create a memory cgroup with a hard limit (e.g., 200MB)
#   2. Spawn N worker processes inside it, each consuming a known amount of RAM
#   3. Spawn a "trigger" process that pushes memory over the limit
#   4. Record which PID/worker gets killed
#   5. Repeat multiple times and compare results
#
# REQUIRES: root, cgroups v2 (most modern distros), Linux 4.19+
# ============================================================================

set -euo pipefail

# --- Configuration ---
CGROUP_NAME="oom_experiment"
CGROUP_PATH="/sys/fs/cgroup/${CGROUP_NAME}"
MEM_LIMIT="200M"           # Total memory budget for the cgroup
NUM_TRIALS=10               # How many times to repeat the experiment
LOG_DIR="./results"
WORKER_BINARY="./mem_worker"

# Worker definitions: name and memory allocation in MB
# Deliberately different sizes so the OOM killer has a clear "worst" candidate
declare -A WORKERS
WORKERS=(
    ["small"]=20        # 20 MB
    ["medium"]=50       # 50 MB
    ["large"]=80        # 80 MB - expected victim (highest RSS)
)
TRIGGER_MB=100              # The trigger process allocates this much to push over

# --- Preflight checks ---
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (for cgroup manipulation)."
    exit 1
fi

if [[ ! -f "$WORKER_BINARY" ]]; then
    echo "ERROR: Worker binary not found. Compile it first:"
    echo "  gcc -o mem_worker mem_worker.c"
    exit 1
fi

# Check cgroups v2
if ! mount | grep -q "cgroup2"; then
    echo "ERROR: cgroups v2 not mounted. This experiment requires cgroups v2."
    exit 1
fi

# --- Functions ---

cleanup() {
    echo "[cleanup] Removing cgroup and killing stragglers..."

    # Kill anything still in the cgroup
    if [[ -f "${CGROUP_PATH}/cgroup.procs" ]]; then
        while read -r pid; do
            kill -9 "$pid" 2>/dev/null || true
        done < "${CGROUP_PATH}/cgroup.procs"
        sleep 1
    fi

    # Remove the cgroup
    rmdir "${CGROUP_PATH}" 2>/dev/null || true
    echo "[cleanup] Done."
}

setup_cgroup() {
    # Clean up from any previous run
    cleanup 2>/dev/null || true

    echo "[setup] Creating cgroup: ${CGROUP_PATH}"
    mkdir -p "${CGROUP_PATH}"

    # Enable memory controller
    echo "+memory" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true

    # Set memory limit
    echo "${MEM_LIMIT}" > "${CGROUP_PATH}/memory.max"

    # Disable swap to make behavior more predictable
    echo "0" > "${CGROUP_PATH}/memory.swap.max" 2>/dev/null || true

    echo "[setup] Memory limit set to ${MEM_LIMIT}, swap disabled."
}

run_single_trial() {
    local trial_num=$1
    local result_file="${LOG_DIR}/trial_${trial_num}.log"

    echo ""
    echo "========================================"
    echo " Trial ${trial_num} / ${NUM_TRIALS}"
    echo "========================================"

    setup_cgroup

    declare -A WORKER_PIDS

    # Spawn workers inside the cgroup
    for name in "${!WORKERS[@]}"; do
        local mb=${WORKERS[$name]}
        ${WORKER_BINARY} "${name}" "${mb}" &
        local pid=$!

        # Move process into our cgroup
        echo "$pid" > "${CGROUP_PATH}/cgroup.procs"

        WORKER_PIDS[$name]=$pid
        echo "[spawn] Worker '${name}': PID=${pid}, allocating ${mb}MB"
    done

    # Give workers time to allocate and stabilize
    sleep 2

    # Record memory state before trigger
    echo "[state] Memory usage before trigger:"
    cat "${CGROUP_PATH}/memory.current"

    # Record per-process OOM scores
    echo "[scores] OOM scores before trigger:"
    for name in "${!WORKER_PIDS[@]}"; do
        local pid=${WORKER_PIDS[$name]}
        if [[ -f "/proc/${pid}/oom_score" ]]; then
            local score=$(cat "/proc/${pid}/oom_score")
            local adj=$(cat "/proc/${pid}/oom_score_adj")
            echo "  ${name} (PID ${pid}): oom_score=${score}, oom_score_adj=${adj}"
        fi
    done

    # Listen for OOM events in the background via dmesg
    local dmesg_before=$(dmesg | wc -l)

    # Launch trigger process inside cgroup
    echo "[trigger] Spawning trigger process (${TRIGGER_MB}MB)..."
    ${WORKER_BINARY} "trigger" "${TRIGGER_MB}" &
    local trigger_pid=$!
    echo "$trigger_pid" > "${CGROUP_PATH}/cgroup.procs"

    WORKER_PIDS["trigger"]=$trigger_pid

    # Wait for OOM to happen
    sleep 5

    # Determine which process(es) got killed
    echo "[result] Checking which processes survived:"
    local killed=""
    for name in "${!WORKER_PIDS[@]}"; do
        local pid=${WORKER_PIDS[$name]}
        if kill -0 "$pid" 2>/dev/null; then
            echo "  ${name} (PID ${pid}): ALIVE"
        else
            echo "  ${name} (PID ${pid}): KILLED"
            killed="${killed}${name}(${pid}) "
        fi
    done

    # Extract OOM killer messages from dmesg
    local oom_log=$(dmesg | tail -n +$((dmesg_before + 1)) | grep -i "oom\|killed\|out of memory" || true)

    # Write trial result
    {
        echo "=== Trial ${trial_num} ==="
        echo "Timestamp: $(date -Iseconds)"
        echo "Workers:"
        for name in "${!WORKERS[@]}"; do
            echo "  ${name}: ${WORKERS[$name]}MB (PID ${WORKER_PIDS[$name]})"
        done
        echo "Trigger: ${TRIGGER_MB}MB (PID ${trigger_pid})"
        echo "Killed: ${killed:-none}"
        echo ""
        echo "Kernel OOM log:"
        echo "${oom_log}"
        echo ""
    } > "${result_file}"

    echo "[result] Killed: ${killed:-none}"
    echo "[result] Saved to ${result_file}"

    # Cleanup for next trial
    cleanup
    sleep 2
}

# --- Main ---
trap cleanup EXIT

mkdir -p "${LOG_DIR}"

echo "============================================="
echo " OOM Killer Determinism Experiment"
echo "============================================="
echo " Memory limit:  ${MEM_LIMIT}"
echo " Workers:       ${!WORKERS[*]}"
echo " Trigger size:  ${TRIGGER_MB}MB"
echo " Trials:        ${NUM_TRIALS}"
echo "============================================="

for i in $(seq 1 ${NUM_TRIALS}); do
    run_single_trial "$i"
done

# --- Summary ---
echo ""
echo "============================================="
echo " Summary"
echo "============================================="

summary_file="${LOG_DIR}/summary.txt"
{
    echo "OOM Killer Determinism Experiment - Summary"
    echo "Date: $(date)"
    echo "Trials: ${NUM_TRIALS}"
    echo "Memory limit: ${MEM_LIMIT}"
    echo ""
    echo "Per-trial results:"
    for i in $(seq 1 ${NUM_TRIALS}); do
        killed=$(grep "^Killed:" "${LOG_DIR}/trial_${i}.log" | sed 's/Killed: //')
        echo "  Trial ${i}: Killed -> ${killed}"
    done
    echo ""

    # Check determinism
    unique_results=$(for i in $(seq 1 ${NUM_TRIALS}); do
        grep "^Killed:" "${LOG_DIR}/trial_${i}.log"
    done | sort -u | wc -l)

    if [[ "$unique_results" -eq 1 ]]; then
        echo "RESULT: DETERMINISTIC - Same process killed in all ${NUM_TRIALS} trials."
    else
        echo "RESULT: NON-DETERMINISTIC - Different processes killed across trials."
        echo "Unique outcomes:"
        for i in $(seq 1 ${NUM_TRIALS}); do
            grep "^Killed:" "${LOG_DIR}/trial_${i}.log"
        done | sort | uniq -c | sort -rn
    fi
} | tee "${summary_file}"

echo ""
echo "Full results saved in ${LOG_DIR}/"
