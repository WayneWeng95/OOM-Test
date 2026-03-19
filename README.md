# OOM Killer Experiment Suite

## Overview

A set of experiments testing how the Linux OOM killer selects victims inside cgroup v2 memory limits — covering baseline determinism, `oom_score_adj` tuning, container kill patterns, score floor/ceiling tiebreaks, and the adj crossover threshold.

Key finding: the OOM killer behaves fundamentally differently inside a cgroup than at the system level. See `summary.md` for the full analysis.

## Files

### Binaries (compile before running)

| Source | Binary | Purpose |
|--------|--------|---------|
| `mem_worker.c` | `mem_worker` | Allocates a fixed MB, touches all pages, holds until killed |
| `mem_worker_grow.c` | `mem_worker_grow` | Allocates memory gradually (used by experiment 03) |
| `mem_controller.c` | `mem_controller` | Manages worker respawn cycles (used by experiment 03) |

### Experiments

| Script | Results dir | Summary |
|--------|-------------|---------|
| `01_setup_and_run.sh` | `01_results/` | Baseline: does the OOM killer always kill the same process? |
| `02_score_adj_override.sh` | `02_results/` | Can `oom_score_adj` override natural size-based selection? |
| `03_container_oom_pattern.sh` | `03_results/` | Kill sequence determinism across parallel containers |
| `04_score_floor_tiebreak.sh` | `04_results/` | Tiebreak behavior at adj ceiling (+1000) and floor (-1000) |
| `05_adj_crossover.sh` | `05_results/` | At what size difference does adj bias get overcome? |
| `probe_cgroup_oom.sh` | _(stdout only)_ | Quick sanity check: does cgroup OOM kill work on this system? |

### Documentation

| File | Purpose |
|------|---------|
| `summary.md` | Key findings across all experiments |
| `02_summary.md` | Design and analysis for experiment 02 |
| `thoughts.md` | Raw observations and notes |
| `test_design.md` | Test design notes |

## Prerequisites

- Linux kernel 4.19+ with **cgroups v2**
- **Root access**
- **GCC**

```bash
# Verify cgroups v2
mount | grep cgroup2
# Expected: cgroup2 on /sys/fs/cgroup type cgroup2 ...
```

## Quick Start

```bash
# 1. Compile all binaries
gcc -O2 -o mem_worker mem_worker.c
gcc -O2 -o mem_worker_grow mem_worker_grow.c
gcc -O2 -o mem_controller mem_controller.c

# 2. (Recommended) Disable swap for cleaner OOM observation
sudo swapoff -a

# 3. Sanity check — confirms OOM kill works on this system
sudo bash probe_cgroup_oom.sh

# 4. Run experiments
sudo bash 01_setup_and_run.sh
sudo bash 02_score_adj_override.sh
sudo bash 03_container_oom_pattern.sh
sudo bash 04_score_floor_tiebreak.sh
sudo bash 05_adj_crossover.sh

# 5. Re-enable swap when done
sudo swapon -a
```

Each run creates a timestamped subfolder inside its results directory (e.g., `01_results/20260319_143201/`), so repeated runs never overwrite each other.

## Experiment Summaries

### 01 — Baseline Determinism

```
cgroup limit = 200 MB, swap off
  small   20 MB  adj=0
  medium  50 MB  adj=0
  large   80 MB  adj=0   ← expected victim (highest RSS)
  trigger 100 MB         ← pushes total to ~250 MB → OOM fires
```

Expected: `large` killed in every trial. If non-deterministic, suspect the MAP_POPULATE cgroup race (see `summary.md` Finding 4).

### 02 — `oom_score_adj` Override

Same layout as 01, but adj is set after workers are resident:

```
  large   80 MB  adj=-1000  ← protected
  medium  50 MB  adj=0
  small   20 MB  adj=+1000  ← targeted
```

Expected: `small` killed despite being the smallest. Extreme adj values (+1000/-1000) reliably flip victim selection even inside a cgroup. See `02_summary.md` for score math.

### 03 — Container Kill Pattern

Runs 4 parallel cgroups simultaneously, each with a controller managing 4 gradually-growing workers through 10 OOM cycles. Measures whether the kill sequence (which slot dies first, second, …) is consistent across containers and across trials.

### 04 — Score Floor/Ceiling Tiebreak

**Scenario A:** Two processes both at adj=+1000 (score ceiling). Tiebreaker is RSS — the larger one should die.

**Scenario B:** `huge` (100 MB, adj=-1000) vs `tiny` (10 MB, adj=+1000). Tests that -1000 fully exempts a process even when it holds 10× more memory than the target.

### 05 — adj Crossover Threshold

Sweeps `neutral` process size around the theoretical crossover point where size difference overcomes adj bias. Critically, uses the **cgroup formula** denominator (cgroup limit, not system RAM):

```
crossover diff = adj × cgroup_limit / 1000
```

For adj=10 and a ~150 MB cgroup, the crossover is only ~1.5 MB — far smaller than the system-level formula predicts (~158 MB). See `summary.md` for the full table.

## Key Findings

1. **`/proc/pid/oom_score` is misleading inside cgroups** — it uses system RAM as the denominator, not the cgroup limit.
2. **The adj crossover threshold shrinks by ~100×** inside a cgroup relative to system-level OOM.
3. **Intermediate adj values give far weaker protection than expected** in container-level OOM (the common production case).
4. **MAP_POPULATE / cgroup membership race** — fast-allocating processes can have pages charged to the root cgroup if `MAP_POPULATE` completes before the PID is written to `cgroup.procs`. This applies to any Linux system, not just WSL2.

## Observing OOM Events Live

```bash
# Watch kernel OOM messages in real time
sudo dmesg -w | grep -i oom

# Watch cgroup memory usage
watch -n 0.5 cat /sys/fs/cgroup/oom_experiment/memory.current

# See per-process OOM scores
cat /proc/<pid>/oom_score
cat /proc/<pid>/oom_score_adj
```

## Troubleshooting

**"cgroups v2 not mounted"**
Some distros default to v1. Enable v2 with the kernel boot parameter:
```
systemd.unified_cgroup_hierarchy=1
```

**Workers aren't being killed**
Increase `TRIGGER_MB` or decrease `MEM_LIMIT` so the overage is large enough to force a kill.

**Non-deterministic results in experiment 01**
Increase the `sleep` between worker allocation and trigger launch to ensure all pages are fully resident before OOM fires. Also confirm swap is disabled (`free -h` should show 0 swap).

**OOM fires but kills the wrong process**
Check `dmesg` for double-kill events — the limit may be set too aggressively narrow, causing a second OOM immediately after the first kill.
