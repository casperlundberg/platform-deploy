# What the platform needs

Four workloads, one namespace.

| Workload | Replicas | CPU req | Mem req | Mem limit | Storage |
|---|---|---|---|---|---|
| autoscaler | **1, Recreate** | 100m | 128Mi | 512Mi | 1Gi RWO |
| simlab-api | **1, Recreate** | 200m | 256Mi | 1Gi | — |
| postgres | **1, Recreate** | 100m | 256Mi | 1Gi | 8Gi RWO |
| simlab-web | 1+ | 25m | 32Mi | 128Mi | — |

## Constraints

**Three workloads are strictly single-replica.** The autoscaler would have two
copies driving the same targets from each other's stale state; simlab-api
holds a run in the memory of the process that started it; Postgres can't share
a ReadWriteOnce volume. If the house template sets replicas or a rolling
strategy, these three need exempting.

**Volumes go on Longhorn, never local-path.** `longhorn-single-odin`
preferred. The chart fails the render on anything else, and on an unset value
— two classes are marked default here, so blank doesn't mean "the sensible
one".

**The autoscaler's volume holds credentials in the clear** (`targets.json`,
mode 0600): Kubernetes tokens, ColonyOS keys, Docker certs. No alternative
survives a restart still able to scale. Treat it as secret-bearing.

**Don't buffer the event stream.** `proxy-buffering: "off"` and
`proxy-read-timeout: "86400"` on the ingress. Without them live runs look
frozen, or reconnect every 60s. Nothing is lost, so it goes undiagnosed.

## Ports

Only simlab-web needs to be reachable. Its nginx also proxies `/api`, so one
ingress rule covers everything and the backend needs no CORS.

| Service | Port | Reached by |
|---|---|---|
| simlab-web | 8080 | ingress |
| simlab-api | 8081 | simlab-web |
| autoscaler | 8080 | simlab-api |
| postgres | 5432 | simlab-api |

Outbound, only when a target of that kind is registered: a Kubernetes API, a
ColonyOS server (50080), a Docker daemon (2376 or a unix socket — the socket
means a hostPath mount, which is the cluster's call).

## RBAC

Namespace-scoped Roles, one per namespace in `autoscaler.rbac.namespaces`. No
ClusterRole: this service creates Deployments and reads Secrets, so it should
be able to do that exactly where somebody said so.

| Resource | Verbs |
|---|---|
| `pods` | get, list |
| `apps/deployments` | get, list, create |
| `apps/deployments/scale` | get, patch, update |
| `secrets` | get, create, update |

`deployments/scale` rather than the Deployment, so a scaling write can't touch
the pod template and roll the pool mid-burst. `create` is only for the
`colonyos-k8s` platform, which builds its own executor pools; drop it to run
against pools somebody else manages.

## Credentials

**Deployed:** one token, `api-token`, consumed by both the autoscaler
(`AUTOSCALER_API_TOKEN`) and simlab-api (`SIMLAB_AUTOSCALER_TOKEN`). It is the
most valuable secret here — it grants access to a service that holds *other*
systems' credentials. No default anywhere; `openssl rand -hex 32`. A
SealedSecret in the infra repo.

Plus `database-url` if not using the embedded Postgres.

**Not deployed:** platform access keys (Kubernetes tokens, ColonyOS private
keys, Docker certs) are entered at runtime when somebody registers a target,
and live in the autoscaler's volume. They never come back out of the API —
only a name and a fingerprint — and simlab-api stores none of them.

The browser never holds any of this: simlab-web talks only to simlab-api,
which holds the token.

## What grows

Targets cost autoscaler CPU. Scenario size costs simlab-api memory and
Postgres rows (~3,300 rows per two-hour run). Users cost nothing.
