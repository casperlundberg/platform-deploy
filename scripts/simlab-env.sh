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

names=$(kubectl get secret --namespace "$NAMESPACE" --no-headers \
    -o custom-columns=NAME:.metadata.name 2>/dev/null || true)

# Two different credentials, in opposite directions, and sending one where the
# other belongs fails as a flat 401 with nothing to say which.
#
#   simlab-api-token : what a caller presents to Simlab's API. This is the one
#                      scripts and the browser need.
#   api-token        : what simlab-api presents to the autoscaler. Only needed
#                      to call the autoscaler directly.
#
# A self-contained install has the chart generate <release>-prefixed names; a
# cluster using existingSecret has whatever it chose. Both are found.
api_secret=$(echo "$names" | grep -E '(^|-)simlab-api-token$' | head -1 || true)
auto_secret=$(echo "$names" | grep -E '(^|-)autoscaler-api-token$' | head -1 || true)

read_key() {  # $1 = secret, $2 = key
    [ -n "$1" ] || return 0
    kubectl get secret "$1" --namespace "$NAMESPACE" -o jsonpath="{.data.$2}" 2>/dev/null | base64 -d
}

# simlab-api's own token lives under its own key wherever it is kept.
token=$(read_key "$api_secret" simlab-api-token)
[ -n "$token" ] || token=$(read_key "$auto_secret" simlab-api-token)
autoscaler_token=$(read_key "$auto_secret" api-token)

if [ -z "$token" ] && [ -z "$autoscaler_token" ]; then
    echo "no Simlab or autoscaler token Secret in $NAMESPACE -- is the platform installed?" >&2
    exit 1
fi
if [ -z "$token" ]; then
    echo "note: Simlab's API has no token configured, so it is unauthenticated" >&2
fi
secret="${api_secret:-$auto_secret}"

# The public URL, if an Ingress exposes the SPA. Its nginx proxies /api, so one
# host serves the whole application -- which is why there is no separate API
# hostname to look up.
if [ -z "$PUBLIC_URL" ]; then
    host=$(kubectl get ingress --namespace "$NAMESPACE" \
        -o jsonpath='{.items[0].spec.rules[0].host}' 2>/dev/null || true)
    [ -n "$host" ] && PUBLIC_URL="https://$host"
fi

# In-cluster addresses, for anything running as a pod in this namespace.
release=${secret%-simlab-api-token}
release=${release%-autoscaler-api-token}
[ "$release" = "$secret" ] && release=platform      # existingSecret, name says nothing

if [ "$FORMAT" = json ]; then
    python3 - "$token" "$PUBLIC_URL" "$release" "$NAMESPACE" "$secret" "$autoscaler_token" <<'PY'
import json, sys
tok, url, rel, ns, sec, autotok = sys.argv[1:7]
print(json.dumps({
    "token": tok,
    "autoscaler_token": autotok or None,
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
[ -n "$autoscaler_token" ] && echo "export AUTOSCALER_TOKEN='$autoscaler_token'"
[ -n "$PUBLIC_URL" ] && echo "export SIMLAB_URL='$PUBLIC_URL'"
echo "export SIMLAB_IN_CLUSTER_URL='http://${release}-simlab-api.${NAMESPACE}.svc:8081'"
echo "export AUTOSCALER_IN_CLUSTER_URL='http://${release}-autoscaler.${NAMESPACE}.svc:8080'"
echo "# secret: $secret in $NAMESPACE (context $(kubectl config current-context 2>/dev/null))"
