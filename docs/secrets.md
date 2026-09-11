# Credentials

Every secret this platform needs, what it unlocks, and what happens if it
leaks. Sealing and storing them is the infrastructure repository's job; naming
them and saying what they are for is this one's.

## The ones the platform needs to start

### `autoscaler-api-token`

| | |
|---|---|
| Key | `api-token` |
| Used by | autoscaler (`AUTOSCALER_API_TOKEN`), simlab-api (`SIMLAB_AUTOSCALER_TOKEN`) |
| Chart values | `autoscaler.auth.existingSecret`, `simlab-api.autoscaler.existingSecret` |

One token, two consumers: the autoscaler requires it on every endpoint except
the probes, and simlab-api presents it on every call.

**It is the most valuable secret here.** It does not merely grant API access —
it grants access to a service that holds *other* systems' credentials:
Kubernetes bearer tokens, ColonyOS executor private keys, Docker client
certificates. Anyone with this token can register a target, and a target is
somewhere to send credentials.

Generate with `openssl rand -hex 32`. There is no default anywhere in the
charts, deliberately: a chart that shipped one would ship a well-known
credential, and one that generated it silently would leave nobody able to say
what it is.

The autoscaler's pod restarts when this Secret changes, so a rotation takes
effect rather than waiting for the next unrelated deploy. Rotate both
consumers together; there is no grace period where the old and new are both
accepted.

### `simlab-database-url` *(only when not using the embedded Postgres)*

| | |
|---|---|
| Key | `database-url` |
| Used by | simlab-api (`SIMLAB_DATABASE_URL`) |
| Chart value | `simlab-api.database.existingSecret` |

A full connection string, password included — which is why it is a Secret
rather than a value. With the embedded Postgres enabled the chart generates
this itself from `database.embedded.*` and no external Secret is needed.

## The ones that arrive later, at runtime

These are **not** deployed. They are entered when somebody registers a target,
through the UI or the API, and the autoscaler stores them in its own state
file. They are listed here because the infrastructure repository needs to know
they exist, and because the volume holding them needs treating accordingly.

| Platform | Credentials it asks for |
|---|---|
| `kubernetes` | `bearer_token` — a ServiceAccount token permitted to get deployments and pods, and patch deployments/scale, in the target namespace |
| `colonyos-k8s` | the same, plus `colonies_prvkey` — a hex ColonyOS executor private key |
| `colonyos-container` | `colonies_prvkey`, plus `docker_tls_cert` / `docker_tls_key` / `docker_tls_ca` for a TLS-protected daemon, and optionally `registry_auth` |
| `simulation` | none |

Three things follow from this:

**The autoscaler's PVC is secret-bearing.** `targets.json` holds these in the
clear, mode 0600. There is no alternative that survives a restart still able
to scale anything — a registry that stored them redacted would come back
useless. Give the volume the same protection as a Secret: encrypted storage if
the cluster offers it, and no casual snapshot sharing.

**They never come back out.** The API returns a key's name and a SHA-256
fingerprint prefix, never a value, enforced in the type's `MarshalJSON` so
every reporting path is covered — API responses, log lines, error messages. A
target read back and submitted again keeps its stored credentials rather than
wiping them.

**They do not pass through simlab-api's storage.** simlab-api proxies target
registration to the autoscaler and stores nothing; its Postgres contains no
credentials of any kind.

## Why the browser never holds any of this

simlab-web talks only to simlab-api. simlab-api holds the autoscaler token and
makes every call. The alternative — a browser calling the autoscaler directly
— would mean shipping that token to a browser, and a token in a browser is a
token that has been disclosed.

## Sealing them for vikingvault

SealedSecrets live in the infrastructure repository under
`sealed-secrets/<namespace>/`, and are committed rather than applied — the
encryption key is cluster-specific, and git stays the single source of truth.

```bash
kubectl create secret generic autoscaler-api-token \
  --namespace <namespace> \
  --from-literal=api-token="$(openssl rand -hex 32)" \
  --dry-run=client -o yaml \
| kubeseal --format yaml \
> sealed-secrets/<namespace>/autoscaler-api-token.yaml
```

Then commit it to the infra repo. Do not `kubectl apply` the result directly,
even though a SealedSecret is harmless in transit: the point is that live
state and git never disagree about which is authoritative.
