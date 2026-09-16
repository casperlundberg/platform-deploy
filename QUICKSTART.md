# Deploying your own instance

Everything ships as OCI artifacts on Docker Hub — the chart as well as the
images — so you need no repository access, no checkout, and nothing built
locally. No key generation, no secrets to create, no DNS, no certificates.

## What you need

- A Kubernetes cluster you can install into: k3d, kind, minikube or Docker
  Desktop are all fine. It needs a default StorageClass; those all ship exactly
  one.
- `helm` 3.8 or newer (OCI support) and `kubectl`.

## Install

```bash
TOKEN=$(openssl rand -hex 16)      # or any string; it just has to match below

helm install platform \
  oci://registry-1.docker.io/cappelumpa/autoscale-platform --version 0.1.0 \
  --namespace autoscale-platform --create-namespace \
  --set storage.requireLonghorn=false \
  --set autoscaler.auth.token="$TOKEN" \
  --set simlab-api.autoscaler.token="$TOKEN"
```

Timed on a fresh k3d cluster: **helm returns in about half a second, and all
four pods are Running roughly 70 seconds later.**

Three flags and why each is needed:

| Flag | Why |
|---|---|
| `storage.requireLonghorn=false` | The chart refuses a non-Longhorn volume by default, because this project's own cluster has two default StorageClasses and picking the wrong one silently loses data. A laptop cluster has no Longhorn, so the check is waived. |
| `autoscaler.auth.token` | The autoscaler's API holds other systems' credentials, so the chart ships no default token. Pick any string. |
| `simlab-api.autoscaler.token` | **The same string.** simlab-api is a client of that API and needs the same credential. |

Those last two are two ends of one credential. Setting one and not the other
used to produce a system that looked perfectly healthy — four pods Running, the
UI loading — in which every run failed with a 401 visible only in a log. The
chart now refuses to render in that state and tells you what to set, but it is
worth knowing why they are both there.

## Watch it come up

```bash
kubectl -n autoscale-platform get pods -w
```

**`simlab-api` will crash-loop two or three times first.** That is expected and
resolves itself: it refuses to start without a reachable database, Postgres
takes a few seconds longer than it does, and Kubernetes restarts it until the
database answers:

```
simlab-api: the database is not reachable: failed to connect to
`user=simlab database=simlab`: connection refused
```

Refusing to start is deliberate — a service that came up and failed every run
instead would be harder to diagnose than one that says why it will not start.

## Use it

Nothing is exposed by default. Reach the app with a port-forward:

```bash
kubectl -n autoscale-platform port-forward svc/platform-simlab-web 8080:8080
```

Then open <http://localhost:8080>. The SPA proxies `/api` itself, so that one
port is the whole application: define a mine, define a scenario, launch a run,
and watch the autoscaler decide. Every decision carries the reasoning that
produced it.

## Uninstall

```bash
helm uninstall platform --namespace autoscale-platform
kubectl delete namespace autoscale-platform      # also drops the volumes
```

## What this install is not

It is self-contained on purpose, and three of those choices are wrong anywhere
that outlives a demo:

- **The token is on the command line**, so it is in your shell history. A real
  deployment points both `autoscaler.auth.existingSecret` and
  `simlab-api.autoscaler.existingSecret` at one Secret it manages itself.
- **Postgres comes with it**, one replica, no backups. Point
  `simlab-api.database.url` at a managed instance instead.
- **The Longhorn check is off.** It exists because an unset storage class binds
  to whichever class the cluster happens to default to, and the wrong one
  silently loses the autoscaler's stored credentials on a reschedule.

`docs/requirements.md` lists what the platform actually needs, and
`docs/infra-handover.md` lists every decision a cluster owns, with what each
costs if it is wrong.

## Installing a specific build

`--version` selects the chart. Each published chart pins the exact service
images it was built from, so a given chart version always deploys the same
code — there is no floating tag to drift underneath it.

```bash
helm show chart oci://registry-1.docker.io/cappelumpa/autoscale-platform --version 0.1.0
```
