# Handover to the infrastructure repository

This repo says what the project needs. The infra repo —
`vikingvault-labs/vikingvault-infrastructure` — says what the cluster requires
and owns the ArgoCD Applications, the SealedSecrets, and the templating. The
three Applications are written and live there; this document is now mostly a
record of why each value is what it is, plus the two items still open (7, and
the guard in 2).

Rule of thumb: if the answer would be the same on any cluster it belongs here;
if it would change on a different cluster it belongs there.

`make template VALUES=values/vikingvault.yaml` renders what the three live
Applications render, object for object, **with one deliberate exception: the
image tag.** The values here leave `image.tag` unset, so the chart falls back
to `appVersion` (`0.1.0`, which nothing publishes); the Applications pin a
`sha-` tag, because the tag is what moves on every deploy and pinning one here
would be stale within a day. Item 4 records what is deployed now.

The per-service values those manifests correspond to are in
`values/vikingvault/`, one file per Application — see item 8.
`make check-values` asserts they agree with the umbrella file, and
`make check-argocd` asserts `argocd/` still matches the live Applications.

**Never `helm install` this against vikingvault.** ArgoCD manages it with
selfHeal — a direct install creates a second owner and gets reverted.

## Checklist

**1. Namespace — `autoscale-platform`, and it is live.** As of 2026-09-14 the
namespace exists, both PVCs are Bound, Postgres is Running, and all three
Applications report Synced. The three application pods are `ImagePullBackOff`
on `:0.1.0`, which is the chart's `appVersion` fallback and was never
published — that is the only thing wrong, and item 4 is the fix.

The charts resolve each other by release name, so only `destination.namespace`
changes if another name is wanted.

**2. Storage — set, and not what it should be.** Checked against the cluster
2026-09-14. Both PVCs are Bound, and `storageClassName` on a bound PVC is
**immutable**: changing the value in an Application migrates nothing, it makes
the sync fail on an immutable field. So these match the cluster rather than the
argument.

| Volume | Bound to | Should be |
|---|---|---|
| `platform-autoscaler-state` | `longhorn-single-odin` | `longhorn-hugin` |
| `platform-simlab-api-postgres` | `longhorn-hugin` | fine as is |

The autoscaler's volume is the one worth moving. The infra repo documents
`longhorn-single-odin` as being for "reconstructable / bulk data (prometheus
metrics, loki logs)" — one replica on one tagged disk, no backup target. That
volume is `targets.json`: every registered target and its access keys, in the
clear at mode 0600. Not reconstructable. Losing it means re-entering every
credential by hand while the service sits there healthy, passing its probes,
and unable to scale anything.

Moving it is a migration, and it is not urgent:

1. Scale the autoscaler to 0 so nothing is writing.
2. Copy `/var/lib/autoscaler/targets.json` out of the volume.
3. Delete the PVC, set `storageClassName: longhorn-hugin`, let ArgoCD recreate.
4. Copy the file back, scale up.

Or simply re-register the targets, which is the same work by a different route.

**`local-path` is still a default class**, alongside `longhorn-hugin` —
confirmed, not assumed:

```
NAME                   DEFAULT   PROVISIONER
local-path             true      rancher.io/local-path
longhorn               false     driver.longhorn.io
longhorn-hugin         true      driver.longhorn.io
longhorn-single-odin   <none>    driver.longhorn.io
```

With two defaults Kubernetes takes the most recently created one, so an omitted
class binds to whichever that happens to be — and nothing on the deployed path
catches an omission, because the check that would (`validate-storage.yaml`)
lives in the umbrella chart, which ArgoCD does not render (item 8). Unmarking
`local-path` is a one-line change in `manifests/storage/storage-classes.yaml`
and fixes this for every workload on the cluster, not just this one. It is a
better fix than any chart guard.

**3. The API token — done.** A SealedSecret, `autoscaler-api-token` in
`autoscale-platform`, holding an `api-token` key; read by both
`autoscaler.auth.existingSecret` and `simlab-api.autoscaler.existingSecret` —
the autoscaler owns the API, simlab-api is the caller.

It had been applied by hand and existed nowhere but the cluster. It is now in
the infra repo at
`sealed-secrets/autoscale-platform/autoscaler-api-token-sealed.yaml`, exported
from the live resource, so the ciphertext is unchanged and committing it is a
no-op against the cluster. That directory is watched by the
`sealed-secrets-sync` Application with `prune: true` and `selfHeal: true`,
which is the reason it could not be left out of git.

To rotate it:

```bash
kubectl create secret generic autoscaler-api-token \
  --namespace autoscale-platform \
  --from-literal=api-token="$(openssl rand -base64 32)" \
  --dry-run=client -o yaml \
  | kubeseal --format yaml \
  > sealed-secrets/autoscale-platform/autoscaler-api-token-sealed.yaml
```

Both Deployments restart on a token change — the charts checksum it into the
pod annotations — so a rotation takes effect rather than waiting for the next
unrelated deploy. Nothing renders the token back: the autoscaler's API returns
key names and a SHA-256 fingerprint prefix, never a credential.

**4. Images.** `docker.io/cappelumpa/{autoscaler,simlab-api,simlab-web}` —
Docker Hub account, not the GitHub user. Public, so no pull secret today. Each
service's CI publishes on every push to its `main`; *Images and tags* below
says which tag to deploy and why the choice matters.

Deployed at the time of writing (2026-09-14), each the tip of its `main`:

| Service | Tag |
|---|---|
| autoscaler | `sha-d02c1162d08bc5ab7ba2288700c4d8252e74bbf8` |
| simlab-api | `sha-01a03f5580fc920db92aa43df1dbcdeb5c79c255` |
| simlab-web | `sha-197b9794206d748d7b15ecf963e8cb3935040f4e` |

**5. Ingress — `decay.vikingvault.dev`.** One rule, `/` to simlab-web, which
proxies `/api` to simlab-api itself. One host and not two: the browser sees a
single origin, the API needs no CORS, and no platform credential ever reaches
the browser. `nginx` is the only class and is default; TLS via the
`letsencrypt-prod` cluster issuer into `autoscale-platform-tls`.

The name is reused from the decommissioned mining simulator: that Cloudflare
record was never deleted and still resolves to the cluster. **It is also the
one in the DDNS updater's refresh list**
(`manifests/networking/cloudflare-ddns-updater.yaml`), which is the reason to
keep it. `simlab.vikingvault.dev` resolves too, and resolves the way the other
apps do — to Cloudflare's addresses rather than straight to the apex A record —
but it is *not* in that list, so it would go stale the next time the external
IP changed. Moving to it means adding one line there first.

Two annotations are load-bearing and the chart sets them itself:
`proxy-buffering: "off"` and `proxy-read-timeout: "86400"`. Without them the
live event stream is buffered and a running simulation looks frozen until it
finishes.

Never leave `ingress.host` empty. The chart renders `host: ""`, which is a rule
matching every host that reaches the controller — on a cluster running this
many Applications that is not a harmless default.

**5a. The Simlab API is on the public internet with no authentication —
decide.** Confirmed against the deployment on 2026-09-16, not inferred:

```
POST https://simlab.vikingvault.dev/api/mines   (no Authorization header)  -> 200
GET  https://simlab.vikingvault.dev/api/targets (no Authorization header)  -> 200
```

The autoscaler's own API is properly guarded; this is not that. simlab-web's
nginx proxies `/api` to simlab-api, simlab-api has no authentication of its own,
and the Ingress publishes it. So anyone who knows the hostname can create,
start and delete mines, scenarios and runs.

The part that makes it more than nuisance: **simlab-api holds the autoscaler
token and proxies to it.** `/api/targets` is a write endpoint on that path, so
an anonymous caller reaches an authenticated autoscaler through it. On a
deployment whose targets are all simulation that costs compute and other
people's experiments. Point one target at a real Kubernetes namespace or
ColonyOS colony and the same path reaches real infrastructure.

Three ways to close it, cheapest first:

- **Put authentication in front of the Ingress.** `nginx.ingress.kubernetes.io/auth-*`
  annotations with a basic-auth Secret, or the cluster's existing
  `auth-proxy.vikingvault.dev`. Nothing in this project changes.
- **Take the Ingress off** and reach it with `kubectl port-forward`, as
  `values/local.yaml` does. Costs the browser being reachable from anywhere.
- **Give simlab-api its own authentication.** The honest fix, and the only one
  that survives the Ingress being reconfigured by someone who did not read this,
  but it is a change to the service rather than to the deployment.

Until one is chosen, treat the hostname as the only thing standing between the
open internet and a service that can drive an autoscaler.

**6. Single-replica workloads.** autoscaler, simlab-api and Postgres are each
one replica with `Recreate`. Exempt them from any house template that sets
replicas or a rolling strategy.

**7. RBAC namespaces — decide.** `autoscaler.rbac.namespaces` defaults to
empty, meaning the autoscaler can only act in its own namespace. Right
default, probably not what a real deployment wants.

**8. Where ArgoCD reads the charts — done: one Application per service repo.**
Live in `vikingvault-infrastructure/devops/argocd-applications/` as
`autoscale-platform-autoscaler.yaml`, `-simlab-api.yaml` and `-simlab-web.yaml`.
The app-of-apps in that directory picks them up on its own; nothing needs
applying by hand. `argocd/` here holds copies, and `make check-argocd` fails if
they drift.

The umbrella chart cannot be the source: its dependencies are `file://` paths
to the sibling repos, and ArgoCD's repo-server has no siblings to resolve them
against. Each service chart has no dependencies at all, so ArgoCD renders it
straight from `deploy/chart` in its own repository. All three service repos are
public, so this needs no repository credential — ArgoCD's configured Git
secrets only cover `vikingvault-labs`.

Values are inlined under `helm.values` in each Application, which is how every
other Application in that repo is written. A two-source Application with this
repo as `$values` would avoid restating them, but matching the house style of
39 existing Applications is worth more than avoiding a copy that
`make check-argocd` already guards.

Three things this costs:

- **Every Application pins the same Helm release name.** ArgoCD defaults it to
  the Application name, and the charts find each other through `.Release.Name`:
  simlab-api looks for `<release>-autoscaler`, simlab-web for
  `<release>-simlab-api`. Left to default, `autoscale-platform-autoscaler`
  would create a Service called `autoscale-platform-autoscaler-autoscaler` and
  nothing would match anything. All three pin `releaseName: platform`, giving
  `platform-autoscaler`, `platform-simlab-api`, `platform-simlab-web`. The
  values additionally write both cross-service addresses out in full, so a
  rename fails in a file that names it rather than silently at run time.
- **The storage guard does not run.** See item 2. The honest fix is to move the
  check into the three service charts, where each would then be correct
  standing alone.
- **Ordering is per-Application.** Sync waves sequence resources inside one
  Application, not three Applications against each other — but these three are
  children of the app-of-apps (itself wave `-1`), so waves `0`, `1`, `2` do
  order them: autoscaler, then simlab-api, then simlab-web.

`values/vikingvault.yaml` and the umbrella chart both stay: they are what
`make verify`, `make lint` and `make template` use, and they remain the single
readable statement of the whole environment. `make check-values` renders both
paths and asserts they produce the same manifests.

**The OCI route is still the simpler end state**, and it is a small move from
here: publish the three service charts, replace the `file://` repositories in
`charts/autoscale-platform/Chart.yaml` with OCI references, and collapse to the
single Application in `argocd/autoscale-platform.yaml`, kept for exactly that.
It removes all three costs above at once.

**9. Sync policy.** House style throughout: `prune: true`, `selfHeal: true`,
`allowEmpty: false`, and the standard retry backoff.

The autoscaler additionally carries `ApplyOutOfSyncOnly=true`. It writes
Secrets of its own — ColonyOS executor keys its pods read — which are not
chart-managed, and deleting them crash-loops every executor. The other two have
nothing unmanaged to protect.

All three ask to create the shared namespace, which is idempotent. The tidier
alternative is for the infra repo to own `autoscale-platform` itself and for
all three to drop `CreateNamespace=true`.

## Before you start

`make verify` runs the whole platform locally in about a minute, so any
problem afterwards is known to be a deployment problem rather than an
application one.

## Images and tags

Each service's CI builds its Dockerfile on every push to `main`, behind that
repository's own test job, and pushes to Docker Hub:
`docker.io/cappelumpa/autoscaler`, `docker.io/cappelumpa/simlab-api`,
`docker.io/cappelumpa/simlab-web`. Two tags per build, and they are not
interchangeable:

- `sha-<full commit sha>` — one commit, one image, never rewritten.
- `main` — moved to the newest build.

**Deploy the `sha-` tag.** A manifest that names `main` renders identically on
every build, and ArgoCD syncs on a manifest diff: it would see nothing to do,
and with `IfNotPresent` against an unchanged tag the running pods would not
pull the new image either. The deploy has to be a change to the tag itself.

So the infra repo names the exact commit it intends to run. **That is now
written automatically.** Each service's CI has a `deploy` job that, after its
image is published, commits the new `sha-` tag into that service's Application
in this infra repo; ArgoCD picks the commit up on its next reconcile. The
deploy is therefore an ordinary reviewable commit in the GitOps repo, and
ArgoCD remains the only thing that writes to Kubernetes.

The job moves one line and refuses to commit anything else — it checks that
exactly one file changed, that exactly one line changed, and that the changed
line is a pinned tag. That matters because the credential it runs with is a
classic PAT, which is broader than this one file: the narrowness is enforced
by the job, not by the token.

It needs `INFRA_REPO_TOKEN` in each of the three service repositories. Without
it the job skips and says so rather than failing the build, so builds stay
green until the token exists — but nothing is deployed.

Left empty each chart falls back to its `appVersion`, `0.1.0`, which nothing
publishes and which fails as `ImagePullBackOff`. That is not hypothetical: it
is what the cluster did for 45 hours, because the loop this job closes did not
exist and nobody had moved the tag by hand.

The three services do not share a tag. They are separate repositories with
separate histories, so a push to one moves one tag and the other two keep the
commit they were on, which is the intended behaviour rather than a gap.

Publishing needs two repository secrets in each of the three service
repositories: `DOCKERHUB_USERNAME`, the Docker Hub account, and
`DOCKERHUB_TOKEN`, an access token on it with write access to the
`cappelumpa` namespace. This repository needs neither — it publishes nothing
and its CI only lints and renders. None of it reaches the cluster either: the
images are public and there is still no pull secret.
