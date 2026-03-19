# OOM Killer Behavior in Cgroup Environments — Summary

## Core Problem

The Linux OOM killer's behavior inside cgroups (containers, Kubernetes pods) differs fundamentally from system-level OOM. The `oom_score_adj` tuning mechanism is largely calibrated for system-level OOM, and its effectiveness is dramatically reduced in cgroup-constrained environments.

---

## Key Findings

### 1. Non-Deterministic Victim Selection

Across 10 trials with two competing processes (`large` and `trigger`), the OOM killer killed different processes each time — 6× large, 4× trigger. The source of non-determinism is two competing variables:

- **Process RSS size** (the dominant factor in the cgroup formula)
- **Process spawn time** (affects how much memory is charged to the cgroup at OOM time)

### 2. `/proc/pid/oom_score` Is Misleading Inside Cgroups

`/proc/pid/oom_score` is computed using **system RAM** as the denominator:

```
oom_score = (rss / system_RAM) × 1000 + adj
```

But the cgroup OOM killer uses the **cgroup memory limit** as the denominator:

```
oom_score = (rss / cgroup_limit) × 1000 + adj
```

**Effect:** A process using 127 MB inside a 150 MB cgroup has a base score of ~847, capped at 1000. An `adj` of +10 adds only 10 points — negligible against a 1000-point base. The `/proc` score shows a completely different picture and cannot be trusted for cgroup OOM analysis.

### 3. The `adj` Crossover Formula Changes in Cgroups

The threshold at which `adj` can flip which process is killed:

| `adj` value | Crossover (system, 15 GB RAM) | Crossover (cgroup, 150 MB limit) |
|-------------|-------------------------------|----------------------------------|
| +10         | ~158 MB                       | ~1.5 MB                          |
| +100        | ~1,577 MB                     | ~15 MB                           |
| +500        | ~7,883 MB                     | ~75 MB                           |

Inside a cgroup, even small RSS differences between processes overwhelm a moderate `adj` value. To meaningfully influence victim selection via `adj` in a cgroup, you need either a **very large adj** (hundreds) or a **very small RSS difference** between processes (a few MB).

### 4. MAP_POPULATE Race (cgroup Membership Timing)

Small processes that complete `MAP_POPULATE` (physical page faulting) before their PID is written to `cgroup.procs` have their pages charged to the **root cgroup**, not the experiment cgroup. This makes small/fast processes effectively invisible to cgroup memory accounting, causing:

- Inaccurate memory tracking (`memory.current` missing the small process's RSS)
- The cgroup limit being set too aggressively (based only on the large process)
- Double-kill events: after the large process is killed, the limit is still exceeded, so the kernel immediately fires OOM again

---

## Container Runtime Implications

### How Kubernetes Sets `oom_score_adj`

| QoS Class   | `oom_score_adj`                                              |
|-------------|--------------------------------------------------------------|
| Guaranteed  | -997 (nearly protected)                                      |
| BestEffort  | +1000 (always killed first)                                  |
| Burstable   | `min(max(2, 1000 − (1000 × memReq / nodeCapacity)), 999)`   |

These values were designed for **system-level OOM** (node runs out of RAM). They behave differently for **container-level OOM** (pod hits its own `memory.max`).

### Two Distinct OOM Scenarios

| Scenario | Denominator | `adj` Effectiveness |
|---|---|---|
| **Node-level OOM** (host runs out of RAM) | System RAM (~GBs) | Works as designed; QoS priorities are meaningful |
| **Container-level OOM** (pod hits `memory.max`) | Cgroup limit (MBs) | Greatly reduced; process size dominates |

Container-level OOM is the **common production case** (pod hitting its memory limit). In this scenario, the largest process in the container is killed almost regardless of `adj`, unless `adj` is in the extreme range (near -1000 or +1000).

### Practical Takeaway

- **Extreme adj values** (-997, +1000) still work inside containers because they are large enough to overcome even a 1000-point base score.
- **Intermediate Burstable adj values** (e.g., -200 to -500) are calibrated for node-level OOM. Inside a container hitting its own limit, these values provide far weaker protection than intended — the largest process dies almost regardless.
- Application developers relying on Burstable QoS for intra-container OOM priority ordering will likely not get the behavior they expect.

---

## Recommendations for Future Testing

1. Use a **much larger `adj`** (e.g., +500 or -500) to see crossover effects inside cgroups.
2. Keep the **RSS difference between processes small** (a few MB) so `adj` can actually tip the balance.
3. Use `memory.current` and cgroup event counters for ground-truth accounting — do not rely on `/proc/pid/oom_score`.
4. Add a deliberate delay after writing PIDs to `cgroup.procs` before allocating memory, to avoid the MAP_POPULATE race.
