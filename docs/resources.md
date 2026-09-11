# What this project needs

Four workloads in one namespace. Everything below is stated with its reason,
because a request without a reason is a number nobody can ever safely change.

Figures marked **measured** come from running the platform; the rest are
starting points and should be revised against real usage.

## At a glance

| Workload | Replicas | CPU request | Memory request | Memory limit | Storage |
|---|---|---|---|---|---|
| autoscaler | 1 (strict) | 100m | 128Mi | 512Mi | 1Gi RWO |
| simlab-api | 1 (strict) | 200m | 256Mi | 1Gi | — |
| Postgres | 1 (strict) | 100m | 256Mi | 1Gi | 8Gi RWO |
| simlab-web | 1+ | 25m | 32Mi | 128Mi | — |

Total at rest: about 0.4 CPU and 0.7Gi memory requested, 9Gi of storage. That
is small enough to sit alongside anything else in a shared namespace.

## autoscaler

**Replicas: exactly one, `strategy: Recreate`.** Not a preference — two
replicas would both hold the same target file and both drive the same
autonomous targets, each deciding from capacity the other had just changed.
The chart sets `Recreate` so a rolling update cannot briefly run two.

**CPU** is spiky and small. Between decisions it does nothing. A decision
simulates the queue forward over a 15-minute horizon in 15-second steps, once
per candidate executor count in a binary search — tens of thousands of
floating-point operations, single-digit milliseconds, every 15 seconds per
target. 100m is comfortable for tens of targets; it would need revisiting at
hundreds.

**Memory** is dominated by the target registry, which is small: a target is a
few hundred bytes plus its settings document. The Go binary itself is **4.2 MB
(measured)** and the runtime floor is a few tens of Mi. The 512Mi limit is
headroom against a pathological queue observation, not an expectation.

**Storage: 1Gi ReadWriteOnce**, holding `targets.json` — every registered
target with its access keys, written 0600 and replaced atomically. The actual
file is kilobytes; the 1Gi is because that is the smallest PVC worth asking
for. **Without persistence a restart loses every target and every access key,
and the service comes back unable to scale anything.** Treat the volume as
secret-bearing: it holds Kubernetes tokens, ColonyOS private keys and Docker
client certificates in the clear, because a registry that stored them redacted
would be useless after a restart.

Losing the volume is recoverable but not free: no run data lives there, so the
cost is re-entering each target's credentials by hand. On vikingvault the
class this project uses (`longhorn-single-odin`) keeps one replica and
reclaims on delete, so both a node failure and a `helm uninstall` have that
cost. A replicated class is the fix if the platform is ever expected to
survive a node failure unattended.

**RBAC** is namespace-scoped Roles, one per namespace the autoscaler is
permitted to provision into, listed in `autoscaler.rbac.namespaces`. It needs:

| Resource | Verbs | What for |
|---|---|---|
| `pods` | get, list | Counting Ready pods — capacity that can actually take work |
| `apps/deployments` | get, list | Reading what each tier has been asked for |
| `apps/deployments/scale` | get, patch, update | Resizing a pool. The subresource only, so a scaling write cannot touch a pod template and roll the pool mid-burst |
| `apps/deployments` | create | Creating an executor pool that does not exist yet, for the `colonyos-k8s` platform. Drop it to run only against pools somebody else manages |
| `secrets` | get, create, update | Writing the ColonyOS executor key the pods read. Referenced from the pod spec rather than inlined, so it is visible only to whoever can read Secrets |

A ClusterRole is deliberately not offered. This service creates Deployments
and reads Secrets; it should be able to do that exactly where somebody has
said so.

## simlab-api

**Replicas: exactly one, `strategy: Recreate`.** A run in flight is held in
memory by the process that started it. A second replica would neither know
about its runs nor be able to stop them, and a load balancer would send half
the status requests to a pod that has never heard of the run being asked
about.

**CPU** is the highest of the four, and it is the queue simulation rather than
the HTTP layer. A two-hour scenario at 15-second cycles is **3,287 cycles over
13,071 jobs (measured)**, each cycle admitting arrivals, allocating an
executor-seconds budget strict-priority, and scanning for newly breached jobs.
Compressed replay runs that flat out. 200m is a request, not a cap; a run will
happily use a whole core and finish sooner for it. Raise the limit rather than
the request if runs feel slow.

**Memory** scales with the job log, which is generated up front and held for
the run: roughly 40 bytes per job, so a 13,000-job scenario is well under a
megabyte and a 5,000,000-job one — the generator's hard ceiling — would be
about 200Mi. The 1Gi limit accommodates the ceiling; ordinary runs never
approach it. The binary is **4.5 MB (measured)**.

**No storage of its own.** Everything durable is in Postgres.

**Termination needs room.** A run that is killed mid-cycle leaves an ephemeral
autoscaler target behind, and those accumulate silently. The chart sets a
60-second grace period and the process stops runs rather than abandoning them.

## Postgres

**Replicas: exactly one, `strategy: Recreate`.** Two pods cannot share one
ReadWriteOnce volume, and a rolling update would deadlock waiting for the old
one to release it.

**Storage: 8Gi ReadWriteOnce.** Sizing is driven by `run_cycles`, which is the
only table that grows meaningfully: one row per decision, so **3,287 rows for
a two-hour run at 15-second cycles (measured)**. Each row carries the
per-priority queue shape as JSONB, so call it 1–2 KB. A hundred such runs is
therefore a few hundred megabytes. 8Gi leaves room for a few thousand runs;
`DELETE FROM runs` cascades everything a run owns when space is wanted back.

The embedded Postgres is appropriate for this workload — one writer, no
replication requirement, and losing it costs stored results rather than
anything live. Point `simlab-api.database.existingSecret` at a managed
instance if runs are to be kept long-term.

## simlab-web

Static assets behind nginx. **20.5 MB image (measured)**, no state, no
dependencies beyond simlab-api. The only workload here that can be scaled
horizontally, and the only one where that would achieve nothing.

## What grows, and what does not

- **More targets** costs the autoscaler CPU roughly linearly: one forward
  simulation binary search per target per interval. Nothing else notices.
- **Longer or busier scenarios** cost simlab-api memory (the job log) and
  Postgres storage (`run_cycles`), both linearly.
- **More concurrent runs** cost simlab-api CPU and memory per run, and each
  one creates a short-lived autoscaler target. They do not contend: each run
  owns its own target and its own queue.
- **More users** costs essentially nothing. Every page reads from Postgres or
  a stream that drops frames rather than slowing a run down.

## Node placement

Nothing here needs a particular node. If the cluster wants these on specific
nodes, `nodeSelector`, `tolerations` and `affinity` are exposed on all three
service charts and are the infrastructure repository's decision.

One thing is worth knowing. On vikingvault (checked 2026-09-11)
`odin-worker-1..3` still carry `decay.io/tier=local` and `odin-worker-4`
carries `decay.io/tier=cloud` — left over from an earlier incarnation of this
project, whose workloads are otherwise entirely gone. Those labels are for the
*executors* an autoscaler target provisions, not for these four workloads, but
a `colonyos-k8s` target that wants its two tiers on different nodes could use
them as they stand, through that target's own pod spec rather than through
this chart.

The four large nodes are `odin-worker-1..4` at 6 CPU and 24Gi each; the
masters and the two small workers are not somewhere to put a database.
