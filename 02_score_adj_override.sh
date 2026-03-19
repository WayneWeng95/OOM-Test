#!/bin/bash
# ============================================================================
# Experiment 2: Proving oom_score_adj overrides natural selection
# ============================================================================
#
# In experiment 1, the largest process should always be killed.
# Here, we prove that oom_score_adj can override that:
#   - "large" allocates the most memory (normally the victim)
#   - But we set oom_score_adj=-1000 on "large" (protect it)
#   - And set oom_score_adj=+1000 on "small" (make it the target)
#   - The OOM killer should now kill "small" instead
#
# This demonstrates both the determinism and the tunability of the OOM killer.
# ============================================================================

set -euo pipefail

CGROUP_NAME="oom_experiment_adj"
CGROUP_PATH="/sys/fs/cgroup/${CGROUP_NAME}"
MEM_LIMIT="200M"
NUM_TRIALS=5
LOG_DIR="./02_results"
RUN_DIR="${LOG_DIR}/$(date +%Y%m%d_%H%M%S)"
WORKER_BINARY="./mem_worker"

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

run_trial() {
    local trial_num=$1
    local result_file="${RUN_DIR}/trial_adj_${trial_num}.log"

    echo ""
    echo "========================================"
    echo " Trial ${trial_num} / ${NUM_TRIALS}"
    echo "========================================"

    setup_cgroup

    # Spawn workers
    ${WORKER_BINARY} "small" 20 &
    local pid_small=$!
    echo "$pid_small" > "${CGROUP_PATH}/cgroup.procs"
    echo "[spawn] Worker 'small':  PID=${pid_small}, allocating 20MB"

    ${WORKER_BINARY} "medium" 50 &
    local pid_medium=$!
    echo "$pid_medium" > "${CGROUP_PATH}/cgroup.procs"
    echo "[spawn] Worker 'medium': PID=${pid_medium}, allocating 50MB"

    ${WORKER_BINARY} "large" 80 &
    local pid_large=$!
    echo "$pid_large" > "${CGROUP_PATH}/cgroup.procs"
    echo "[spawn] Worker 'large':  PID=${pid_large}, allocating 80MB"

    # Give workers time to allocate and stabilize
    sleep 2

    # Record memory state before adjustments
    echo "[state] Memory usage before trigger:"
    cat "${CGROUP_PATH}/memory.current"

    # HERE'S THE KEY: override the OOM scores
    # Protect the large process (would normally be the victim)
    echo "-1000" > "/proc/${pid_large}/oom_score_adj"
    # Make the small process the preferred target
    echo "1000" > "/proc/${pid_small}/oom_score_adj"

    echo "[adj] small  (PID ${pid_small}):  oom_score_adj=+1000 (TARGETED)"
    echo "[adj] medium (PID ${pid_medium}): oom_score_adj=0     (default)"
    echo "[adj] large  (PID ${pid_large}):  oom_score_adj=-1000 (PROTECTED)"

    # Record per-process OOM scores after adjustment
    echo "[scores] OOM scores after adjustment:"
    for label_pid in "small:${pid_small}" "medium:${pid_medium}" "large:${pid_large}"; do
        local label=${label_pid%%:*}
        local pid=${label_pid##*:}
        if [[ -f "/proc/${pid}/oom_score" ]]; then
            local score=$(cat "/proc/${pid}/oom_score")
            local adj=$(cat "/proc/${pid}/oom_score_adj")
            echo "  ${label} (PID ${pid}): oom_score=${score}, oom_score_adj=${adj}"
        fi
    done

    # Listen for OOM events in the background via dmesg
    local dmesg_before=$(dmesg | wc -l)

    # Trigger OOM
    echo "[trigger] Spawning trigger process (100MB)..."
    ${WORKER_BINARY} "trigger" 100 &
    local pid_trigger=$!
    echo "$pid_trigger" > "${CGROUP_PATH}/cgroup.procs"

    # Wait for OOM to happen
    sleep 5

    # Determine which process(es) got killed
    echo "[result] Checking which processes survived:"
    local killed=""
    for label_pid in "small:${pid_small}" "medium:${pid_medium}" "large:${pid_large}" "trigger:${pid_trigger}"; do
        local label=${label_pid%%:*}
        local pid=${label_pid##*:}
        if kill -0 "$pid" 2>/dev/null; then
            echo "  ${label} (PID ${pid}): ALIVE"
        else
            echo "  ${label} (PID ${pid}): KILLED"
            killed="${killed}${label}(${pid}) "
        fi
    done

    # Extract OOM killer messages from dmesg
    local oom_log=$(dmesg | tail -n +$((dmesg_before + 1)) | grep -i "oom\|killed\|out of memory" || true)

    # Write trial result
    {
        echo "=== Trial ${trial_num} ==="
        echo "Timestamp: $(date -Iseconds)"
        echo "Workers:"
        echo "  small:  20MB (PID ${pid_small},  oom_score_adj=+1000 TARGETED)"
        echo "  medium: 50MB (PID ${pid_medium}, oom_score_adj=0     default)"
        echo "  large:  80MB (PID ${pid_large},  oom_score_adj=-1000 PROTECTED)"
        echo "Trigger: 100MB (PID ${pid_trigger})"
        echo "Killed: ${killed:-none}"
        echo "Expected: small (because oom_score_adj=+1000)"
        echo ""
        echo "Kernel OOM log:"
        echo "${oom_log}"
        echo ""
    } > "${result_file}"

    echo "[result] Killed: ${killed:-none}"
    echo "[result] Expected: small (oom_score_adj=+1000)"
    echo "[result] Saved to ${result_file}"

    cleanup
    sleep 2
}

# --- Main ---
trap cleanup EXIT

mkdir -p "${RUN_DIR}"

echo "============================================="
echo " Experiment 2: oom_score_adj Override Test"
echo "============================================="
echo " Memory limit:  ${MEM_LIMIT}"
echo " Workers:       small (20MB), medium (50MB), large (80MB)"
echo " Trigger size:  100MB"
echo " Trials:        ${NUM_TRIALS}"
echo "---------------------------------------------"
echo " large  (80MB) is PROTECTED  (oom_score_adj=-1000)"
echo " small  (20MB) is TARGETED   (oom_score_adj=+1000)"
echo " Prediction: small should be killed, not large"
echo "============================================="

for i in $(seq 1 ${NUM_TRIALS}); do
    run_trial "$i"
done

# --- Summary ---
echo ""
echo "============================================="
echo " Summary: Did oom_score_adj override size?"
echo "============================================="

summary_file="${RUN_DIR}/summary_adj.txt"
{
    echo "OOM Killer oom_score_adj Override Experiment - Summary"
    echo "Date: $(date)"
    echo "Trials: ${NUM_TRIALS}"
    echo "Memory limit: ${MEM_LIMIT}"
    echo ""
    echo "Per-trial results:"
    for i in $(seq 1 ${NUM_TRIALS}); do
        killed=$(grep "^Killed:" "${RUN_DIR}/trial_adj_${i}.log" | sed 's/Killed: //')
        echo "  Trial ${i}: Killed -> ${killed}"
    done
    echo ""

    # Check if oom_score_adj override worked
    unique_results=$(for i in $(seq 1 ${NUM_TRIALS}); do
        grep "^Killed:" "${RUN_DIR}/trial_adj_${i}.log"
    done | sort -u | wc -l)

    all_small=$(for i in $(seq 1 ${NUM_TRIALS}); do
        grep "^Killed:" "${RUN_DIR}/trial_adj_${i}.log"
    done | grep -c "small" || true)

    if [[ "$all_small" -eq "$NUM_TRIALS" ]]; then
        echo "RESULT: SUCCESS - oom_score_adj override worked. 'small' was killed in all ${NUM_TRIALS} trials despite being the smallest process."
    else
        echo "RESULT: PARTIAL/UNEXPECTED - 'small' was killed in ${all_small}/${NUM_TRIALS} trials."
        echo "Unique outcomes:"
        for i in $(seq 1 ${NUM_TRIALS}); do
            grep "^Killed:" "${RUN_DIR}/trial_adj_${i}.log"
        done | sort | uniq -c | sort -rn
    fi
} | tee "${summary_file}"

echo ""
echo "Full results saved in ${RUN_DIR}/"
