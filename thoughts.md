One of the case we have observed is that:

The killed process may be determined by two reasons:

1. Size
2. Spawned time

Which in this case, we see the first set of results which non-deterministic behavior have been observed.

-- this two variable leads to the back and forth behavior of such a simple OOM killer situation.

```
Per-trial results:
  Trial 1: Killed -> large(7825)
  Trial 2: Killed -> trigger(8006)
  Trial 3: Killed -> trigger(8136)
  Trial 4: Killed -> large(8227)
  Trial 5: Killed -> trigger(8409)
  Trial 6: Killed -> large(8485)
  Trial 7: Killed -> large(8613)
  Trial 8: Killed -> large(8781)
  Trial 9: Killed -> large(8970)
  Trial 10: Killed -> trigger(9142)

RESULT: NON-DETERMINISTIC - Different processes killed across trials.
Unique outcomes:
      1 Killed: trigger(9142)
      1 Killed: trigger(8409)
      1 Killed: trigger(8136)
      1 Killed: trigger(8006)
      1 Killed: large(8970)
      1 Killed: large(8781)
      1 Killed: large(8613)
      1 Killed: large(8485)
      1 Killed: large(8227)
      1 Killed: large(7825)

```
In this sense, the problem is clear that the non-deterministic is surely there. 

With the OOM_adjust score, the issue seems not being elevated as the amount of the scoring seems fit in the old scheme but may not in the new scheme.


Also in the case with smaller memory capacity, the adjust number seems make less impact?  (Maybe not true)  the 1000/1000 score adjust level.


Finding 1: /proc/oom_score is a lie for cgroup OOM   
                                                       
  Every trial shows targeted=674 > neutral=670-674, yet
   neutral is killed every single time. The            
  /proc/pid/oom_score is computed using system RAM     
  (15766 MB) as the denominator — but the cgroup OOM
  killer uses the cgroup memory limit as its           
  denominator.                                         
                                                       
  With system RAM formula:                             
  targeted: 20MB / 15766MB × 1000 + 10 ≈ 11.3   ← what 
  /proc shows as ~674 (WSL2 anomaly)                   
  neutral:  127MB / 15766MB × 1000 + 0  ≈  8.1

  With cgroup limit formula (e.g. limit=117MB):
  targeted: 20MB / 117MB × 1000 + 10  = 171 + 10 = 181
  neutral:  127MB / 117MB × 1000 + 0  = 1085 → capped
  at 1000
  In the cgroup context, neutral's score is capped at
  1000 because it exceeds the limit itself. adj=+10
  adds only 10 points — completely irrelevant against a
   1000-point score.

  Finding 2: The crossover formula you were testing
  doesn't apply in cgroup OOM

  The formula (neutral - targeted) > adj × system_RAM /
   1000 is only correct for system-level OOM. Inside a
  cgroup, the effective crossover is:
  (neutral - targeted) > adj × cgroup_limit / 1000
  For adj=10 and cgroup_limit=~150MB, the crossover is
  at only ~1.5 MB difference. Since neutral starts at
  127MB vs targeted's 20MB (107 MB difference), we were
   far above the cgroup crossover for every single
  trial.

  ┌────────┬───────────────────┬──────────────────┐
  │  adj   │  crossover diff   │ crossover diff   │
  │ value  │  (system, 15GB    │ (cgroup, 150MB)  │
  │        │       RAM)        │                  │
  ├────────┼───────────────────┼──────────────────┤
  │ +10    │ ~158 MB           │ ~1.5 MB          │
  ├────────┼───────────────────┼──────────────────┤
  │ +100   │ ~1577 MB          │ ~15 MB           │
  ├────────┼───────────────────┼──────────────────┤
  │ +500   │ ~7883 MB          │ ~75 MB           │
  └────────┴───────────────────┴──────────────────┘

  Finding 3: WSL2 has a MAP_POPULATE race on
  cgroup.procs assignment

  The memory.current consistently shows only neutral's
  size, missing targeted's 20 MB. Because targeted (20
  MB) is small, its MAP_POPULATE completes in
  milliseconds — before bash finishes writing its PID
  to cgroup.procs. Pages faulted in before cgroup
  membership are charged to the root cgroup, not the
  experiment cgroup. So targeted is invisible to the
  cgroup's memory accounting, which also means the OOM
  limit is set too aggressively narrow in the first
  place (based only on neutral's size).

  The neutral=127MB, both killed case confirms this:
  the limit was set 10 MB below neutral alone (not the
  real total), so after neutral was killed the kernel
  immediately fired OOM again and killed the
  now-orphaned targeted.

  ---
  Bottom line: To meaningfully test adj crossover in a
  cgroup context, you'd need either a much larger adj
  (hundreds, not +10), or a very small size difference
  between the two processes (a few MB). 
  
  
  The system-RAM-based formula is only valid for bare-metal/system-level OOM, not cgroup-constrained memory.

---

## Container Runtime Implication

This is directly relevant to how container runtimes (Docker, Kubernetes, LXC) operate,
because they all use cgroup memory limits to isolate workloads.

### How runtimes set oom_score_adj today

Kubernetes assigns adj based on QoS class:
  - Guaranteed pods:   oom_score_adj = -997  (almost protected)
  - Burstable pods:    oom_score_adj = calculated from request/limit ratio
  - BestEffort pods:   oom_score_adj = +1000 (always killed first)

Docker by default sets oom_score_adj = 0 for containers.

### Why this is based on the wrong formula

These values were designed assuming the system-level formula:
  oom_score = (rss / system_RAM) * 1000 + adj

But inside a container's own cgroup, the OOM killer uses:
  oom_score = (rss / cgroup_limit) * 1000 + adj

Within a tight cgroup (e.g. 256MB container limit), a process using 200MB
already has a base score of ~781. An adj of -997 reduces that to roughly
-216, which is below zero (→ protected). So extreme values (+1000, -997)
still work as intended.

But intermediate Kubernetes Burstable adj values (e.g. adj = -500) behave
very differently than expected:
  - System-level: protects against processes using less than 50% of RAM
  - Cgroup-level:  protects only against processes using less than ~33% of
    the container's own memory limit

### Two distinct OOM scenarios in a cluster

  1. NODE-level OOM (host runs out of memory):
     - Formula uses system RAM as denominator
     - Kubernetes QoS adj values work as designed
     - BestEffort pods die first, Guaranteed pods are protected

  2. CONTAINER-level OOM (pod exceeds its own memory.max):
     - Formula uses the container's cgroup limit as denominator
     - The adj values have far less influence; process size dominates
     - The largest process in the container is killed almost regardless of adj
     - This is the common case in production (pods hitting their memory limit)

### Practical takeaway

oom_score_adj tuning in container environments primarily affects inter-pod
priority at the NODE level. Within a single container that hits its own
memory limit, the kernel kills the largest process first — adj offers
only marginal protection unless the adj value is in the extreme range
(close to -1000 or +1000).


Two completely different OOM scenarios in a cluster:
                                                       
  - Node-level OOM (host runs out of RAM) — the
  Kubernetes QoS adj values (-997, +1000) work as
  designed, because the denominator is system RAM
  (~GBs). The adj bias has real weight.
  - Container-level OOM (pod hits its own memory.max) —
   this is the common production case, and it's where
  the formula breaks down. With a 256MB container
  limit, any process using >80MB of that container
  already has a base score of ~312. An adj of +100 adds
   100 points, which is significant. But adj of +10
  (like we tested) adds almost nothing compared to the
  size difference.

  The important implication: Kubernetes' intermediate
  Burstable QoS adj values (e.g., -200 to -500) are
  calibrated for node-level OOM protection, but when a
  container hits its own limit, those same values give
  far weaker size-vs-adj tradeoffs than the designers
  likely intended. The largest process in the container
   dies almost regardless of adj, which may not align
  with what the application developer expects.


Node out of memory behavior
If the node experiences an out of memory (OOM) event prior to the kubelet being able to reclaim memory, the node depends on the oom_killer to respond.

The kubelet sets an oom_score_adj value for each container based on the QoS for the pod.

Quality of Service	oom_score_adj
Guaranteed	-997
BestEffort	1000
Burstable	min(max(2, 1000 - (1000 × memoryRequestBytes) / machineMemoryCapacityBytes), 999)

Note:
The kubelet also sets an oom_score_adj value of -997 for any containers in Pods that have system-node-critical Priority.
If the kubelet can't reclaim memory before a node experiences OOM, the oom_killer calculates an oom_score based on the percentage of memory it's using on the node, and then adds the oom_score_adj to get an effective oom_score for each container. It then kills the container with the highest score.

This means that containers in low QoS pods that consume a large amount of memory relative to their scheduling requests are killed first.

Unlike pod eviction, if a container is OOM killed, the kubelet can restart it based on its restartPolicy.