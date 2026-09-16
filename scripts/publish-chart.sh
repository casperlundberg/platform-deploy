#!/usr/bin/env bash
#
# Package the platform as one self-contained chart and push it to an OCI
# registry, so it can be installed by someone who has the registry and nothing
# else -- no repositories, no checkout, no sibling directories.
#
# Two things have to be true of the published artifact that are not true of the
# chart in this repository:
#
#   1. It must carry the service charts inside it. Here they are file://
#      dependencies on the sibling repos, which is right for developing them
#      together and useless to anyone who does not have those repos.
#
#   2. Its images must resolve to tags that exist. A service chart with
#      image.tag unset falls back to its own appVersion, and appVersion is
#      0.1.0, which nothing has ever published -- install it and every pod sits
#      in ImagePullBackOff. Each embedded subchart therefore gets its appVersion
#      stamped with the sha- tag actually built from that commit, which is what
#      appVersion is supposed to mean.
#
# Usage:
#   scripts/publish-chart.sh [--dry-run] [--registry oci://...] [--version X.Y.Z]
#
# Credentials come from `helm registry login`, or from HELM_REGISTRY_USER and
# HELM_REGISTRY_PASSWORD if set.
set -euo pipefail

REGISTRY="oci://registry-1.docker.io/cappelumpa"
VERSION=""
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --registry) REGISTRY="$2"; shift 2 ;;
        --version)  VERSION="$2";  shift 2 ;;
        --dry-run)  DRY_RUN=1;     shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

cd "$(dirname "$0")/.."
CHART_DIR="charts/autoscale-platform"
SERVICES="autoscaler simlab-api simlab-web"

[ -n "$VERSION" ] || VERSION=$(awk '/^version:/ {print $2; exit}' "$CHART_DIR/Chart.yaml")

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
staged="$work/autoscale-platform"
mkdir -p "$staged/charts"

# The umbrella itself, with its dependencies rewritten. The file:// paths have
# to go -- they point at sibling repos the installer will not have -- but the
# dependencies cannot simply be deleted either: a v2 chart must declare
# whatever sits in charts/, and helm lint fails with "chart metadata is missing
# these dependencies" if it does not. Declared with no repository means
# "already vendored here", which is exactly the case.
awk '/^dependencies:/ {exit} {print}' "$CHART_DIR/Chart.yaml" > "$staged/Chart.yaml"
{
    echo ""
    echo "# Vendored into charts/ by scripts/publish-chart.sh. No repository:"
    echo "# they are present, not fetched."
    echo "dependencies:"
    for svc in $SERVICES; do
        ver=$(awk '/^version:/ {print $2; exit}' "../$svc/deploy/chart/Chart.yaml")
        echo "  - name: $svc"
        echo "    version: \"$ver\""
    done
} >> "$staged/Chart.yaml"
cp "$CHART_DIR/values.yaml" "$staged/values.yaml"
[ -d "$CHART_DIR/templates" ] && cp -r "$CHART_DIR/templates" "$staged/templates"
[ -f "$CHART_DIR/README.md" ] && cp "$CHART_DIR/README.md" "$staged/README.md"

echo "staging the service charts"
for svc in $SERVICES; do
    src="../$svc/deploy/chart"
    if [ ! -d "$src" ]; then
        echo "  $svc: $src is missing -- publishing needs the sibling repos checked out" >&2
        exit 1
    fi
    sha=$(git -C "../$svc" rev-parse HEAD)
    # Only the chart is published, so only the chart has to be clean. An
    # unrelated scratch file at the repo root says nothing about what goes into
    # the artifact.
    if [ -n "$(git -C "../$svc" status --porcelain -- deploy/chart)" ]; then
        echo "  $svc: deploy/chart has uncommitted changes; the published chart" >&2
        echo "         would claim a commit whose contents it does not have" >&2
        exit 1
    fi
    if ! git -C "../$svc" merge-base --is-ancestor HEAD "@{upstream}" 2>/dev/null; then
        echo "  $svc: HEAD is not pushed, so no image was ever built from it" >&2
        exit 1
    fi

    cp -r "$src" "$staged/charts/$svc"
    # appVersion is what an unset image.tag falls back to. Stamping it here is
    # what makes the published chart install into a working system with no
    # values at all.
    sed -i "s|^appVersion:.*|appVersion: \"sha-$sha\"|" "$staged/charts/$svc/Chart.yaml"
    echo "  $svc -> sha-${sha:0:12}"
done

echo "verifying every image tag exists before publishing a chart that names it"
for svc in $SERVICES; do
    tag=$(awk -F'"' '/^appVersion:/ {print $2}' "$staged/charts/$svc/Chart.yaml")
    code=$(curl -sS -o /dev/null -w '%{http_code}' \
        "https://hub.docker.com/v2/repositories/cappelumpa/$svc/tags/$tag")
    if [ "$code" != "200" ]; then
        echo "  $svc:$tag is not on Docker Hub (HTTP $code) -- has its CI finished?" >&2
        exit 1
    fi
    echo "  $svc:${tag:0:16}... present"
done

# Lint under the flags the install instructions actually use. Linting bare
# defaults would fail on purpose -- the storage guard rejects an unset class,
# which is the whole point of it -- and `cmd && echo` would swallow that
# failure rather than stop, because a failing left-hand side of && does not
# trip `set -e`. Both mistakes were here.
LINT_FLAGS=(--set storage.requireLonghorn=false
            --set autoscaler.auth.token=lint-only
            --set simlab-api.autoscaler.token=lint-only)
if ! helm lint "$staged" "${LINT_FLAGS[@]}" >/dev/null; then
    echo "chart does not lint under the documented install flags" >&2
    helm lint "$staged" "${LINT_FLAGS[@]}" >&2
    exit 1
fi
echo "chart lints under the documented install flags"

# And it must render into valid Kubernetes, which lint does not check.
helm template lint-only "$staged" "${LINT_FLAGS[@]}" >/dev/null
helm package "$staged" --version "$VERSION" --destination "$work" >/dev/null
pkg="$work/autoscale-platform-$VERSION.tgz"
echo "packaged $(basename "$pkg") ($(du -h "$pkg" | cut -f1))"

if [ -n "${HELM_REGISTRY_USER:-}" ]; then
    host=${REGISTRY#oci://}; host=${host%%/*}
    echo "$HELM_REGISTRY_PASSWORD" | helm registry login "$host" \
        --username "$HELM_REGISTRY_USER" --password-stdin
fi

if [ "$DRY_RUN" = "1" ]; then
    echo "dry run: not pushing. would push to $REGISTRY"
    cp "$pkg" "./$(basename "$pkg")"
    echo "left $(basename "$pkg") here for inspection"
    exit 0
fi

helm push "$pkg" "$REGISTRY"
echo
echo "installable with nothing but the registry:"
echo "  helm install platform ${REGISTRY}/autoscale-platform --version $VERSION \\"
echo "    --namespace autoscale-platform --create-namespace \\"
echo "    --set storage.requireLonghorn=false \\"
echo "    --set autoscaler.auth.token=CHOOSE-ONE \\"
echo "    --set simlab-api.autoscaler.token=CHOOSE-ONE   # the same value: two ends of one credential"
