#!/usr/bin/env python3
"""Drive a deployed Simlab from the command line, for experiments.

Credentials and addresses come from the cluster, via simlab-env.sh, so there is
nothing to copy around and nothing to go stale:

    eval "$(scripts/simlab-env.sh)"
    scripts/simlab.py mines
    scripts/simlab.py compare --cloud-caps 0,20,40

Or let it discover them itself -- with no SIMLAB_URL set it runs simlab-env.sh
for you.

Everything it creates is named with a per-invocation prefix and removed again
when the command finishes, including on failure. `compare` and `run` take
--keep if you want the runs left behind to look at in the browser.

This talks to Simlab, which owns mines, scenarios and runs. It does not create
autoscaler targets against real infrastructure: a simulation run exercises the
real decision engine without anything being provisioned, which is what makes it
safe to point at a live deployment.
"""

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

TIMEOUT = 30


def discover():
    """Ask simlab-env.sh, so the token is always the one the cluster holds."""
    url, token = os.environ.get("SIMLAB_URL"), os.environ.get("SIMLAB_TOKEN")
    if url:
        return url.rstrip("/"), token
    script = Path(__file__).with_name("simlab-env.sh")
    if not script.exists():
        sys.exit("set SIMLAB_URL, or keep simlab-env.sh beside this script")
    try:
        out = subprocess.run([str(script), "--json"], capture_output=True,
                             text=True, check=True, timeout=60).stdout
    except subprocess.CalledProcessError as e:
        sys.exit(e.stderr.strip() or "simlab-env.sh failed")
    d = json.loads(out)
    if not d.get("public_url"):
        sys.exit("the deployment has no Ingress; port-forward and set SIMLAB_URL")
    return d["public_url"].rstrip("/"), d.get("token")


class Simlab:
    def __init__(self, base, token=None):
        self.base, self.token = base.rstrip("/"), token

    def _call(self, method, path, body=None):
        req = urllib.request.Request(
            f"{self.base}{path}",
            data=json.dumps(body).encode() if body is not None else None,
            method=method)
        if body is not None:
            req.add_header("Content-Type", "application/json")
        if self.token:
            req.add_header("Authorization", f"Bearer {self.token}")
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
                raw = r.read().decode()
                return r.status, (json.loads(raw) if raw.strip() else None)
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode()[:400]
        except Exception as e:
            return 0, f"{type(e).__name__}: {e}"

    def ok(self, method, path, body=None, expect=(200, 201, 202, 204)):
        st, b = self._call(method, path, body)
        if st not in expect:
            raise RuntimeError(f"{method} {path} -> HTTP {st}: {str(b)[:300]}")
        return b

    # --- reads -------------------------------------------------------------
    def _rows(self, path, key):
        b = self.ok("GET", path)
        rows = b.get(key, b) if isinstance(b, dict) else b
        out = []
        for r in rows if isinstance(rows, list) else []:
            # /api/runs wraps each row as {"active": ..., "run": {...}}
            out.append(r.get(key[:-1], r) if isinstance(r, dict) and key[:-1] in r else r)
        return out

    def mines(self):
        return self._rows("/api/mines", "mines")

    def scenarios(self):
        return self._rows("/api/scenarios", "scenarios")

    def runs(self):
        return self._rows("/api/runs", "runs")

    def metrics(self, run_id):
        b = self.ok("GET", f"/api/runs/{run_id}/metrics")
        return b.get("metrics", b) if isinstance(b, dict) else b

    def cycles(self, run_id):
        b = self.ok("GET", f"/api/runs/{run_id}/cycles")
        return b.get("cycles", b) if isinstance(b, dict) else b

    def status(self, run_id):
        b = self.ok("GET", f"/api/runs/{run_id}")
        inner = b.get("run", b) if isinstance(b, dict) else {}
        return inner.get("status") if isinstance(inner, dict) else None

    # --- writes ------------------------------------------------------------
    def create_mine(self, **kw):
        return self.ok("POST", "/api/mines", kw)

    def create_scenario(self, **kw):
        return self.ok("POST", "/api/scenarios", kw)

    def start_run(self, **kw):
        return self.ok("POST", "/api/runs", kw)["id"]

    def wait(self, run_id, budget=300, poll=2):
        deadline = time.time() + budget
        while time.time() < deadline:
            s = self.status(run_id)
            if s in ("completed", "failed", "cancelled"):
                return s
            time.sleep(poll)
        return self.status(run_id)

    def delete(self, kind, ident):
        """Idempotent: a thing already gone is a thing successfully removed."""
        if kind == "run" and self.status(ident) in ("pending", "running"):
            self._call("POST", f"/api/runs/{ident}/cancel")
            time.sleep(2)
        st, _ = self._call("DELETE", f"/api/{kind}s/{ident}")
        return st in (200, 204, 404)


class Sweep:
    """Whatever this created, it removes -- however the command ends."""

    def __init__(self, api):
        self.api, self.made = api, []

    def track(self, kind, ident):
        if ident:
            self.made.append((kind, ident))
        return ident

    def clean(self, quiet=False):
        leaked = []
        for kind, ident in reversed(self.made):
            if not self.api.delete(kind, ident):
                leaked.append(f"{kind} {ident}")
        self.made.clear()
        if leaked and not quiet:
            print("\nLEFT BEHIND (delete by hand):", file=sys.stderr)
            for x in leaked:
                print(f"  {x}", file=sys.stderr)
        return not leaked


def secs(v):
    v = float(v or 0)
    if v < 90:
        return f"{v:,.0f} s"
    if v < 5400:
        return f"{v/60:,.0f} m"
    return f"{v/3600:,.1f} h"


def cmd_list(api, args):
    for kind in (args.what or ["mines", "scenarios", "runs"]):
        rows = getattr(api, kind)()
        print(f"{kind} ({len(rows)})")
        for r in rows:
            name = r.get("name", "")
            extra = f"  {r['status']}" if r.get("status") else ""
            print(f"   {r.get('id','?'):38} {name[:44]}{extra}")


def cmd_compare(api, args):
    """One workload, several cloud caps. The seed is what makes it a comparison."""
    tag = f"exp-{int(time.time())}"
    sweep = Sweep(api)
    caps = [int(c) for c in args.cloud_caps.split(",")]
    results = []
    try:
        api.create_mine(id=f"{tag}-mine", name=f"{args.mine_name}",
                        sensors=args.sensors, background_rate_per_hour=args.rate)
        sweep.track("mine", f"{tag}-mine")

        scenario = dict(
            id=f"{tag}-scn", mine_id=f"{tag}-mine", name="experiment",
            duration_seconds=args.duration, job_seconds=args.job_seconds,
            seed=args.seed, priority_mix=json.loads(args.priority_mix))
        if args.burst_at is not None:
            scenario["bursts"] = [{"at_seconds": args.burst_at,
                                   "magnitude": args.burst_magnitude,
                                   "aftershock_decay_seconds": args.burst_decay}]
        api.create_scenario(**scenario)
        sweep.track("scenario", f"{tag}-scn")

        for cap in caps:
            rid = api.start_run(
                name=f"{tag} cloud={cap}", mode="simulation", scenario_id=f"{tag}-scn",
                decision_interval_seconds=args.interval,
                time_compression=args.compression,
                settings={"local_executor_cap": args.local_cap, "cloud_executor_cap": cap})
            sweep.track("run", rid)
            state = api.wait(rid, budget=args.budget)
            m = api.metrics(rid) if state == "completed" else {}
            results.append((cap, state, m))
            print(f"  cloud_executor_cap={cap:<4} {state}", file=sys.stderr)

        submitted = {r[2].get("jobs_submitted") for r in results if r[2]}
        print()
        print(f"scenario {tag}-scn   seed {args.seed}   local cap {args.local_cap}")
        if len(submitted) == 1:
            print(f"every run replayed the identical {submitted.pop():,} jobs — the seed held")
        elif submitted:
            print(f"!! job counts differ between runs {sorted(submitted)} — not a fair comparison")
        print()
        head = f"{'cloud cap':>10} {'breaches':>10} {'rate':>8} {'mean wait':>11} {'p95 wait':>11} {'peak q':>8} {'cloud h':>9}"
        print(head)
        print("-" * len(head))
        for cap, state, m in results:
            if not m:
                print(f"{cap:>10} {state:>10}")
                continue
            print(f"{cap:>10} {m.get('sla_breaches',0):>10,} "
                  f"{m.get('breach_rate',0)*100:>7.2f}% "
                  f"{secs(m.get('mean_wait_seconds')):>11} "
                  f"{secs(m.get('p95_wait_seconds')):>11} "
                  f"{m.get('peak_queue_depth',0):>8,} "
                  f"{(m.get('cloud_executor_seconds',0) or 0)/3600:>9.1f}")
        if args.json:
            print()
            print(json.dumps([{"cloud_executor_cap": c, "status": s, "metrics": m}
                              for c, s, m in results], indent=2))
    finally:
        if args.keep:
            print(f"\nkept: everything prefixed {tag} (delete with: "
                  f"{Path(__file__).name} cleanup --prefix {tag})", file=sys.stderr)
            sweep.made.clear()
        else:
            sweep.clean()


def cmd_run(api, args):
    tag = f"exp-{int(time.time())}"
    sweep = Sweep(api)
    try:
        api.create_mine(id=f"{tag}-mine", name=args.mine_name,
                        sensors=args.sensors, background_rate_per_hour=args.rate)
        sweep.track("mine", f"{tag}-mine")
        api.create_scenario(id=f"{tag}-scn", mine_id=f"{tag}-mine", name="run",
                            duration_seconds=args.duration, job_seconds=args.job_seconds,
                            seed=args.seed, priority_mix=json.loads(args.priority_mix))
        sweep.track("scenario", f"{tag}-scn")
        rid = api.start_run(name=f"{tag}", mode="simulation", scenario_id=f"{tag}-scn",
                            decision_interval_seconds=args.interval,
                            time_compression=args.compression,
                            settings={"local_executor_cap": args.local_cap,
                                      "cloud_executor_cap": args.cloud_cap})
        sweep.track("run", rid)
        print(f"run {rid}: {api.wait(rid, budget=args.budget)}")
        print(json.dumps(api.metrics(rid), indent=2))
        cyc = api.cycles(rid)
        print(f"\n{len(cyc)} decisions. First three, with the reasoning each carries:")
        for c in cyc[:3]:
            print(f"  #{c.get('sequence')} {c.get('action')} "
                  f"-> local {c.get('plan_local')}, cloud {c.get('plan_cloud')}")
            print(f"     {c.get('reason','')}")
    finally:
        if args.keep:
            print(f"kept: {tag}", file=sys.stderr)
            sweep.made.clear()
        else:
            sweep.clean()


def cmd_cleanup(api, args):
    """Remove leftovers by id prefix. Only ever what the prefix matches."""
    if not args.prefix:
        sys.exit("--prefix is required: this will not guess what is yours")
    n = 0
    for kind, rows in (("run", api.runs()), ("scenario", api.scenarios()), ("mine", api.mines())):
        for r in rows:
            ident, name = str(r.get("id", "")), str(r.get("name", ""))
            if ident.startswith(args.prefix) or name.startswith(args.prefix):
                print(f"  delete {kind} {ident} {name[:40]}")
                api.delete(kind, ident)
                n += 1
    print(f"removed {n}")


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--url", help="default: from $SIMLAB_URL, else simlab-env.sh")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("mines", help="list mines");      s.set_defaults(fn=cmd_list, what=["mines"])
    s = sub.add_parser("scenarios", help="list scenarios"); s.set_defaults(fn=cmd_list, what=["scenarios"])
    s = sub.add_parser("runs", help="list runs");        s.set_defaults(fn=cmd_list, what=["runs"])
    s = sub.add_parser("ls", help="list everything");    s.set_defaults(fn=cmd_list, what=None)

    def workload(sp):
        sp.add_argument("--sensors", type=int, default=40)
        sp.add_argument("--rate", type=float, default=60, help="background events per hour")
        sp.add_argument("--duration", type=int, default=3600, help="scenario seconds")
        sp.add_argument("--job-seconds", type=float, default=20)
        sp.add_argument("--seed", type=int, default=42)
        sp.add_argument("--priority-mix", default='{"100":1,"25":3}',
                        help='JSON weights per priority, e.g. \'{"100":1,"25":3}\'')
        sp.add_argument("--local-cap", type=int, default=20)
        sp.add_argument("--interval", type=int, default=15, help="decision interval seconds")
        sp.add_argument("--compression", type=int, default=100000)
        sp.add_argument("--budget", type=int, default=300, help="seconds to wait per run")
        sp.add_argument("--mine-name", default="experiment site")
        sp.add_argument("--keep", action="store_true", help="leave it in the browser")

    s = sub.add_parser("compare", help="one workload, several cloud caps")
    workload(s)
    s.add_argument("--cloud-caps", default="0,40")
    s.add_argument("--burst-at", type=int, default=600, help="seconds; omit with --no-burst")
    s.add_argument("--burst-magnitude", type=float, default=30)
    s.add_argument("--burst-decay", type=int, default=900)
    s.add_argument("--no-burst", dest="burst_at", action="store_const", const=None)
    s.add_argument("--json", action="store_true", help="also print the raw metrics")
    s.set_defaults(fn=cmd_compare)

    s = sub.add_parser("run", help="one run, with its decisions")
    workload(s)
    s.add_argument("--cloud-cap", type=int, default=40)
    s.set_defaults(fn=cmd_run)

    s = sub.add_parser("cleanup", help="remove things by id or name prefix")
    s.add_argument("--prefix", required=True)
    s.set_defaults(fn=cmd_cleanup)

    args = p.parse_args()
    url, token = (args.url.rstrip("/"), os.environ.get("SIMLAB_TOKEN")) if args.url else discover()
    try:
        args.fn(Simlab(url, token), args)
    except RuntimeError as e:
        sys.exit(str(e))
    except KeyboardInterrupt:
        sys.exit(130)


if __name__ == "__main__":
    main()
