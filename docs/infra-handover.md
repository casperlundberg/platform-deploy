# Handover to the infrastructure repository

Everything this project cannot decide for itself, why each one is the
cluster's decision rather than the project's, and what goes wrong if it is
left unset.

This is a checklist to work through when populating
`vikingvault-labs/vikingvault-infrastructure` with the ArgoCD Application and
whatever templated charts that repository's conventions call for.

## The division

| This repository decides | The infrastructure repository decides |
|---|---|
| Which services exist, and how they compose | Which namespace they land in |
| What each one needs: CPU, memory, storage size | Which storage class, which nodes |
| Which credentials exist and what they unlock | How they are sealed and where they live |
| Which ports, and which service may reach which | NetworkPolicies, if any |
| That the event stream must not be buffered | Which ingress controller and annotations |
| That three workloads are strictly single-replica | Sync policy, pruning, self-heal |
| Which images, by name | Which registry, and the pull secret |

The rule of thumb: if the answer would be the same on any cluster, it belongs
here. If it would change on a different cluster, it belongs there.

## Checklist

### 1. Namespace — decision required

The standing convention on vikingvault is that a new service joins
`priority-decay-journal` rather than taking a namespace of its own.

There is a genuine argument for isolating this platform instead: the
autoscaler holds credentials for other systems, creates Deployments, and reads
Secrets. Its RBAC and its blast radius are unlike anything else in that
namespace, and a namespace boundary is the cheapest way to keep them apart.

Either works. The charts are namespace-agnostic and resolve each other by
release name. **Decide deliberately rather than inheriting the default in
`argocd/autoscale-platform.yaml`.**

If the platform *does* go into `priority-decay-journal`, note that the release
name prefixes every resource, so `platform-autoscaler` and friends will not
collide with anything already there.

### 2. Storage class — required, no default possible

Two StorageClasses are marked default on this cluster (`local-path` and
`longhorn-hugin`), so a PVC with no explicit class binds unpredictably. This
is not a "pick a sensible default" situation; there is no sensible default to
pick.

Set on both:
- `autoscaler.persistence.storageClassName`
- `simlab-api.database.embedded.storageClassName`

`values/vikingvault.yaml` uses `longhorn-single-odin`, which is what the rest
of this project uses.

**If left unset:** the PVC stays Pending forever and nothing in the pod's
events explains why.

### 3. The autoscaler's volume is secret-bearing

It holds `targets.json`: every registered target's Kubernetes bearer tokens,
ColonyOS private keys and Docker client certificates, in the clear, mode 0600.
There is no alternative that survives a restart still able to scale anything.

Treat it as a Secret would be treated — encrypted storage if available, no
casual snapshot sharing. If that is unacceptable, the alternative is to run
the autoscaler with no persistence and re-register targets after every
restart, which is workable only for simulation-only use.

### 4. The API token — must be created before first sync

One SealedSecret, consumed by two services. See
[`secrets.md`](secrets.md) for what it unlocks and the `kubeseal` command.

Set both:
- `autoscaler.auth.existingSecret`
- `simlab-api.autoscaler.existingSecret`

**If left unset:** the autoscaler starts unauthenticated and logs a warning
saying so. It will work. It should not be allowed to, because it holds other
systems' credentials.

### 5. Registry and image pull

Images are named `autoscaler`, `simlab-api` and `simlab-web`. The registry is
Docker Hub under **`cappelumpa`** — that is the Docker Hub account, not the
GitHub user `casperlundberg`, and the two have been confused before.

The repository is public, so no pull secret is needed today. If that changes,
`imagePullSecrets` is exposed on all three charts.

Nothing publishes these images yet. Whichever CI does so needs to keep four
things in step — the same rule the rest of this project already follows for
its image tags.

### 6. Ingress — one rule is enough

Only simlab-web needs to be reachable. Its nginx serves the app and proxies
`/api` to simlab-api itself, so a single `/` rule covers everything and the
backend needs no CORS.

Two annotations are load-bearing rather than cosmetic:

```yaml
nginx.ingress.kubernetes.io/proxy-buffering: "off"
nginx.ingress.kubernetes.io/proxy-read-timeout: "86400"
```

**If omitted:** live runs appear frozen and then arrive all at once, or the
page reconnects every sixty seconds. Nothing is lost — the client re-reads
from the database — so it presents as a UI that feels broken, and goes
undiagnosed for a long time. See [`networking.md`](networking.md).

### 7. Single-replica workloads — do not scale these

`autoscaler`, `simlab-api` and the embedded Postgres are each strictly one
replica with `strategy: Recreate`, for three different and non-negotiable
reasons set out in [`resources.md`](resources.md). If the infra repo's house
template sets a replica count or a rolling strategy by default, these three
need exempting.

simlab-web can be scaled freely and gains nothing from it.

### 8. RBAC — decide which namespaces the autoscaler may provision into

`autoscaler.rbac.namespaces` defaults to empty, meaning the autoscaler can act
only in its own namespace. That is the right default and probably not what a
real deployment wants.

Roles are namespace-scoped, one per listed namespace. A ClusterRole is
deliberately not offered: this service creates Deployments and reads Secrets,
and it should be able to do that exactly where somebody has said so. The verb
list and its justification are in [`resources.md`](resources.md).

### 9. Where ArgoCD reads the chart from — decision required

The umbrella chart depends on three charts that live with their services, via
`file://` paths that expect sibling checkouts. ArgoCD's repo-server has no
sibling checkouts, so pointing an Application straight at this repository will
not resolve them.

Two workable shapes, both fine:

1. **Publish the three service charts** to an OCI registry and switch
   `Chart.yaml`'s `repository:` entries to OCI references. The Application
   then points here and everything resolves.
2. **Reproduce the manifests in the infra repo**, as a templated chart in
   house style. Closer to how the rest of this project is deployed, where the
   infra repo holds the Application and the chart lives with the service.

`make template VALUES=values/vikingvault.yaml` produces the complete manifest
set that either approach has to reproduce. Diff against it after any change
here.

### 10. Sync policy — one thing to know

The autoscaler creates Secrets of its own, in its namespace, holding the
ColonyOS executor keys its provisioned pods read. Those are not chart-managed
and must not be pruned as though they had gone missing from git.

`ApplyOutOfSyncOnly=true` covers it; so would excluding Secrets from pruning.
The failure mode if neither is set is that ArgoCD deletes the key Secret and
every executor pod crash-loops unable to join its colony.

## Before you start

Run `make verify` once. It builds both services, runs them for real against a
Postgres, and checks the platform does what it claims. It takes about a minute
and it is the fastest way to see what the manifests are supposed to produce —
and to be sure any problem you hit afterwards is a deployment problem rather
than an application one.
