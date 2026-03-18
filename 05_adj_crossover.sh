#!/bin/bash
# ============================================================================
# Experiment 5: oom_score_adj Crossover Threshold
# ============================================================================
#
# At what size difference does raw memory size overcome oom_score_adj bias?
#
# Formula derived from kernel oom_badness():
#   oom_score = (rss / total_system_RAM) * 1000 + oom_score_adj
#
# Two processes compete:
#   targeted : SMALL_MB,  adj = +ADJ_VALUE  (biased toward being killed)
#   neutral  : varies,    adj = 0           (relies on size alone)
#
# Crossover condition — neutral starts winning (gets killed instead):
#   (neutral_size - targeted_size) > ADJ_VALUE * total_RAM_MB / 1000
#
# OOM triggering strategy:
#   Rather than a trigger process (which suffers a cgroup-add race condition),
#   both processes are allocated in an UNLIMITED cgroup, then memory.max is
#   lowered below current usage. Dirty anonymous pages cannot be reclaimed
#   without swap, so the kernel immediately invokes the OOM killer.
#
# Expected results:
#   BELOW crossover: targeted killed  (adj bias wins)
#   ABOVE crossover: neutral  killed  (size difference overcomes adj bias)
#
# ============================================================================

set -euo pipefail

CGROUP_NAME="oom_experiment_crossover"
CGROUP_PATH="/sys/fs/cgroup/${CGROUP_NAME}"
LOG_DIR="./results"
WORKER_BINARY="./mem_worker"

# --- Tunable parameters ---
ADJ_VALUE=10     # oom_score_adj applied to 'targeted'
SMALL_MB=20      # Fixed size of the targeted process
OOM_MARGIN_MB=10 # How far below current usage to set memory.max.
                 # Must be less than SMALL_MB so only one process is killed.
STEP_MB=10       # Size step between sweep points
SWEEP_POINTS=5   # Points to test on each side of the threshold

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

# --- Detect total system RAM and compute theoretical crossover ---
TOTAL_RAM_MB=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 ))
CROSSOVER_DIFF_MB=$(( ADJ_VALUE * TOTAL_RAM_MB / 1000 ))
NEUTRAL_CROSSOVER_MB=$(( SMALL_MB + CROSSOVER_DIFF_MB ))

# --- Per-run output folder ---
RUN_DIR="${LOG_DIR}/crossover_$(date +%Y%m%d_%H%M%S)"
mkdir -p "${RUN_DIR}"
SUMMARY_FILE="${RUN_DIR}/summary.txt"

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
    # Start unlimited — limit is lowered after processes are resident
    echo "max" > "${CGROUP_PATH}/memory.max"
    echo "0"   > "${CGROUP_PATH}/memory.swap.max" 2>/dev/null || true
}

run_sweep_point() {
    local neutral_mb=$1
    local point_label=$2
    local trial_file="${RUN_DIR}/trial_${neutral_mb}mb.log"

    echo ""
    echo "  --- neutral=${neutral_mb}MB [${point_label}] ---"

    setup_cgroup

    # Spawn targeted (fixed small size)
    ${WORKER_BINARY} "targeted" ${SMALL_MB} &
    local pid_targeted=$!
    echo "$pid_targeted" > "${CGROUP_PATH}/cgroup.procs"

    # Spawn neutral (varying size, adj stays 0)
    ${WORKER_BINARY} "neutral" ${neutral_mb} &
    local pid_neutral=$!
    echo "$pid_neutral" > "${CGROUP_PATH}/cgroup.procs"

    # Wait for MAP_POPULATE to fully fault in all pages on both processes
    sleep 3

    # Set adj AFTER processes are fully resident
    echo "${ADJ_VALUE}" > "/proc/${pid_targeted}/oom_score_adj"
    # neutral stays at 0

    local score_targeted score_neutral
    score_targeted=$(cat "/proc/${pid_targeted}/oom_score" 2>/dev/null || echo "dead")
    score_neutral=$(cat  "/proc/${pid_neutral}/oom_score"  2>/dev/null || echo "dead")
    echo "  oom_score: targeted(${SMALL_MB}MB,adj=+${ADJ_VALUE})=${score_targeted}  neutral(${neutral_mb}MB,adj=0)=${score_neutral}"

    # Read actual cgroup usage (includes process overhead beyond just MB allocations)
    local current_bytes current_mb limit_mb
    current_bytes=$(cat "${CGROUP_PATH}/memory.current")
    current_mb=$(( current_bytes / 1024 / 1024 ))

    # Lower memory.max below current usage — forces immediate OOM.
    # Dirty anonymous pages cannot be reclaimed without swap, so the kernel
    # must invoke the OOM killer to get under the new limit.
    # OOM_MARGIN_MB < SMALL_MB ensures only one kill is needed.
    limit_mb=$(( current_mb - OOM_MARGIN_MB ))
    echo "  current=${current_mb}MB → lowering memory.max to ${limit_mb}MB (delta=-${OOM_MARGIN_MB}MB)"

    local dmesg_before
    dmesg_before=$(dmesg | wc -l)

    echo "${limit_mb}M" > "${CGROUP_PATH}/memory.max"

    # Give OOM killer time to fire and the victim time to die
    sleep 5

    # Check survivors
    local targeted_alive=0 neutral_alive=0
    kill -0 "$pid_targeted" 2>/dev/null && targeted_alive=1 || true
    kill -0 "$pid_neutral"  2>/dev/null && neutral_alive=1  || true

    local outcome
    if   [[ $targeted_alive -eq 0 && $neutral_alive -eq 1 ]]; then
        outcome="targeted killed  ← adj=+${ADJ_VALUE} working (preferred victim despite smaller size)"
    elif [[ $neutral_alive  -eq 0 && $targeted_alive -eq 1 ]]; then
        outcome="neutral  killed  ← ${neutral_mb}MB size overcame adj=+${ADJ_VALUE} bias (crossover)"
    elif [[ $targeted_alive -eq 0 && $neutral_alive  -eq 0 ]]; then
        outcome="both killed"
    else
        outcome="none killed  (OOM did not fire)"
    fi

    local oom_log
    oom_log=$(dmesg | tail -n +$((dmesg_before + 1)) | grep -i "Killed process" || true)

    echo "  outcome: ${outcome}"
    [[ -n "$oom_log" ]] && echo "  kernel:  $(echo "$oom_log" | head -2)"

    {
        echo "=== neutral=${neutral_mb}MB | ${point_label} threshold | current=${current_mb}MB → limit=${limit_mb}MB ==="
        echo "targeted : ${SMALL_MB}MB, adj=+${ADJ_VALUE}  | oom_score=${score_targeted}"
        echo "neutral  : ${neutral_mb}MB, adj=0       | oom_score=${score_neutral}"
        echo "Outcome: ${outcome}"
        echo "Kernel OOM log:"
        echo "${oom_log:-(none)}"
        echo ""
    } >> "${SUMMARY_FILE}"

    # Write individual trial log
    {
        echo "Trial: neutral=${neutral_mb}MB [${point_label}]"
        echo "Timestamp: $(date -Iseconds)"
        echo "targeted : ${SMALL_MB}MB, adj=+${ADJ_VALUE}  | oom_score=${score_targeted}"
        echo "neutral  : ${neutral_mb}MB, adj=0       | oom_score=${score_neutral}"
        echo "cgroup   : current=${current_mb}MB, limit set to ${limit_mb}MB"
        echo "Outcome  : ${outcome}"
        echo ""
        echo "Kernel OOM log:"
        echo "${oom_log:-(none)}"
    } > "${trial_file}"

    cleanup
    sleep 2
}

# ============================================================================
# Main
# ============================================================================

trap cleanup EXIT

echo "================================================================"
echo " Experiment 5: oom_score_adj Crossover Threshold"
echo "================================================================"
echo " System RAM      : ${TOTAL_RAM_MB} MB"
echo " targeted        : ${SMALL_MB} MB, adj=+${ADJ_VALUE} (fixed)"
echo " neutral         : sweeps ±${SWEEP_POINTS}×${STEP_MB}MB around crossover"
echo " OOM method      : lower memory.max below current usage (no trigger process)"
echo ""
echo " Crossover formula : (neutral - ${SMALL_MB}) = ${ADJ_VALUE} × ${TOTAL_RAM_MB} / 1000"
echo " Theoretical crossover at neutral = ${NEUTRAL_CROSSOVER_MB} MB"
echo "   Below ${NEUTRAL_CROSSOVER_MB} MB → targeted killed  (adj bias dominates)"
echo "   Above ${NEUTRAL_CROSSOVER_MB} MB → neutral  killed  (size overcomes adj)"
echo ""
echo " Output: ${RUN_DIR}/"
echo "================================================================"
echo ""

{
    echo "Experiment 5: oom_score_adj Crossover Threshold"
    echo "Run: $(date)"
    echo "System RAM      : ${TOTAL_RAM_MB} MB"
    echo "targeted        : ${SMALL_MB} MB, adj=+${ADJ_VALUE}"
    echo "Theoretical crossover at neutral = ${NEUTRAL_CROSSOVER_MB} MB"
    echo ""
} > "${SUMMARY_FILE}"

# Build sweep range centered on NEUTRAL_CROSSOVER_MB
sweep_points=()
for offset in $(seq -$(( SWEEP_POINTS * STEP_MB )) ${STEP_MB} $(( SWEEP_POINTS * STEP_MB ))); do
    pt=$(( NEUTRAL_CROSSOVER_MB + offset ))
    [[ $pt -gt $(( SMALL_MB + 5 )) ]] && sweep_points+=( "$pt" )
done

for neutral_mb in "${sweep_points[@]}"; do
    if   (( neutral_mb < NEUTRAL_CROSSOVER_MB - STEP_MB / 2 )); then label="BELOW"
    elif (( neutral_mb > NEUTRAL_CROSSOVER_MB + STEP_MB / 2 )); then label="ABOVE"
    else label="AT   "
    fi
    run_sweep_point "$neutral_mb" "$label"
done

# ============================================================================
# Summary table
# ============================================================================

echo ""
echo "================================================================"
echo " Results"
echo "================================================================"
printf " %-12s | %-10s | %s\n" "neutral_size" "expected" "outcome"
printf " %s\n" "-------------|-----------|----------------------------------------------"

{
    echo ""
    echo "=== Results Table ==="
    printf " %-12s | %-10s | %s\n" "neutral_size" "expected" "outcome"
    printf " %s\n" "-------------|-----------|----------------------------------------------"
} >> "${SUMMARY_FILE}"

for neutral_mb in "${sweep_points[@]}"; do
    if (( neutral_mb < NEUTRAL_CROSSOVER_MB )); then
        expected="targeted"
    else
        expected="neutral"
    fi
    actual=$(awk "/^=== neutral=${neutral_mb}MB/{found=1} found && /^Outcome:/{sub(/^Outcome: /,\"\"); print; exit}" \
             "${SUMMARY_FILE}")
    line=$(printf " %-12s | %-10s | %s" "${neutral_mb}MB" "$expected" "${actual:-no data}")
    echo "$line"
    echo "$line" >> "${SUMMARY_FILE}"
done

echo ""
echo "Full results: ${RUN_DIR}/"
