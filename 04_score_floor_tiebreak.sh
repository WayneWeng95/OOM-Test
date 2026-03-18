#!/bin/bash
# ============================================================================
# Experiment 4: Score Floor/Ceiling Tiebreak Behavior
# ============================================================================
#
# Explores what happens when multiple processes hit the same adj floor/ceiling:
#
# SCENARIO A — Ceiling tiebreak (+1000 vs +1000):
#   Both "large" (80MB) and "small" (20MB) have oom_score_adj=+1000.
#   Both scores are floored at the ceiling. The kernel must break the tie.
#   Expected: "large" dies first (memory usage is the tiebreaker).
#
# SCENARIO B — Floor protection (-1000) vs forced target (+1000):
#   "huge" (100MB) has oom_score_adj=-1000  → exempt from OOM killing.
#   "tiny"  (10MB) has oom_score_adj=+1000  → always targeted.
#   Despite "tiny" using 10x less memory, it should be killed.
#   "huge" should survive even though it holds the most memory.
#
# ============================================================================

set -euo pipefail

CGROUP_NAME="oom_experiment_floor"
CGROUP_PATH="/sys/fs/cgroup/${CGROUP_NAME}"
MEM_LIMIT="200M"
NUM_TRIALS=3
LOG_DIR="./results"
WORKER_BINARY="./mem_worker"

# --- Preflight checks ---
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Must run as root."
    exit 1
fi

if [[ ! -f "$WORKER_BINARY" ]]; then
    echo "ERROR: Worker binary not found. Compile with: gcc -o mem_worker mem_worker.c"
    exit 1
fi

if ! mount | grep -q "cgroup2"; then
    echo "ERROR: cgroups v2 not mounted."
    exit 1
fi

# --- Helpers ---

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

show_scores() {
    # show_scores label:pid [label:pid ...]
    for label_pid in "$@"; do
        local label=${label_pid%%:*}
        local pid=${label_pid##*:}
        if [[ -f "/proc/${pid}/oom_score" ]]; then
            local score=$(cat "/proc/${pid}/oom_score")
            local adj=$(cat "/proc/${pid}/oom_score_adj")
            echo "  ${label} (PID ${pid}): oom_score=${score}, oom_score_adj=${adj}"
        else
            echo "  ${label} (PID ${pid}): [already dead]"
        fi
    done
}

check_survivors() {
    local killed=""
    for label_pid in "$@"; do
        local label=${label_pid%%:*}
        local pid=${label_pid##*:}
        if kill -0 "$pid" 2>/dev/null; then
            echo "  ${label} (PID ${pid}): ALIVE"
        else
            echo "  ${label} (PID ${pid}): KILLED"
            killed="${killed}${label} "
        fi
    done
    echo "$killed"
}

# ============================================================================
# SCENARIO A: Both large+small at +1000 — tiebreak by memory size
# ============================================================================

run_scenario_a() {
    local trial_num=$1
    local result_file="${LOG_DIR}/trial_floor_a${trial_num}.log"

    echo ""
    echo "========================================"
    echo " Scenario A — Trial ${trial_num}: Ceiling Tiebreak (+1000 vs +1000)"
    echo "========================================"

    setup_cgroup

    # Spawn workers: large and small — both will get adj=+1000
    ${WORKER_BINARY} "small_A"  20 &
    local pid_small=$!
    echo "$pid_small" > "${CGROUP_PATH}/cgroup.procs"

    ${WORKER_BINARY} "medium_A" 50 &
    local pid_medium=$!
    echo "$pid_medium" > "${CGROUP_PATH}/cgroup.procs"

    ${WORKER_BINARY} "large_A"  80 &
    local pid_large=$!
    echo "$pid_large" > "${CGROUP_PATH}/cgroup.procs"

    sleep 2

    # Set both small and large to +1000 — ceiling tiebreak scenario
    echo "1000" > "/proc/${pid_small}/oom_score_adj"
    echo "1000" > "/proc/${pid_large}/oom_score_adj"
    # medium stays at 0 (default)

    echo "[adj] small_A  (PID ${pid_small}):  oom_score_adj=+1000  (CEILING)"
    echo "[adj] medium_A (PID ${pid_medium}): oom_score_adj=0      (default)"
    echo "[adj] large_A  (PID ${pid_large}):  oom_score_adj=+1000  (CEILING)"
    echo "[adj] Both small and large are at the ceiling — tiebreaker is memory size"

    echo "[scores] OOM scores before trigger:"
    show_scores "small_A:${pid_small}" "medium_A:${pid_medium}" "large_A:${pid_large}"

    local dmesg_before=$(dmesg | wc -l)

    # Trigger OOM: 120MB pushes total (20+50+80+120=270MB) well over 200MB limit
    # Large trigger ensures OOM fires hard enough to kill resident processes,
    # not just fail the trigger's own mmap silently.
    ${WORKER_BINARY} "trigger_A" 120 &
    local pid_trigger=$!
    echo "$pid_trigger" > "${CGROUP_PATH}/cgroup.procs"

    sleep 5

    echo "[result] Survivors:"
    local killed
    killed=$(check_survivors \
        "small_A:${pid_small}" "medium_A:${pid_medium}" \
        "large_A:${pid_large}" "trigger_A:${pid_trigger}")

    local oom_log=$(dmesg | tail -n +$((dmesg_before + 1)) | grep -i "oom\|killed\|out of memory" || true)

    {
        echo "=== Scenario A — Trial ${trial_num} ==="
        echo "Timestamp: $(date -Iseconds)"
        echo "Setup:"
        echo "  small_A:  20MB, oom_score_adj=+1000  (CEILING)"
        echo "  medium_A: 50MB, oom_score_adj=0      (default)"
        echo "  large_A:  80MB, oom_score_adj=+1000  (CEILING)"
        echo "  trigger_A: 120MB (OOM trigger)"
        echo "Question: When two processes both hit +1000, which dies?"
        echo "Expected: large_A (tiebreak goes to higher memory usage)"
        echo "Killed: ${killed:-none}"
        echo ""
        echo "Kernel OOM log:"
        echo "${oom_log}"
        echo ""
    } > "${result_file}"

    echo "[result] Killed: ${killed:-none}"
    echo "[result] Expected: large_A (tiebreak = larger memory wins)"
    echo "[result] Saved to ${result_file}"

    cleanup
    sleep 2
}

# ============================================================================
# SCENARIO B: Huge process at -1000 survives; tiny process at +1000 dies
# ============================================================================

run_scenario_b() {
    local trial_num=$1
    local result_file="${LOG_DIR}/trial_floor_b${trial_num}.log"

    echo ""
    echo "========================================"
    echo " Scenario B — Trial ${trial_num}: Floor Protection (-1000) vs Forced Target (+1000)"
    echo "========================================"

    setup_cgroup

    # huge holds most memory but is protected; tiny is tiny but targeted
    ${WORKER_BINARY} "tiny_B"   10 &
    local pid_tiny=$!
    echo "$pid_tiny" > "${CGROUP_PATH}/cgroup.procs"

    ${WORKER_BINARY} "medium_B" 50 &
    local pid_medium=$!
    echo "$pid_medium" > "${CGROUP_PATH}/cgroup.procs"

    ${WORKER_BINARY} "huge_B"  100 &
    local pid_huge=$!
    echo "$pid_huge" > "${CGROUP_PATH}/cgroup.procs"

    sleep 2

    # tiny is forced target, huge is fully protected
    echo "1000"  > "/proc/${pid_tiny}/oom_score_adj"
    echo "-1000" > "/proc/${pid_huge}/oom_score_adj"
    # medium stays at 0

    echo "[adj] tiny_B   (PID ${pid_tiny}):   oom_score_adj=+1000  (TARGETED)"
    echo "[adj] medium_B (PID ${pid_medium}): oom_score_adj=0      (default)"
    echo "[adj] huge_B   (PID ${pid_huge}):   oom_score_adj=-1000  (PROTECTED)"
    echo "[adj] huge_B uses 10x more RAM than tiny_B, yet should survive"

    echo "[scores] OOM scores before trigger:"
    show_scores "tiny_B:${pid_tiny}" "medium_B:${pid_medium}" "huge_B:${pid_huge}"

    local dmesg_before=$(dmesg | wc -l)

    # Trigger OOM: 100MB pushes total (10+50+100+100=260MB) well over 200MB limit
    ${WORKER_BINARY} "trigger_B" 100 &
    local pid_trigger=$!
    echo "$pid_trigger" > "${CGROUP_PATH}/cgroup.procs"

    sleep 5

    echo "[result] Survivors:"
    local killed
    killed=$(check_survivors \
        "tiny_B:${pid_tiny}" "medium_B:${pid_medium}" \
        "huge_B:${pid_huge}" "trigger_B:${pid_trigger}")

    local oom_log=$(dmesg | tail -n +$((dmesg_before + 1)) | grep -i "oom\|killed\|out of memory" || true)

    {
        echo "=== Scenario B — Trial ${trial_num} ==="
        echo "Timestamp: $(date -Iseconds)"
        echo "Setup:"
        echo "  tiny_B:    10MB, oom_score_adj=+1000  (TARGETED)"
        echo "  medium_B:  50MB, oom_score_adj=0      (default)"
        echo "  huge_B:   100MB, oom_score_adj=-1000  (PROTECTED)"
        echo "  trigger_B: 100MB (OOM trigger)"
        echo "Question: Does -1000 protect a 100MB process from being killed?"
        echo "Expected: tiny_B killed (not huge_B, despite huge_B using 10x more memory)"
        echo "Killed: ${killed:-none}"
        echo ""
        echo "Kernel OOM log:"
        echo "${oom_log}"
        echo ""
    } > "${result_file}"

    echo "[result] Killed: ${killed:-none}"
    echo "[result] Expected: tiny_B (adj=+1000 overrides memory size)"
    echo "[result] Saved to ${result_file}"

    cleanup
    sleep 2
}

# ============================================================================
# Main
# ============================================================================

trap cleanup EXIT
mkdir -p "${LOG_DIR}"

echo "============================================================"
echo " Experiment 4: Score Floor/Ceiling Tiebreak Behavior"
echo "============================================================"
echo " Memory limit: ${MEM_LIMIT}"
echo ""
echo " Scenario A: Ceiling tiebreak — large_A(80MB,+1000) vs small_A(20MB,+1000)"
echo "   Both at adj=+1000. Expected: large_A dies (size breaks the tie)."
echo ""
echo " Scenario B: Floor protection — huge_B(100MB,-1000) vs tiny_B(10MB,+1000)"
echo "   huge_B holds 10x more RAM but is exempt. Expected: tiny_B dies."
echo "============================================================"

for i in $(seq 1 ${NUM_TRIALS}); do
    run_scenario_a "$i"
done

for i in $(seq 1 ${NUM_TRIALS}); do
    run_scenario_b "$i"
done

# --- Summary ---
echo ""
echo "============================================================"
echo " Summary"
echo "============================================================"

summary_file="${LOG_DIR}/summary_floor.txt"
{
    echo "Experiment 4: Score Floor/Ceiling Tiebreak — Summary"
    echo "Date: $(date)"
    echo "Trials per scenario: ${NUM_TRIALS}"
    echo "Memory limit: ${MEM_LIMIT}"
    echo ""

    echo "--- Scenario A (Ceiling tiebreak: large_A vs small_A, both +1000) ---"
    echo "Expected: large_A killed in all trials"
    for i in $(seq 1 ${NUM_TRIALS}); do
        local_killed=$(grep "^Killed:" "${LOG_DIR}/trial_floor_a${i}.log" | sed 's/Killed: //')
        echo "  Trial A${i}: Killed -> ${local_killed:-none}"
    done

    a_correct=$(for i in $(seq 1 ${NUM_TRIALS}); do
        grep "^Killed:" "${LOG_DIR}/trial_floor_a${i}.log"
    done | grep -c "large_A" || true)
    echo "  large_A killed: ${a_correct}/${NUM_TRIALS}"
    echo ""

    echo "--- Scenario B (Floor protection: huge_B at -1000, tiny_B at +1000) ---"
    echo "Expected: tiny_B killed, huge_B survives in all trials"
    for i in $(seq 1 ${NUM_TRIALS}); do
        local_killed=$(grep "^Killed:" "${LOG_DIR}/trial_floor_b${i}.log" | sed 's/Killed: //')
        echo "  Trial B${i}: Killed -> ${local_killed:-none}"
    done

    b_tiny=$(for i in $(seq 1 ${NUM_TRIALS}); do
        grep "^Killed:" "${LOG_DIR}/trial_floor_b${i}.log"
    done | grep -c "tiny_B" || true)
    b_huge=$(for i in $(seq 1 ${NUM_TRIALS}); do
        grep "^Killed:" "${LOG_DIR}/trial_floor_b${i}.log"
    done | grep -c "huge_B" || true)
    echo "  tiny_B killed: ${b_tiny}/${NUM_TRIALS} (expected: all)"
    echo "  huge_B killed: ${b_huge}/${NUM_TRIALS} (expected: none)"

} | tee "${summary_file}"

echo ""
echo "Full results saved in ${LOG_DIR}/"
