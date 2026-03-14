#!/usr/bin/env bash
# probe_cgroup_oom.sh — minimal sanity check: does a cgroup memory.max OOM kill work?
#
# Creates one cgroup with a 150M limit, launches a single worker that tries
# to allocate 300M. Should be OOM-killed within ~30s.
# Run as: sudo ./probe_cgroup_oom.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER="${SCRIPT_DIR}/mem_worker_grow"
CG="/sys/fs/cgroup/oom_probe_test"

cleanup() {
    if [[ -d "$CG" ]]; then
        while read -r pid 2>/dev/null; do
            kill -9 "$pid" 2>/dev/null || true
        done < "${CG}/cgroup.procs" 2>/dev/null || true
        sleep 0.3
        rmdir "$CG" 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo "=== Cgroup OOM probe ==="
echo "+memory" > /sys/fs/cgroup/cgroup.subtree_control

mkdir -p "$CG"
echo "150M" > "${CG}/memory.max"
echo "0"    > "${CG}/memory.swap.max"

echo "  cgroup : $CG"
echo "  memory.max      : $(cat ${CG}/memory.max)"
echo "  memory.swap.max : $(cat ${CG}/memory.swap.max)"
echo ""
echo "  Launching worker (wants 300M, limit is 150M)..."

(
    echo $BASHPID > "${CG}/cgroup.procs"
    exec "$WORKER" probe 20 100 300
) &
WPID=$!
echo "  worker pid=$WPID  (in cgroup: $(cat ${CG}/cgroup.procs 2>/dev/null || echo '?'))"

wait $WPID 2>/dev/null; RC=$?

if (( RC == 137 )); then
    echo ""
    echo "  RESULT: KILLED with exit code 137 (128+SIGKILL=9) — OOM killer fired correctly."
elif (( RC == 1 )); then
    echo ""
    echo "  RESULT: Worker exited with code 1 (mmap failed) — memory limit enforced, but via mmap"
    echo "          failure rather than OOM kill. Check dmesg for 'oom_kill_process'."
else
    echo ""
    echo "  RESULT: exit code=$RC — unexpected. Worker may NOT have been in the cgroup."
    echo "          Check: dmesg | grep -i oom"
fi
