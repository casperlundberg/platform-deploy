# Handover to the infrastructure repository

This repo says what the project needs. The infra repo says what the cluster
requires and owns the ArgoCD Application, the SealedSecrets, and the
templating.

Rule of thumb: if the answer would be the same on any cluster it belongs here;
if it would change on a different cluster it belongs there.

`make template VALUES=values/vikingvault.yaml` renders the manifests the infra
repo has to reproduce, in whatever form it prefers.

**Never `helm install` this against vikingvault.** ArgoCD manages it with
selfHeal — a direct install creates a second owner and gets reverted.

## Checklist

**1. Namespace — `autoscale-platform`.** Checked 2026-09-11: the previous
incarnation of this project is entirely gone from the cluster — no namespaces,
no Applications, no released volumes. Clean sheet, own namespace. The charts
resolve each other by release name, so only `destination.namespace` changes if
another name is wanted.

**2. Storage — Longhorn only, `longhorn-single-odin` preferred.** Set on
`autoscaler.persistence` and `simlab-api.database.embedded`. The chart fails
the render otherwise, including on an unset value.

Worth knowing before accepting the default: that class is one replica on one
tagged disk (`odin-worker-2/disk-4`), and there is no Longhorn backup target or
recurring snapshot job configured. Losing it costs re-entering target
credentials, and the record of past runs — though not the ability to reproduce
them, since scenarios carry seeds. **Decide whether that's acceptable.** Both
fixes stay in policy: configure a backup target, or put the Postgres on
`longhorn-hugin` (3 replicas).

**3. The API token.** One SealedSecret, `api-token`, referenced by
`autoscaler.auth.existingSecret` and `simlab-api.autoscaler.existingSecret`.
Must exist before first sync. Unset, the autoscaler runs unauthenticated while
holding other systems' credentials.

**4. Images.** `docker.io/cappelumpa/{autoscaler,simlab-api,simlab-web}` —
Docker Hub account, not the GitHub user. Public, so no pull secret today.
Nothing publishes them yet.

**5. Ingress.** One rule, `/` to simlab-web, which proxies `/api` itself.
`nginx` is the only class and is default. Two annotations are load-bearing:
`proxy-buffering: "off"` and `proxy-read-timeout: "86400"`, or live runs look
frozen.

**6. Single-replica workloads.** autoscaler, simlab-api and Postgres are each
one replica with `Recreate`. Exempt them from any house template that sets
replicas or a rolling strategy.

**7. RBAC namespaces — decide.** `autoscaler.rbac.namespaces` defaults to
empty, meaning the autoscaler can only act in its own namespace. Right
default, probably not what a real deployment wants.

**8. Where ArgoCD reads the chart — decide.** The umbrella chart's
dependencies are `file://` paths to the sibling repos, which won't resolve for
ArgoCD's repo-server. Either publish the three service charts to an OCI
registry and switch `Chart.yaml`, or reproduce the manifests in the infra repo
in house style. Both fine.

**9. Sync policy.** The autoscaler writes Secrets of its own (ColonyOS
executor keys its pods read). Not chart-managed — don't let pruning delete
them, or every executor pod crash-loops. `ApplyOutOfSyncOnly=true` covers it.

## Before you start

`make verify` runs the whole platform locally in about a minute, so any
problem afterwards is known to be a deployment problem rather than an
application one.
