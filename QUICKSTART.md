# Deploying your own instance

No key generation, no secrets to create, no DNS, no certificates. A
self-contained install brings its own Postgres and its own development token.

Timed on a fresh k3d cluster: **helm returns in under a second, and all four
pods are Running about 60 seconds later.**

## What you need

- A Kubernetes cluster you can `helm install` into — k3d, kind, minikube or
  Docker Desktop are all fine. It must have a default StorageClass; the ones
  above all ship exactly one.
- `helm` 3 and `kubectl`.
- The four repositories checked out **side by side**. This is the only real
  friction, and it is because the umbrella chart composes the three service
  charts through `file://` paths — each service's chart lives with its service
  so a chart change and the code change needing it land in one commit.

```bash
mkdir autoscale-platform && cd autoscale-platform
for r in autoscaler simlab-api simlab-web platform-deploy; do
  git clone https://github.com/casperlundberg/$r.git
done
```

## Install

```bash
cd platform-deploy
make install-local          # values/local.yaml by default
```

Then watch it come up:

```bash
kubectl -n autoscale-platform get pods -w
```

**`simlab-api` will crash-loop two or three times first.** That is expected and
resolves itself: it refuses to start without a reachable database, Postgres
takes a few seconds longer than it does, and Kubernetes restarts it until the
database answers. The log says exactly that:

```
simlab-api: the database is not reachable: failed to connect to
`user=simlab database=simlab`: connection refused
```

Refusing to start is deliberate. A service that came up and failed every run
instead would be harder to diagnose than one that says why it will not start.

## Use it

`values/local.yaml` leaves the Ingress off, so nothing is exposed. Reach the
app with a port-forward:

```bash
kubectl -n autoscale-platform port-forward svc/platform-simlab-web 8080:8080
```

Then open <http://localhost:8080>. The SPA proxies `/api` itself, so that one
port is the whole application.

## Check it actually works

```bash
make e2e
```

43 checks against the deployment: CRUD on mines, scenarios, runs and targets,
and the path where the Simlab backend drives the real autoscaler. It creates
only its own rows and removes them again, so it is safe to run against an
instance that has real data in it. See [`e2e/README.md`](e2e/README.md).

## Uninstall

```bash
make uninstall-local
kubectl delete namespace autoscale-platform     # also drops the volumes
```

## What is deliberately different from a real deployment

`values/local.yaml` is for a laptop and is **not** a starting point for anything
real. Three things in it would be wrong anywhere else:

| | local | why it differs |
|---|---|---|
| `auth.token` | a literal in the file | a real install uses `existingSecret`, because a token in a values file is a token in a git history |
| `image.tag` | `main` | a GitOps deploy must pin `sha-<commit>`: a manifest naming `main` never changes, so ArgoCD sees nothing to sync and the new image is never rolled out |
| `storage.requireLonghorn` | `false` | waived only because a laptop has no Longhorn; every real environment leaves the check on |

For a real deployment, copy `values/vikingvault.yaml` instead and read
[`docs/infra-handover.md`](docs/infra-handover.md), which lists every decision
the cluster owns and what each one costs if it is wrong.

## Without Kubernetes at all

To see the system work without a cluster:

```bash
make verify        # needs Docker and Go, takes about a minute
```

It builds both services, runs them against a real Postgres, and replays one
scenario under two policies.
