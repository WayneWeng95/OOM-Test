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
LOG_DIR="./results_adj"
WORKER_BINARY="./mem_worker"

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run as root."
    exit 1
fi

if [[ ! -f "$WORKER_BINARY" ]]; then
    echo "ERROR: Compile mem_worker first: gcc -o mem_worker mem_worker.c"
    exit 1
fi

cleanup() {
    if [[ -f "${CGROUP_PATH}/cgroup.procs" ]]; then
        while read -r pid; do
            kill -9 "$pid" 2>/dev/null || true
        done < "${CGROUP_PATH}/cgroup.procs"
        sleep 1
    fi
    rmdir "${CGROUP_PATH}" 2>/dev/null || true
}

setup_cgroup() {
    cleanup 2>/dev/null || true
    mkdir -p "${CGROUP_PATH}"
    echo "+memory" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
    echo "${MEM_LIMIT}" > "${CGROUP_PATH}/memory.max"
    echo "0" > "${CGROUP_PATH}/memory.swap.max" 2>/dev/null || true
}

run_trial() {
    local trial_num=$1
    local result_file="${LOG_DIR}/trial_${trial_num}.log"

    echo ""
    echo "=== Trial ${trial_num} / ${NUM_TRIALS} (with oom_score_adj) ==="

    setup_cgroup

    # Spawn workers
    ${WORKER_BINARY} "small" 20 &
    local pid_small=$!
    echo "$pid_small" > "${CGROUP_PATH}/cgroup.procs"

    ${WORKER_BINARY} "medium" 50 &
    local pid_medium=$!
    echo "$pid_medium" > "${CGROUP_PATH}/cgroup.procs"

    ${WORKER_BINARY} "large" 80 &
    local pid_large=$!
    echo "$pid_large" > "${CGROUP_PATH}/cgroup.procs"

    sleep 2

    # HERE'S THE KEY: override the OOM scores
    # Protect the large process (would normally be the victim)
    echo "-1000" > "/proc/${pid_large}/oom_score_adj"
    # Make the small process the preferred target
    echo "1000" > "/proc/${pid_small}/oom_score_adj"

    echo "[adj] small  (PID ${pid_small}):  oom_score_adj=+1000 (TARGETED)"
    echo "[adj] medium (PID ${pid_medium}): oom_score_adj=0     (default)"
    echo "[adj] large  (PID ${pid_large}):  oom_score_adj=-1000 (PROTECTED)"

    # Record scores
    echo "[scores] After adjustment:"
    for label_pid in "small:${pid_small}" "medium:${pid_medium}" "large:${pid_large}"; do
        local label=${label_pid%%:*}
        local pid=${label_pid##*:}
        if [[ -f "/proc/${pid}/oom_score" ]]; then
            echo "  ${label}: oom_score=$(cat /proc/${pid}/oom_score)"
        fi
    done

    # Trigger OOM
    echo "[trigger] Spawning trigger (100MB)..."
    ${WORKER_BINARY} "trigger" 100 &
    local pid_trigger=$!
    echo "$pid_trigger" > "${CGROUP_PATH}/cgroup.procs"

    sleep 5

    # Check results
    local killed=""
    for label_pid in "small:${pid_small}" "medium:${pid_medium}" "large:${pid_large}" "trigger:${pid_trigger}"; do
        local label=${label_pid%%:*}
        local pid=${label_pid##*:}
        if kill -0 "$pid" 2>/dev/null; then
            echo "  ${label} (PID ${pid}): ALIVE"
        else
            echo "  ${label} (PID ${pid}): KILLED"
            killed="${killed}${label} "
        fi
    done

    {
        echo "Trial ${trial_num}: Killed -> ${killed:-none}"
        echo "  Expected: small (because oom_score_adj=+1000)"
    } | tee "${result_file}"

    cleanup
    sleep 2
}

trap cleanup EXIT
mkdir -p "${LOG_DIR}"

echo "============================================="
echo " Experiment 2: oom_score_adj Override Test"
echo "============================================="
echo " The large process (80MB) is PROTECTED (-1000)"
echo " The small process (20MB) is TARGETED (+1000)"
echo " Prediction: small should be killed, not large"
echo "============================================="

for i in $(seq 1 ${NUM_TRIALS}); do
    run_trial "$i"
done

echo ""
echo "============================================="
echo " Summary: Did oom_score_adj override size?"
echo "============================================="
for i in $(seq 1 ${NUM_TRIALS}); do
    cat "${LOG_DIR}/trial_${i}.log"
done
