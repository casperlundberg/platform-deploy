#!/usr/bin/env python3
"""End-to-end check of the deployed platform, run as a Job inside the cluster.

This runs against the real deployment, beside real data. Two rules follow from
that, and everything else here is a consequence of them:

  1. It only ever creates its own rows, and only ever mutates rows it created.
     Nothing belonging to anyone else is written to, so there is nothing of
     theirs to restore.

  2. Every mutation pushes its inverse onto a stack, and the stack is unwound
     last-in-first-out however this process ends -- pass, fail, exception or
     SIGTERM. That is a saga, not a transaction: HTTP has no rollback, so the
     guarantee is "every compensation is attempted, and anything left behind is
     named", not "nothing can ever be left behind".

Concurrency. Every id this creates carries a per-execution nonce, so two copies
running at once cannot collide, and neither can collide with real data. The
final restoration check compares *sets of primary keys*, never counts: another
client legitimately creating or deleting its own rows while this runs must not
fail this test. What is asserted is exactly:

  - every primary key that existed before this started still exists, and
  - no primary key this created still exists.

Exit code is 0 only if every check passed and every compensation succeeded.
"""

import json
import os
import signal
import sys
import time
import urllib.error
import urllib.request

SIMLAB = os.environ.get("SIMLAB_URL", "http://platform-simlab-api:8081").rstrip("/")
AUTOSCALER = os.environ.get("AUTOSCALER_URL", "http://platform-autoscaler:8080").rstrip("/")
TOKEN = os.environ.get("AUTOSCALER_TOKEN", "")
OWNER = "e2e-"                      # marks a row as belonging to some run of this test
NONCE = f"{OWNER}{int(time.time())}-{os.urandom(3).hex()}"
RUN_TIMEOUT = float(os.environ.get("E2E_RUN_TIMEOUT_SECONDS", "120"))

checks, saga, leaked = [], [], []
created = {}


def http(method, url, body=None, token=None, timeout=30):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    if data:
        req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read().decode(errors="replace")
            try:
                return r.status, json.loads(raw) if raw.strip() else None
            except json.JSONDecodeError:
                return r.status, raw
    except urllib.error.HTTPError as e:
        raw = e.read().decode(errors="replace")
        try:
            return e.code, json.loads(raw) if raw.strip() else None
        except json.JSONDecodeError:
            return e.code, raw
    except Exception as e:                      # connection refused, DNS, timeout
        return 0, f"{type(e).__name__}: {e}"


def sse_probe(url, seconds=5):
    """Open an event stream, take the first bytes, hang up.

    The ordinary reader cannot be used here: an event stream stays open, so
    reading it to completion times out and is indistinguishable from the
    service being down. What is being checked is that the stream opens and
    produces something.
    """
    try:
        req = urllib.request.Request(url, headers={"Accept": "text/event-stream"})
        with urllib.request.urlopen(req, timeout=seconds) as r:
            if r.status != 200:
                return r.status, ""
            try:
                return 200, r.read(256).decode(errors="replace")
            except Exception:
                return 200, ""          # opened, produced nothing before the cut-off
    except urllib.error.HTTPError as e:
        return e.code, ""
    except Exception as e:
        return 0, f"{type(e).__name__}: {e}"


def check(name, ok, detail="", *, status=None):
    # 401/403/404/405 are called out separately: on an endpoint this is
    # supposed to be allowed to use, they mean the access is missing rather
    # than that the behaviour is wrong, and that is a different thing to fix.
    kind = "FAIL"
    if ok:
        kind = "PASS"
    elif status in (401, 403, 404, 405):
        kind = "NO-ACCESS"
    checks.append((kind, name, detail))
    print(f"  {kind:9} {name}" + (f"  -- {detail}" if detail else ""), flush=True)
    return ok


def compensate(label, fn):
    saga.append((label, fn))


def track(kind, ident, label, fn):
    """Register a compensation the moment an id exists.

    Deliberately not guarded by whether the create *passed*: an id that came
    back is a row that exists, whatever this test thinks of the status code.
    Registering inside `if check(...)` was a real bug here — a run created with
    202 failed an assertion expecting 201, so its compensation was never
    registered, the run was left behind, and the restoration check then passed
    because it was comparing against a set that never included it. A cleanup
    that only runs when you guessed the status code correctly is not cleanup.
    """
    if not ident:
        return
    created.setdefault(kind, set()).add(str(ident))
    compensate(label, fn)


def unwind():
    if not saga:
        return
    print("\n--- compensating (last first) ---", flush=True)
    while saga:
        label, fn = saga.pop()
        ok, detail = False, ""
        for attempt in range(3):
            try:
                ok, detail = fn()
            except Exception as e:
                ok, detail = False, f"{type(e).__name__}: {e}"
            if ok:
                break
            time.sleep(1 + attempt)
        print(f"  {'undone' if ok else 'LEAKED':9} {label}" + (f"  -- {detail}" if detail else ""), flush=True)
        if not ok:
            leaked.append(label)


def rows_of(payload):
    """The entities out of a list response, whatever envelope it uses."""
    if isinstance(payload, dict):
        for key in ("items", "mines", "scenarios", "runs", "targets", "data"):
            if isinstance(payload.get(key), list):
                payload = payload[key]
                break
    if not isinstance(payload, list):
        return []
    out = []
    for x in payload:
        if not isinstance(x, dict):
            continue
        # /api/runs wraps each row: {"active": bool, "run": {"id": ...}}. Looking
        # only at the top level finds no ids at all, which does not fail loudly —
        # it silently makes every assertion about this collection vacuous.
        if "id" not in x:
            for inner in ("run", "target", "mine", "scenario"):
                if isinstance(x.get(inner), dict) and "id" in x[inner]:
                    x = x[inner]
                    break
        if x.get("id") is not None:
            out.append(x)
    return out


def ids_of(payload):
    return {str(r["id"]) for r in rows_of(payload)}


def owned_by_a_test(row):
    """Does this row belong to some run of this test -- possibly another one?

    Concurrency makes this necessary. Two copies of this test overlap happily,
    but each snapshots the world at a different moment, so one will see the
    other's rows as pre-existing and then watch them vanish when their owner
    cleans up. A row disappearing because the thing that made it removed it is
    not data loss, and must not be reported as it.

    Run ids are server-generated, so ownership is carried in the name too.
    """
    return (str(row.get("id", "")).startswith(OWNER)
            or str(row.get("name", "")).startswith(OWNER))


def snapshot():
    """Primary keys that exist before this test touches anything."""
    snap, fetched = {}, {}
    for label, url, token in (
        ("mines", f"{SIMLAB}/api/mines", None),
        ("scenarios", f"{SIMLAB}/api/scenarios", None),
        ("runs", f"{SIMLAB}/api/runs", None),
        ("targets", f"{AUTOSCALER}/v1/targets", TOKEN),
    ):
        st, body = http("GET", url, token=token)
        fetched[label] = rows_of(body) if st == 200 else None
        if fetched[label] is None:
            print(f"  {label:10} unreadable (HTTP {st})", flush=True)

    # A simulation run registers a real target in the real autoscaler -- that
    # is the point of the simulation adapter, and it means the target's id is
    # the run's id. So a target can be owned by a test indirectly: delete the
    # run and its target goes with it. Without this link, one instance sees
    # another's run-target vanish and calls it data loss.
    test_runs = {str(r["id"]) for r in (fetched.get("runs") or []) if owned_by_a_test(r)}

    for label, rows in fetched.items():
        if rows is None:
            snap[label] = None
            continue
        ids = {str(r["id"]) for r in rows}
        theirs = {str(r["id"]) for r in rows
                  if owned_by_a_test(r) or str(r["id"]) in test_runs}
        snap[label] = {"ids": ids, "theirs": theirs}
        extra = f", {len(theirs)} owned by a concurrent run of this test" if theirs else ""
        print(f"  {label:10} {len(ids)} rows{extra}", flush=True)
    return snap


def main():
    print(f"e2e {NONCE}\n  simlab     {SIMLAB}\n  autoscaler {AUTOSCALER}\n", flush=True)

    print("--- probes ---", flush=True)
    for label, base in (("simlab-api", SIMLAB), ("autoscaler", AUTOSCALER)):
        for probe in ("healthz", "readyz"):
            st, _ = http("GET", f"{base}/{probe}")
            check(f"{label} /{probe}", st == 200, f"HTTP {st}", status=st)

    print("\n--- auth is actually enforced ---", flush=True)
    st, _ = http("GET", f"{AUTOSCALER}/v1/targets")          # deliberately no token
    check("autoscaler rejects an unauthenticated read", st in (401, 403),
          f"HTTP {st}" + (" -- the API is open" if st == 200 else ""))
    st, _ = http("GET", f"{AUTOSCALER}/v1/targets", token=TOKEN)
    check("autoscaler accepts the token", st == 200, f"HTTP {st}", status=st)

    print("\n--- platform schemas (Schema is API, not documentation) ---", flush=True)
    st, plats = http("GET", f"{AUTOSCALER}/v1/platforms", token=TOKEN)
    check("autoscaler lists platforms", st == 200, f"HTTP {st}", status=st)
    kinds = []
    if isinstance(plats, (list, dict)):
        items = plats if isinstance(plats, list) else plats.get("platforms", [])
        kinds = [p.get("kind") for p in items if isinstance(p, dict)]
        check("simulation is a first-class platform", "simulation" in kinds, f"kinds={kinds}")
        for p in items if isinstance(items, list) else []:
            fields = p.get("schema") or p.get("fields") or []
            unlabelled = [f.get("key") for f in fields if isinstance(f, dict) and not f.get("label")]
            check(f"every {p.get('kind')} field has a Label", not unlabelled, f"missing={unlabelled}")
    st, _ = http("GET", f"{SIMLAB}/api/platforms")
    check("simlab proxies the platform list", st == 200, f"HTTP {st}", status=st)

    print("\n--- snapshot of primary keys before the test ---", flush=True)
    before = snapshot()

    mine_id = f"{NONCE}-mine"
    scenario_id = f"{NONCE}-scn"
    target_id = f"{NONCE}-tgt"

    print("\n--- simlab CRUD: mine ---", flush=True)
    st, body = http("POST", f"{SIMLAB}/api/mines", {
        "id": mine_id, "name": "e2e probe mine",
        "sensors": 8, "background_rate_per_hour": 30})
    got = body.get("id") if isinstance(body, dict) else None
    track("mines", got, f"delete mine {mine_id}", lambda: (
        lambda s: (s in (200, 204, 404), f"HTTP {s}"))(
            http("DELETE", f"{SIMLAB}/api/mines/{mine_id}")[0]))
    check("create mine", st in (200, 201), f"HTTP {st} {str(body)[:120]}", status=st)
    st, body = http("GET", f"{SIMLAB}/api/mines/{mine_id}")
    check("read it back", st == 200 and isinstance(body, dict) and body.get("id") == mine_id,
          f"HTTP {st}", status=st)
    st, _ = http("PUT", f"{SIMLAB}/api/mines/{mine_id}", {
        "id": mine_id, "name": "e2e probe mine (updated)",
        "sensors": 9, "background_rate_per_hour": 31})
    check("update it", st in (200, 204), f"HTTP {st}", status=st)
    st, body = http("GET", f"{SIMLAB}/api/mines/{mine_id}")
    check("the update stuck", isinstance(body, dict) and body.get("sensors") == 9,
          f"sensors={body.get('sensors') if isinstance(body, dict) else body}")
    st, body = http("GET", f"{SIMLAB}/api/mines")
    check("it appears in the list", mine_id in ids_of(body), f"HTTP {st}", status=st)

    print("\n--- simlab CRUD: scenario ---", flush=True)
    st, body = http("POST", f"{SIMLAB}/api/scenarios", {
        "id": scenario_id, "mine_id": mine_id, "name": "e2e burst",
        "duration_seconds": 600, "job_seconds": 20, "seed": 42,
        "priority_mix": {"100": 1, "25": 3},
        "bursts": [{"at_seconds": 120, "magnitude": 10, "aftershock_decay_seconds": 180}]})
    got = body.get("id") if isinstance(body, dict) else None
    track("scenarios", got, f"delete scenario {scenario_id}", lambda: (
        lambda s: (s in (200, 204, 404), f"HTTP {s}"))(
            http("DELETE", f"{SIMLAB}/api/scenarios/{scenario_id}")[0]))
    check("create scenario", st in (200, 201), f"HTTP {st} {str(body)[:120]}", status=st)
    st, body = http("GET", f"{SIMLAB}/api/scenarios/{scenario_id}")
    check("read it back", st == 200, f"HTTP {st}", status=st)

    print("\n--- the real end-to-end path: a run drives the autoscaler ---", flush=True)
    st, body = http("POST", f"{SIMLAB}/api/runs", {
        "name": f"{NONCE} baseline", "mode": "simulation", "scenario_id": scenario_id,
        "decision_interval_seconds": 15, "time_compression": 100000,
        "settings": {"local_executor_cap": 20, "cloud_executor_cap": 40}})
    run_id = body.get("id") if isinstance(body, dict) else None
    if run_id:
        def drop_run():
            s, b = http("GET", f"{SIMLAB}/api/runs/{run_id}")
            inner = b.get("run", b) if isinstance(b, dict) else {}
            if s == 200 and isinstance(inner, dict) and inner.get("status") in ("pending", "running"):
                http("POST", f"{SIMLAB}/api/runs/{run_id}/cancel")   # cancel before delete
                time.sleep(2)
            s = http("DELETE", f"{SIMLAB}/api/runs/{run_id}")[0]
            return s in (200, 204, 404), f"HTTP {s}"

        track("runs", run_id, f"cancel+delete run {run_id}", drop_run)
    # 202: starting a run is asynchronous, and saying so is correct.
    check("create run", st in (200, 201, 202) and run_id,
          f"HTTP {st} {str(body)[:100]}", status=st)

    if run_id:
        deadline, status = time.time() + RUN_TIMEOUT, None
        while time.time() < deadline:
            st, body = http("GET", f"{SIMLAB}/api/runs/{run_id}")
            inner = body.get("run", body) if isinstance(body, dict) else {}
            status = inner.get("status") if isinstance(inner, dict) else None
            if status in ("completed", "failed", "cancelled"):
                break
            time.sleep(2)
        check("run reaches a terminal state", status == "completed",
              f"status={status} after {RUN_TIMEOUT:.0f}s budget")

        st, cyc = http("GET", f"{SIMLAB}/api/runs/{run_id}/cycles", timeout=15)
        rows = cyc.get("cycles", []) if isinstance(cyc, dict) else (cyc if isinstance(cyc, list) else [])
        check("run cycles readable", st == 200 and len(rows) > 0,
              f"HTTP {st}, {len(rows)} cycles -- the autoscaler decided this many times", status=st)
        # The whole argument of this system is that a decision is a simulation
        # of the queue rather than a threshold, and that it can say why. An
        # empty reason would mean the claim is not actually being met.
        reasons = [r.get("reason") for r in rows if isinstance(r, dict)]
        check("every decision carries its reasoning",
              bool(reasons) and all(r for r in reasons),
              f"{sum(1 for r in reasons if r)}/{len(reasons)} with a reason"
              + (f'  e.g. "{reasons[0][:70]}"' if reasons and reasons[0] else ""))

        st, _ = http("GET", f"{SIMLAB}/api/runs/{run_id}/metrics", timeout=15)
        check("run metrics readable", st == 200, f"HTTP {st}", status=st)

        st, first = sse_probe(f"{SIMLAB}/api/runs/{run_id}/events")
        check("run event stream opens", st == 200,
              f"HTTP {st}" + (f", first bytes: {first[:40]!r}" if first else ", opened, no bytes before cut-off"),
              status=st)

    print("\n--- autoscaler CRUD: target ---", flush=True)
    st, body = http("POST", f"{AUTOSCALER}/v1/targets", {
        "target": {"id": target_id, "name": "e2e probe target",
                   "kind": "simulation", "mode": "manual", "config": {}},
        "settings": {"local_executor_cap": 5, "cloud_executor_cap": 5},
    }, token=TOKEN)
    got = (body.get("target", {}).get("id") if isinstance(body, dict) else None) or (
        body.get("id") if isinstance(body, dict) else None)
    track("targets", got, f"delete target {target_id}", lambda: (
        lambda s: (s in (200, 204, 404), f"HTTP {s}"))(
            http("DELETE", f"{AUTOSCALER}/v1/targets/{target_id}", token=TOKEN)[0]))
    if check("create simulation target", st in (200, 201), f"HTTP {st} {str(body)[:160]}", status=st):
        st, _ = http("GET", f"{AUTOSCALER}/v1/targets/{target_id}", token=TOKEN)
        check("read it back", st == 200, f"HTTP {st}", status=st)
        # Settings come back as a SettingsSnapshot -- {version, updated_at,
        # settings{...}, warnings} -- not as bare settings. Reading the cap off
        # the top level finds None and looks like a broken write.
        st, snap0 = http("GET", f"{AUTOSCALER}/v1/targets/{target_id}/settings", token=TOKEN)
        v0 = snap0.get("version") if isinstance(snap0, dict) else None
        st, _ = http("PATCH", f"{AUTOSCALER}/v1/targets/{target_id}/settings",
                     {"local_executor_cap": 7}, token=TOKEN)
        check("patch its settings", st in (200, 204), f"HTTP {st}", status=st)
        st, snap1 = http("GET", f"{AUTOSCALER}/v1/targets/{target_id}/settings", token=TOKEN)
        eff = snap1.get("settings", {}) if isinstance(snap1, dict) else {}
        check("the patch stuck", eff.get("local_executor_cap") == 7,
              f"local_executor_cap={eff.get('local_executor_cap')}")
        # The store is versioned so that writes can be conditional. A write that
        # did not move the version would make expected-version writes useless.
        v1 = snap1.get("version") if isinstance(snap1, dict) else None
        check("the settings version advanced", isinstance(v0, int) and isinstance(v1, int) and v1 > v0,
              f"{v0} -> {v1}")
        st, _ = http("GET", f"{AUTOSCALER}/v1/targets/{target_id}/settings/history", token=TOKEN)
        check("settings history readable", st == 200, f"HTTP {st}", status=st)
        # A simulation target cannot see its own queue, so cycling it without a
        # workload has nothing to decide from. Being refused is the correct
        # answer; what is worth asserting is that the refusal says why, which is
        # this project's standing rule that an error names the thing.
        st, b = http("POST", f"{AUTOSCALER}/v1/targets/{target_id}/cycle", {}, token=TOKEN)
        msg = (b.get("error") if isinstance(b, dict) else str(b)) or ""
        check("cycling a blind target with no workload is refused, and the error says why",
              st == 400 and "workload" in msg.lower(), f"HTTP {st} {msg[:130]}")
        st, _ = http("GET", f"{AUTOSCALER}/v1/targets/{target_id}/status", token=TOKEN)
        check("status readable", st == 200, f"HTTP {st}", status=st)

    print("\n--- credentials are never returned ---", flush=True)
    st, b = http("GET", f"{AUTOSCALER}/v1/targets/{target_id}", token=TOKEN)
    blob = json.dumps(b) if b is not None else ""
    check("no secret material in a target read",
          TOKEN == "" or TOKEN not in blob, "the API token appeared in a response body")

    return before


def verify_restoration(before):
    print("\n--- restoration ---", flush=True)
    after = {}
    for label, url, token in (
        ("mines", f"{SIMLAB}/api/mines", None),
        ("scenarios", f"{SIMLAB}/api/scenarios", None),
        ("runs", f"{SIMLAB}/api/runs", None),
        ("targets", f"{AUTOSCALER}/v1/targets", TOKEN),
    ):
        st, body = http("GET", url, token=token)
        after[label] = ids_of(body) if st == 200 else None

    for label in before:
        snap, post = before.get(label), after.get(label)
        if snap is None or post is None:
            check(f"{label}: restoration verifiable", False, "could not list before or after")
            continue
        # Set comparison, never counts: somebody else adding or removing their
        # own rows while this ran is legitimate and must not fail the test.
        # Rows belonging to a concurrent run of this test are excluded for the
        # same reason -- their owner is entitled to delete them.
        destroyed = (snap["ids"] - post) - snap["theirs"]
        check(f"{label}: nothing pre-existing was destroyed", not destroyed,
              f"missing now: {sorted(destroyed)[:5]}")
        left = created.get(label, set()) & post
        check(f"{label}: nothing of ours was left behind", not left,
              f"still present: {sorted(left)[:5]}")


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: (unwind(), sys.exit(143)))
    before = {}
    try:
        before = main()
    except Exception as e:
        check("test body completed", False, f"{type(e).__name__}: {e}")
    finally:
        unwind()
        if before:
            try:
                verify_restoration(before)
            except Exception as e:
                check("restoration verified", False, f"{type(e).__name__}: {e}")

    failed = [c for c in checks if c[0] == "FAIL"]
    noaccess = [c for c in checks if c[0] == "NO-ACCESS"]
    print(f"\n{'='*64}")
    print(f"  {len(checks)} checks   {len(failed)} failed   {len(noaccess)} missing-access"
          f"   {len(leaked)} leaked")
    for kind, name, detail in failed + noaccess:
        print(f"  {kind:9} {name}  -- {detail}")
    for label in leaked:
        print(f"  LEAKED    {label}  -- delete this by hand")
    print("=" * 64)
    sys.exit(1 if (failed or noaccess or leaked) else 0)
