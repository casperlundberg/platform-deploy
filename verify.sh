#!/usr/bin/env bash
#
# Runs the whole platform for real and checks it does what it claims.
#
# Not a unit test and not a substitute for one. Every service has its own suite
# against fakes that behave like the real thing; this is the one check that
# nothing between them has been assumed. It builds both binaries, starts them
# against a real Postgres, and replays one scenario under two policies — and
# it was worth writing: the first time it ran it found a response rendering
# nanoseconds for a field the request took in seconds.
#
# Usage:
#   ./verify.sh                    # brings up its own Postgres
#   POSTGRES_URL=... ./verify.sh   # uses one you already have
#
# Expects the service repositories checked out beside this one.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "$HERE/.." && pwd)"
AUTOSCALER_DIR="${AUTOSCALER_DIR:-$PLATFORM_DIR/autoscaler}"
SIMLAB_DIR="${SIMLAB_DIR:-$PLATFORM_DIR/simlab-api}"

for dir in "$AUTOSCALER_DIR" "$SIMLAB_DIR"; do
  [[ -d "$dir" ]] || {
    echo "$dir is not there. This script expects the service repositories"
    echo "checked out beside this one; set AUTOSCALER_DIR and SIMLAB_DIR if"
    echo "they live somewhere else."
    exit 1
  }
done

WORK="$(mktemp -d)"
AUTOSCALER_PORT="${AUTOSCALER_PORT:-18190}"
SIMLAB_PORT="${SIMLAB_PORT:-18191}"
TOKEN="verify-$RANDOM"
PG_CONTAINER="simlab-verify-pg"
OWN_POSTGRES=0

API="http://127.0.0.1:$SIMLAB_PORT"

log()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$*"; exit 1; }

cleanup() {
  [[ -n "${SIMLAB_PID:-}" ]] && kill "$SIMLAB_PID" 2>/dev/null || true
  [[ -n "${AUTOSCALER_PID:-}" ]] && kill "$AUTOSCALER_PID" 2>/dev/null || true
  [[ "$OWN_POSTGRES" == "1" ]] && docker rm -f "$PG_CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

wait_for() {
  local url=$1 name=$2
  for _ in $(seq 1 120); do
    curl -sf "$url" >/dev/null 2>&1 && return 0
    sleep 0.25
  done
  echo "--- $name log ---"; cat "$WORK/$name.log" 2>/dev/null || true
  fail "$name never became healthy at $url"
}

# ---------------------------------------------------------------- postgres

if [[ -z "${POSTGRES_URL:-}" ]]; then
  log "Starting Postgres"
  docker rm -f "$PG_CONTAINER" >/dev/null 2>&1 || true
  docker run -d --name "$PG_CONTAINER" \
    -e POSTGRES_PASSWORD=simlab -e POSTGRES_USER=simlab -e POSTGRES_DB=simlab_verify \
    -p 15433:5432 postgres:16-alpine >/dev/null
  OWN_POSTGRES=1
  POSTGRES_URL="postgres://simlab:simlab@127.0.0.1:15433/simlab_verify?sslmode=disable"
  for _ in $(seq 1 120); do
    docker exec "$PG_CONTAINER" pg_isready -U simlab >/dev/null 2>&1 && break
    sleep 0.5
  done
  ok "Postgres is up"
fi

# ------------------------------------------------------------------ build

log "Building both services"
(cd "$AUTOSCALER_DIR" && go build -o "$WORK/autoscaler" ./cmd/autoscaler)
ok "autoscaler"
(cd "$SIMLAB_DIR" && go build -o "$WORK/simlab-api" ./cmd/simlab-api)
ok "simlab-api"

# ------------------------------------------------------------------ start

log "Starting the platform"
AUTOSCALER_ADDRESS=":$AUTOSCALER_PORT" \
AUTOSCALER_API_TOKEN="$TOKEN" \
AUTOSCALER_STATE_FILE="$WORK/targets.json" \
  "$WORK/autoscaler" > "$WORK/autoscaler.log" 2>&1 &
AUTOSCALER_PID=$!
wait_for "http://127.0.0.1:$AUTOSCALER_PORT/healthz" autoscaler
ok "autoscaler on :$AUTOSCALER_PORT"

SIMLAB_ADDRESS=":$SIMLAB_PORT" \
SIMLAB_DATABASE_URL="$POSTGRES_URL" \
SIMLAB_AUTOSCALER_URL="http://127.0.0.1:$AUTOSCALER_PORT" \
SIMLAB_AUTOSCALER_TOKEN="$TOKEN" \
  "$WORK/simlab-api" > "$WORK/simlab-api.log" 2>&1 &
SIMLAB_PID=$!
wait_for "$API/healthz" simlab-api
ok "simlab-api on :$SIMLAB_PORT"

# ------------------------------------------------------- they see each other

log "Checking the services can reach each other"
PLATFORMS=$(curl -sf "$API/api/platforms" | python3 -c 'import sys,json; print(",".join(sorted(p["kind"] for p in json.load(sys.stdin)["platforms"])))')
[[ "$PLATFORMS" == "colonyos-container,colonyos-k8s,kubernetes,simulation" ]] \
  || fail "simlab-api sees platforms [$PLATFORMS]; the autoscaler is not answering properly"
ok "every platform is reachable through simlab-api: $PLATFORMS"

# -------------------------------------------------------------- the workload

log "Defining a mine and a rock burst"
curl -sf "$API/api/mines" -H 'Content-Type: application/json' -d '{
  "id":"storhall","name":"Storhall","sensors":30,"background_rate_per_hour":90}' >/dev/null
ok "mine registered"

curl -sf "$API/api/scenarios" -H 'Content-Type: application/json' -d '{
  "id":"rock-burst","mine_id":"storhall","name":"Large rock burst",
  "duration_seconds":7200,"job_seconds":20,"seed":20260910,
  "priority_mix":{"100":1,"50":1,"25":2},
  "bursts":[{"at_seconds":1800,"magnitude":45,"aftershock_decay_seconds":1800}]}' > "$WORK/scenario.json"
ok "scenario registered"

# A response that cannot be sent back is a broken contract. This is the check
# that first failed, so it stays.
curl -sf -o /dev/null -X PUT -H 'Content-Type: application/json' \
  --data-binary @"$WORK/scenario.json" "$API/api/scenarios/rock-burst" \
  || fail "a scenario response cannot be sent back as a request"
ok "the scenario round-trips: what comes out can be sent back in"

# -------------------------------------------------------------------- runs

start_run() {
  curl -sf "$API/api/runs" -H 'Content-Type: application/json' -d "$1" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])'
}

await_run() {
  local id=$1
  for _ in $(seq 1 600); do
    local status
    status=$(curl -sf "$API/api/runs/$id" | python3 -c 'import sys,json; print(json.load(sys.stdin)["run"]["status"])')
    case "$status" in
      completed) return 0 ;;
      failed|cancelled)
        curl -sf "$API/api/runs/$id" | python3 -c 'import sys,json; print(json.load(sys.stdin)["run"].get("error",""))'
        fail "run $id ended as $status" ;;
    esac
    sleep 0.5
  done
  fail "run $id never finished"
}

metric() {
  curl -sf "$API/api/runs/$1/metrics" | python3 -c "import sys,json; print(json.load(sys.stdin)['$2'])"
}

log "Replaying the same workload under two policies"

CAPPED=$(start_run '{"name":"On-premise only","mode":"simulation","scenario_id":"rock-burst",
  "decision_interval_seconds":15,"time_compression":500000,
  "settings":{"local_executor_cap":12,"cloud_executor_cap":0,"local_coldstart_seconds":60}}')
await_run "$CAPPED"
ok "on-premise-only run finished"

ELASTIC=$(start_run '{"name":"With cloud burst","mode":"simulation","scenario_id":"rock-burst",
  "decision_interval_seconds":15,"time_compression":500000,
  "settings":{"local_executor_cap":12,"cloud_executor_cap":60,"local_coldstart_seconds":60,"cloud_coldstart_seconds":180}}')
await_run "$ELASTIC"
ok "cloud-burst run finished"

# ------------------------------------------------------------------ assert

log "Checking the results mean something"

CAPPED_JOBS=$(metric "$CAPPED" jobs_submitted)
ELASTIC_JOBS=$(metric "$ELASTIC" jobs_submitted)
[[ "$CAPPED_JOBS" == "$ELASTIC_JOBS" && "$CAPPED_JOBS" -gt 0 ]] \
  || fail "the two runs replayed different workloads ($CAPPED_JOBS and $ELASTIC_JOBS jobs); the comparison would be meaningless"
ok "both runs replayed the identical $CAPPED_JOBS jobs — the seed held"

CAPPED_BREACHES=$(metric "$CAPPED" sla_breaches)
ELASTIC_BREACHES=$(metric "$ELASTIC" sla_breaches)
[[ "$ELASTIC_BREACHES" -lt "$CAPPED_BREACHES" ]] \
  || fail "cloud burst did not reduce breaches ($ELASTIC_BREACHES against $CAPPED_BREACHES)"
ok "cloud burst cut SLA breaches from $CAPPED_BREACHES to $ELASTIC_BREACHES"

CAPPED_CLOUD=$(metric "$CAPPED" cloud_executor_seconds)
ELASTIC_CLOUD=$(metric "$ELASTIC" cloud_executor_seconds)
python3 -c "import sys; sys.exit(0 if float('$CAPPED_CLOUD') == 0 else 1)" \
  || fail "the on-premise-only run used $CAPPED_CLOUD cloud executor-seconds; its cloud cap was zero"
python3 -c "import sys; sys.exit(0 if float('$ELASTIC_CLOUD') > 0 else 1)" \
  || fail "the cloud-burst run never used the cloud tier"
ok "and it cost $(python3 -c "print(round(float('$ELASTIC_CLOUD')/3600,1))") cloud executor-hours to do it"

# The decisions have to come from the real engine, with its reasoning, not
# from anything Simlab invented.
REASONED=$(curl -sf "$API/api/runs/$ELASTIC/cycles?limit=20000" | python3 -c '
import sys, json
cycles = json.load(sys.stdin)["cycles"]
changed = [c for c in cycles if c["action"] not in ("", "maintain")]
reasoned = [c for c in changed if c["reason"] and c["settings_version"] > 0]
print(f"{len(reasoned)}/{len(changed)}")
if reasoned:
    print(reasoned[0]["reason"])
')
COUNTS=$(echo "$REASONED" | head -1)
[[ "${COUNTS%%/*}" -gt 0 && "${COUNTS%%/*}" == "${COUNTS##*/}" ]] \
  || fail "only $COUNTS scaling decisions carried the engine's reasoning"
ok "every one of ${COUNTS##*/} scaling decisions carries the engine's own reasoning"
printf '      %s\n' "$(echo "$REASONED" | tail -1)"

# A run that left its ephemeral target behind would accumulate silently.
REMAINING=$(curl -sf -H "Authorization: Bearer $TOKEN" \
  "http://127.0.0.1:$AUTOSCALER_PORT/v1/targets" \
  | python3 -c 'import sys,json; print(len(json.load(sys.stdin)["targets"]))')
[[ "$REMAINING" == "0" ]] || fail "$REMAINING autoscaler targets outlived their runs"
ok "both runs cleaned up their autoscaler targets"

# ------------------------------------------------- settings, live, no restart

log "Changing a live autoscaler's settings through Simlab"

curl -sf "$API/api/targets" -H 'Content-Type: application/json' -d '{
  "target":{"id":"live-demo","name":"Live demo","kind":"simulation","mode":"driven",
            "config":{"local_coldstart_seconds":"0"}}}' >/dev/null
BEFORE=$(curl -sf "$API/api/targets/live-demo/settings" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["version"], int(d["settings"]["local_executor_cap"]))')
curl -sf -X PATCH "$API/api/targets/live-demo/settings?expected_version=${BEFORE%% *}" \
  -H 'Content-Type: application/json' -d '{"local_executor_cap": 77}' >/dev/null
AFTER=$(curl -sf "$API/api/targets/live-demo/settings" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["version"], int(d["settings"]["local_executor_cap"]))')
[[ "$AFTER" == "$(( ${BEFORE%% *} + 1 )) 77" ]] \
  || fail "the settings change did not reach the autoscaler (before: $BEFORE, after: $AFTER)"
ok "settings went from [$BEFORE] to [$AFTER] on a running service, with nothing restarted"

# A stale write must be refused, or two editors silently overwrite each other.
STALE=$(curl -s -o /dev/null -w '%{http_code}' -X PATCH \
  "$API/api/targets/live-demo/settings?expected_version=${BEFORE%% *}" \
  -H 'Content-Type: application/json' -d '{"local_executor_cap": 5}')
[[ "$STALE" == "409" ]] || fail "a stale settings write returned $STALE, want 409"
ok "a stale write is refused, so two editors cannot clobber each other"

curl -sf -o /dev/null -X DELETE "$API/api/targets/live-demo"

log "The platform works."
