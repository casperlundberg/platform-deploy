#!/usr/bin/env bash
#
# Print the deployed platform's API token and base URLs, as shell exports.
#
#   eval "$(scripts/simlab-env.sh)"        # into this shell
#   scripts/simlab-env.sh --json           # for anything that is not a shell
#
# The token is read from the cluster Secret the services themselves read, so it
# is always the one actually in force -- not a copy that drifted. It is never
# written to a file here; if you want it in a file, redirect it yourself and
# remember that you have.
#
# The Secret's name depends on how the platform was installed: a cluster using
# auth.existingSecret has whatever name it chose, and a self-contained install
# has the chart generate <release>-autoscaler-api-token. Both are found.
set -euo pipefail

NAMESPACE="${SIMLAB_NAMESPACE:-autoscale-platform}"
FORMAT=text
PUBLIC_URL="${SIMLAB_PUBLIC_URL:-}"

while [ $# -gt 0 ]; do
    case "$1" in
        --json)      FORMAT=json; shift ;;
        --namespace) NAMESPACE="$2"; shift 2 ;;
        -h|--help)   sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "namespace $NAMESPACE not found in context '$(kubectl config current-context 2>/dev/null)'" >&2
    echo "set SIMLAB_NAMESPACE, or switch context" >&2
    exit 1
fi

secret=$(kubectl get secret --namespace "$NAMESPACE" --no-headers \
    -o custom-columns=NAME:.metadata.name 2>/dev/null \
    | grep -E '(^|-)autoscaler-api-token$' | head -1 || true)

if [ -z "$secret" ]; then
    echo "no *autoscaler-api-token Secret in $NAMESPACE -- is the platform installed?" >&2
    exit 1
fi

token=$(kubectl get secret "$secret" --namespace "$NAMESPACE" \
    -o jsonpath='{.data.api-token}' 2>/dev/null | base64 -d)

if [ -z "$token" ]; then
    echo "Secret $secret has no api-token key" >&2
    exit 1
fi

# The public URL, if an Ingress exposes the SPA. Its nginx proxies /api, so one
# host serves the whole application -- which is why there is no separate API
# hostname to look up.
if [ -z "$PUBLIC_URL" ]; then
    host=$(kubectl get ingress --namespace "$NAMESPACE" \
        -o jsonpath='{.items[0].spec.rules[0].host}' 2>/dev/null || true)
    [ -n "$host" ] && PUBLIC_URL="https://$host"
fi

# In-cluster addresses, for anything running as a pod in this namespace.
release=${secret%-autoscaler-api-token}
[ "$release" = "$secret" ] && release=platform      # existingSecret, name says nothing

if [ "$FORMAT" = json ]; then
    python3 - "$token" "$PUBLIC_URL" "$release" "$NAMESPACE" "$secret" <<'PY'
import json, sys
tok, url, rel, ns, sec = sys.argv[1:6]
print(json.dumps({
    "token": tok,
    "public_url": url or None,
    "in_cluster": {
        "simlab": f"http://{rel}-simlab-api.{ns}.svc:8081",
        "autoscaler": f"http://{rel}-autoscaler.{ns}.svc:8080",
    },
    "namespace": ns,
    "secret": sec,
}, indent=2))
PY
    exit 0
fi

echo "export SIMLAB_TOKEN='$token'"
[ -n "$PUBLIC_URL" ] && echo "export SIMLAB_URL='$PUBLIC_URL'"
echo "export SIMLAB_IN_CLUSTER_URL='http://${release}-simlab-api.${NAMESPACE}.svc:8081'"
echo "export AUTOSCALER_IN_CLUSTER_URL='http://${release}-autoscaler.${NAMESPACE}.svc:8080'"
echo "# secret: $secret in $NAMESPACE (context $(kubectl config current-context 2>/dev/null))"
