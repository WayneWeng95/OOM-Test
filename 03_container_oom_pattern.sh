#!/usr/bin/env bash
# 03_container_oom_pattern.sh
#
# Experiment 03: OOM Kill Pattern Determinism with Controller + Respawn
#
# Runs NUM_CONTAINERS isolated cgroups (v2), each with a controller managing
# NUM_WORKERS (4) gradually-growing workers. Records the OOM kill sequence
# per container per trial, then analyses whether the sequence is deterministic
# within a trial (cross-container) and across trials (cross-trial).
#
# Must be run as root (cgroup memory limits require root).
# Prerequisites: mem_worker_grow and mem_controller binaries in same directory.

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────
NUM_CONTAINERS=4
MEM_LIMIT="200M"      # per cgroup  (4 × 100 MB workers = 400 MB > 300 MB → OOM)
WORKER_MAX_MB=100     # each worker grows to 100 MB
NUM_CYCLES=10         # OOM events to observe per container per trial
NUM_TRIALS=3
LOG_DIR="./results"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_BIN="${SCRIPT_DIR}/mem_worker_grow"
CONTROLLER_BIN="${SCRIPT_DIR}/mem_controller"
CGROUP_ROOT="/sys/fs/cgroup"
CGROUP_PREFIX="oom_pattern"

# ── Sanity checks ──────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: must be run as root (cgroup memory control requires root)."
    exit 1
fi

for bin in "$WORKER_BIN" "$CONTROLLER_BIN"; do
    if [[ ! -x "$bin" ]]; then
        echo "ERROR: $bin not found or not executable."
        echo "       Build with: gcc -O2 -o mem_worker_grow mem_worker_grow.c"
        echo "                   gcc -O2 -o mem_controller mem_controller.c"
        exit 1
    fi
done

if ! grep -q "^cgroup2" /proc/mounts 2>/dev/null && \
   ! mountpoint -q "${CGROUP_ROOT}"; then
    echo "ERROR: cgroups v2 not mounted at ${CGROUP_ROOT}."
    exit 1
fi

mkdir -p "${LOG_DIR}"

# ── Helper: timestamp ──────────────────────────────────────────────────────────
ts() { date '+%Y-%m-%dT%H:%M:%S'; }

# ── Helper: destroy one cgroup ────────────────────────────────────────────────
teardown_cgroup() {
    local name="$1"
    local cg="${CGROUP_ROOT}/${name}"
    [[ -d "$cg" ]] || return 0

    # Kill remaining processes
    local attempts=0
    while [[ -s "${cg}/cgroup.procs" ]] && (( attempts < 10 )); do
        while read -r pid; do
            kill -9 "$pid" 2>/dev/null || true
        done < "${cg}/cgroup.procs"
        sleep 0.3
        (( attempts++ ))
    done

    rmdir "$cg" 2>/dev/null || true
}

# ── Helper: extract kill sequence from a log ──────────────────────────────────
extract_sequence() {
    local logfile="$1"
    # Prefer the CONTROLLER_END summary line
    local seq
    seq=$(grep '^CONTROLLER_END' "$logfile" 2>/dev/null \
          | sed 's/.*kill_sequence=\([^ ]*\).*/\1/' | head -1)
    if [[ -z "$seq" ]]; then
        # Fallback: reconstruct from KILL lines
        seq=$(grep '^KILL' "$logfile" 2>/dev/null \
              | awk '{for(i=1;i<=NF;i++) if($i~/^slot=/) {sub(/slot=/,"",$i); printf "%s,",$i}}' \
              | sed 's/,$//')
    fi
    echo "$seq"
}

# ── Main trial loop ────────────────────────────────────────────────────────────
declare -A trial_sequences   # trial_sequences[trial,container] = sequence

for trial in $(seq 1 "$NUM_TRIALS"); do
    echo ""
    echo "══════════════════════════════════════════════════════════════"
    echo "  TRIAL ${trial} / ${NUM_TRIALS}   ($(ts))"
    echo "══════════════════════════════════════════════════════════════"

    # -- Setup all cgroups in parallel, then launch all controllers in parallel --
    # Enable memory controller once (idempotent) before forking
    echo "+memory" > "${CGROUP_ROOT}/cgroup.subtree_control" 2>/dev/null || true

    declare -a ctrl_pids=()
    declare -a ctrl_logs=()

    for c in $(seq 0 $(( NUM_CONTAINERS - 1 ))); do
        logfile="${LOG_DIR}/trial_${trial}_container_${c}.log"
        ctrl_logs+=("$logfile")
        cg="${CGROUP_ROOT}/${CGROUP_PREFIX}_${c}"

        # Each subshell: sets up its own cgroup, then immediately execs the
        # controller — so cgroup creation and controller launch are one step,
        # all four happening in parallel via &.
        (
            # Set up this container's cgroup
            [[ -d "$cg" ]] && rmdir "$cg" 2>/dev/null || true
            mkdir -p "$cg"
            echo "${MEM_LIMIT}" > "${cg}/memory.max"
            echo "0"            > "${cg}/memory.swap.max"
            echo "1"            > "${cg}/memory.oom.group" 2>/dev/null || true

            # Join the cgroup (BASHPID = this subshell, which exec replaces)
            echo $BASHPID > "${cg}/cgroup.procs"
            echo -500 > "/proc/$BASHPID/oom_score_adj" 2>/dev/null || true

            exec "$CONTROLLER_BIN" \
                "$WORKER_BIN" \
                "$WORKER_MAX_MB" \
                "$NUM_CYCLES" \
                "$logfile" \
                "$c" \
                "$trial"
        ) &

        ctrl_pids+=($!)
        echo "  [trial=${trial}] container=${c} controller_pid=${ctrl_pids[-1]} log=${logfile}"
    done

    # -- Wait for all controllers to finish --
    echo ""
    echo "  Waiting for ${NUM_CONTAINERS} controllers to complete ${NUM_CYCLES} OOM cycles each..."
    for pid in "${ctrl_pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    echo "  All controllers done.  ($(ts))"

    # -- Extract and compare sequences --
    comparison_file="${LOG_DIR}/trial_${trial}_comparison.txt"
    {
        echo "TRIAL ${trial} COMPARISON  ($(ts))"
        echo ""
        sequences=()
        for c in $(seq 0 $(( NUM_CONTAINERS - 1 ))); do
            logfile="${LOG_DIR}/trial_${trial}_container_${c}.log"
            seq=$(extract_sequence "$logfile")
            sequences+=("$seq")
            echo "  container=${c}  sequence=${seq}"
            trial_sequences["${trial},${c}"]="$seq"
        done

        echo ""
        # Compare all containers against container 0
        ref="${sequences[0]}"
        all_match=true
        for c in $(seq 1 $(( NUM_CONTAINERS - 1 ))); do
            if [[ "${sequences[$c]}" != "$ref" ]]; then
                all_match=false
                break
            fi
        done

        if $all_match; then
            echo "CROSS_CONTAINER_VERDICT: MATCH (all ${NUM_CONTAINERS} containers show same kill sequence)"
        else
            echo "CROSS_CONTAINER_VERDICT: DIFFER (containers show different kill sequences)"
        fi
    } | tee "$comparison_file"

    # -- Teardown all cgroups --
    for c in $(seq 0 $(( NUM_CONTAINERS - 1 ))); do
        teardown_cgroup "${CGROUP_PREFIX}_${c}"
    done

    echo ""
    echo "  Cgroups cleaned up."
done

# ── Final cross-trial analysis ─────────────────────────────────────────────────
summary_file="${LOG_DIR}/final_summary.txt"
{
    echo "═══════════════════════════════════════════════════════════════"
    echo "  EXPERIMENT 03 FINAL SUMMARY"
    echo "  Generated: $(ts)"
    echo "  Trials: ${NUM_TRIALS}  Containers: ${NUM_CONTAINERS}  Cycles/container: ${NUM_CYCLES}"
    echo "  Memory limit: ${MEM_LIMIT}  Worker max: ${WORKER_MAX_MB} MB"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    echo "── Per-trial, per-container kill sequences ──"
    for trial in $(seq 1 "$NUM_TRIALS"); do
        echo "  Trial ${trial}:"
        for c in $(seq 0 $(( NUM_CONTAINERS - 1 ))); do
            echo "    container=${c}  ${trial_sequences[${trial},${c}]:-N/A}"
        done
    done
    echo ""

    echo "── Cross-container determinism (within each trial) ──"
    all_trials_cross_match=true
    for trial in $(seq 1 "$NUM_TRIALS"); do
        ref="${trial_sequences[${trial},0]:-}"
        match=true
        for c in $(seq 1 $(( NUM_CONTAINERS - 1 ))); do
            if [[ "${trial_sequences[${trial},${c}]:-}" != "$ref" ]]; then
                match=false
                all_trials_cross_match=false
                break
            fi
        done
        echo "  Trial ${trial}: $( $match && echo MATCH || echo DIFFER )"
    done
    echo ""

    echo "── Cross-trial determinism (same container across trials) ──"
    all_containers_cross_trial=true
    for c in $(seq 0 $(( NUM_CONTAINERS - 1 ))); do
        ref="${trial_sequences[1,${c}]:-}"
        match=true
        for trial in $(seq 2 "$NUM_TRIALS"); do
            if [[ "${trial_sequences[${trial},${c}]:-}" != "$ref" ]]; then
                match=false
                all_containers_cross_trial=false
                break
            fi
        done
        echo "  Container ${c}: $( $match && echo MATCH || echo DIFFER )"
    done
    echo ""

    echo "── Overall verdict ──"
    if $all_trials_cross_match; then
        echo "  CROSS_CONTAINER: DETERMINISTIC — all containers show the same kill sequence within each trial."
    else
        echo "  CROSS_CONTAINER: NON-DETERMINISTIC — containers diverge within at least one trial."
    fi

    if $all_containers_cross_trial; then
        echo "  CROSS_TRIAL:     DETERMINISTIC — each container reproduces the same sequence across trials."
    else
        echo "  CROSS_TRIAL:     NON-DETERMINISTIC — kill sequence varies across trials."
    fi
    echo ""
    echo "  See individual logs: ${LOG_DIR}/trial_T_container_C.log"
    echo "  See per-trial comparisons: ${LOG_DIR}/trial_T_comparison.txt"

} | tee "$summary_file"

echo ""
echo "Done. Results in ${LOG_DIR}/"
