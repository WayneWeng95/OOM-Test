# OOM Killer Determinism Experiment

## Overview

This experiment tests whether the Linux OOM killer behaves deterministically:
given the same memory conditions, does it always kill the same process?

## Files

| File | Purpose |
|------|---------|
| `mem_worker.c` | C program that allocates a fixed amount of memory and holds it |
| `01_setup_and_run.sh` | Experiment 1: baseline determinism test |
| `02_score_adj_override.sh` | Experiment 2: prove oom_score_adj overrides natural selection |

## Prerequisites

- **Linux kernel 4.19+** with cgroups v2
- **Root access** (cgroup manipulation requires it)
- **GCC** to compile the worker

Check cgroups v2 is available:
```bash
mount | grep cgroup2
# Should show: cgroup2 on /sys/fs/cgroup type cgroup2 ...
```

## Quick Start

```bash
# 1. Compile the memory worker
gcc -O2 -o mem_worker mem_worker.c

# 2. Run Experiment 1 (baseline determinism)
sudo bash 01_setup_and_run.sh

# 3. Run Experiment 2 (oom_score_adj override)
sudo bash 02_score_adj_override.sh
```

## Experiment 1: Baseline Determinism

### Design

```
┌─────────────────────────────────────────────────┐
│  Memory Cgroup: limit = 200 MB, swap disabled   │
│                                                  │
│  ┌──────────┐ ┌──────────┐ ┌──────────────────┐ │
│  │  small    │ │  medium  │ │     large        │ │
│  │  20 MB   │ │  50 MB   │ │     80 MB        │ │
│  └──────────┘ └──────────┘ └──────────────────┘ │
│                                                  │
│  Total used: ~150 MB (within limit)              │
│                                                  │
│  Then spawn TRIGGER (100 MB)                     │
│  Total would be ~250 MB -> exceeds 200 MB limit  │
│  OOM killer fires!                               │
└─────────────────────────────────────────────────┘
```

### Expected Result

- The **large** process (80 MB RSS) should be killed every time
- The OOM killer's `oom_badness()` score is roughly proportional to RSS
- With 10 identical trials, the same process should be the victim each time
- **Verdict: DETERMINISTIC**

### What to Look For

The summary at the end should read:
```
RESULT: DETERMINISTIC - Same process killed in all 10 trials.
```

## Experiment 2: oom_score_adj Override

### Design

Same setup as Experiment 1, but before triggering OOM:
- Set `oom_score_adj = -1000` on the **large** process (protect it)
- Set `oom_score_adj = +1000` on the **small** process (target it)

### Expected Result

- The **small** process (only 20 MB!) should now be killed instead
- This proves `oom_score_adj` overrides the natural RSS-based scoring
- The large process survives despite being the biggest memory consumer

## Understanding the Results

### Why is this deterministic?

The OOM killer computes `oom_badness()` for each candidate:

```
score = (process_RSS / total_available_memory) * 1000 + oom_score_adj
```

Given identical RSS values and identical `oom_score_adj` values, the
score is always the same, so the same process is always selected.

### When would it NOT be deterministic?

- If worker processes don't fully allocate before the trigger fires
  (race condition in page faulting)
- If kernel background reclaim frees different amounts per trial
- If KSM (Kernel Same-page Merging) is active and deduplicates pages
- If swap is enabled and swaps different pages per run

The experiment mitigates these by:
1. Using `MAP_POPULATE` to pre-fault all pages
2. Writing unique patterns per page to defeat KSM
3. Disabling swap in the cgroup
4. Adding a sleep between allocation and trigger

## Going Further

### Variation ideas:

1. **Equal-size workers**: Spawn 3 workers with identical RSS.
   Which one gets killed? (Hint: process age and PID order matter
   as tiebreakers.)

2. **Dynamic memory**: Have workers continuously allocate/free memory
   in patterns. Does the OOM killer still pick consistently?

3. **Watch in real time**:
   ```bash
   # In another terminal, watch OOM events live:
   sudo dmesg -w | grep -i oom

   # Or watch cgroup memory stats:
   watch -n 0.5 cat /sys/fs/cgroup/oom_experiment/memory.current
   ```

4. **eBPF tracing**: Use bpftrace to hook into the OOM killer path:
   ```bash
   sudo bpftrace -e 'kprobe:oom_kill_process {
       printf("OOM kill: victim=%d\n", ((struct task_struct *)arg1)->pid);
   }'
   ```

5. **Read kernel OOM diagnostic**: After an OOM event, dmesg will show
   a full memory dump including per-process scores. Compare across trials.

## Troubleshooting

**"cgroups v2 not mounted"**
Some distros still default to v1. You can switch with a kernel boot parameter:
```
systemd.unified_cgroup_hierarchy=1
```

**Workers aren't being killed**
The memory limit might be too high relative to worker sizes. Increase
`TRIGGER_MB` or decrease `MEM_LIMIT`.

**Inconsistent results**
Try increasing the sleep time between worker allocation and trigger
to ensure all pages are fully resident before OOM fires.
