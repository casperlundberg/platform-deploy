# platform-deploy

What the autoscale platform needs in order to run, and a working reference
implementation of it.

## What this repository is, and what it is not

This repository holds **the project's side of the deployment contract**: which
services exist, what resources they need, which credentials they require and
what each one unlocks, how they find each other, and what breaks if a
particular value is left unset. It is the answer to *what does this project
need?*

It is **not** the GitOps source of truth. On the vikingvault cluster that is
`vikingvault-labs/vikingvault-infrastructure`, which holds the ArgoCD
Applications, the SealedSecrets, and whatever templating the cluster's own
conventions call for. That repository is the answer to *what does this cluster
require?* — ingress class, storage class, node selectors, image pull policy,
security baselines, naming, sync policy.

```
       this repository                      the infrastructure repository
  ┌──────────────────────────┐          ┌──────────────────────────────────┐
  │ what the project needs   │          │ what the cluster requires        │
  │                          │          │                                  │
  │ • the services and how   │  ──────▶ │ • ArgoCD Application             │
  │   they compose           │          │ • SealedSecrets                  │
  │ • CPU, memory, storage   │          │ • storage class, ingress class   │
  │ • every credential, and  │          │ • node selectors, tolerations    │
  │   what it unlocks        │          │ • sync policy, naming, projects  │
  │ • ports and dependencies │          │ • whatever templating it uses    │
  │ • a reference chart that │          │                                  │
  │   demonstrably works     │          │                                  │
  └──────────────────────────┘          └──────────────────────────────────┘
```

The chart here is a **reference**: it installs and it is verified to work, so
it settles what the manifests actually have to contain. Copy from it, template
over it, or rewrite it to house style — whichever the infra repo prefers.
[`docs/infra-handover.md`](docs/infra-handover.md) is the checklist of what
the infra repo must decide, and why each item is its decision rather than
this repository's.

**Never `helm install` this against the vikingvault cluster.** It is
ArgoCD-managed with `selfHeal` on: a direct install creates a second owner and
gets silently reverted. The chart here is for local clusters and for rendering
manifests to read. Real deployment goes through the infra repo.

## Contents

| Path | What it is |
|---|---|
| [`charts/autoscale-platform/`](charts/autoscale-platform) | The umbrella chart. Composes the three service charts, which live with their services. |
| [`values/`](values) | Per-environment values. `local.yaml` for a laptop cluster, `vikingvault.yaml` filled in with that cluster's real standards. |
| [`argocd/`](argocd) | An ArgoCD Application, written as the infra repo would need it. A reference, not a deployed object. |
| [`docs/resources.md`](docs/resources.md) | What each service needs and why. Start here. |
| [`docs/secrets.md`](docs/secrets.md) | Every credential, what it unlocks, and how to seal it. |
| [`docs/networking.md`](docs/networking.md) | Ports, who talks to whom, and what must not be buffered. |
| [`docs/infra-handover.md`](docs/infra-handover.md) | The checklist for the infra repo. |
| [`verify.sh`](verify.sh) | Runs the whole platform locally and checks it does what it claims. |

## Quick start

```bash
make verify      # build both services, run them for real, check the result
make lint        # lint the umbrella chart
make template    # render the manifests for reading or diffing
```

`make verify` takes about a minute and needs Docker and Go. It ends with the
argument for the whole system:

```
✓ both runs replayed the identical 13071 jobs — the seed held
✓ cloud burst cut SLA breaches from 10689 to 1489
✓ and it cost 62.3 cloud executor-hours to do it
```

## The repositories

Checked out side by side:

```
autoscale-platform/
├── autoscaler/        the scaling controller           (chart: deploy/chart)
├── simlab-api/        workload replay + results        (chart: deploy/chart)
├── simlab-web/        the browser app                  (chart: deploy/chart)
└── platform-deploy/   this repository
```

Each service's chart lives with the service, so a chart change and the code
change that needs it land in one commit, and the chart's `appVersion` cannot
drift from what it deploys. This repository composes them; it does not own
them.
