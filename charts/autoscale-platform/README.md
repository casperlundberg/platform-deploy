# The umbrella chart

Composes the three service charts into one namespace. It is a reference
implementation — it installs, and `../../verify.sh` proves the result works —
not the thing the vikingvault cluster deploys. See the repository README for
that distinction.

## Rendering it

```bash
make deps
make template VALUES=values/vikingvault.yaml
```

`out/vikingvault.yaml` is then the complete set of manifests, which is the
most useful artefact this chart produces: it is what the infra repo needs to
reproduce, in whatever form that repo prefers.

## Installing it locally

```bash
make install-local VALUES=values/local.yaml
```

Local clusters only. On an ArgoCD-managed cluster a direct install creates a
second owner and `selfHeal` reverts it.

## Why the dependencies are file:// paths

The service charts live with their services, in sibling repositories. That
keeps a chart change and the code change that needs it in one commit, and
stops `appVersion` drifting from what it actually deploys. The cost is that
this chart needs those repositories checked out to build.

For an install from a registry, replace each `repository:` in `Chart.yaml`
with the OCI reference the charts are published to. Nothing else about the
chart changes.

It is also why this chart is not what ArgoCD deploys: its repo-server has no
sibling repositories to resolve `file://` against, so the cluster is deployed
from one Application per service chart instead. Item 8 in
`../../docs/infra-handover.md` has the comparison, and publishing to OCI is
what would let this chart take over.

## What it deliberately leaves unset

Storage class, ingress class, node selectors, image pull secrets and
tolerations have no defaults here. They are cluster properties, not project
properties, and a default would be this project quietly asserting a policy it
does not own. `values/vikingvault.yaml` fills them in for that specific
cluster; `docs/infra-handover.md` lists them with the consequence of getting
each one wrong.
