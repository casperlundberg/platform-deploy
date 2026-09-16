# End-to-end check

```bash
make e2e          # run it in the cluster and tail it; non-zero if anything failed
make e2e-clean    # remove the Job and its ConfigMap
```

Runs as a Job inside `autoscale-platform`, against the deployed services over
their real Service names. 43 checks: probes, that the autoscaler's auth is
actually enforced, every platform schema carries a `Label`, full CRUD on mines,
scenarios, runs and targets, and the run path that makes simlab-api drive the
real autoscaler.

## Why it is safe to run against live data

It creates only its own rows and mutates nothing it did not create, so there is
nothing of anyone else's to restore. Every mutation pushes its inverse onto a
stack, and the stack unwinds last-first however the process ends — pass, fail,
exception or `SIGTERM`.

That is a saga, not a transaction. HTTP has no rollback, so the guarantee is
*every compensation is attempted, each retried three times, and anything left
behind is named in the output* — not *nothing can ever be left behind*. A
`LEAKED` line means a row needs deleting by hand, and the exit code is non-zero.

**Register the compensation before asserting anything.** This was a real bug
here: the run create was wrapped in `if check(...)`, the API answered `202`
where the check expected `201`, so the compensation was never registered. The
run was left behind *and* the restoration check passed, because it compared
against a set the run had never been added to. A cleanup that only runs when
you guessed the status code correctly is not a cleanup.

## Concurrency

Two copies can run at once, and either can overlap with real use. Every id
carries a per-execution nonce, so nothing collides.

The restoration check compares sets of primary keys, never counts — another
client creating or deleting its own rows must not fail this test. What is
asserted is exactly:

- every primary key that existed at the start still exists, and
- no primary key this created still exists.

Two subtleties, both found by running three copies at once rather than by
reasoning about it:

1. **Rows belonging to another run of this test are excluded** from the first
   assertion. Each instance snapshots at a different moment, so one sees the
   other's rows as pre-existing and then watches them vanish when their owner
   cleans up. That is not data loss.

2. **A simulation run registers a real target in the real autoscaler**, with the
   run's id as the target's id — that is what the simulation adapter is for.
   So deleting a run removes a target too, and target ownership has to follow
   that link or a concurrent instance reports the disappearance as data loss.

Verified with three overlapping instances plus an unrelated row created by a
third party for the duration: 43/43 in each, nothing leaked, and the third
party's row untouched.

## What it does not cover

Only what is reachable over the two HTTP APIs. It does not exercise the SPA,
and it does not touch real Kubernetes or ColonyOS platforms — the target it
creates is on the `simulation` platform, so no external infrastructure is
scaled. The event stream is checked only far enough to confirm it opens and
that the connection is not refused.

## Running it after every sync

Add to the Job and move it into the chart:

```yaml
annotations:
  argocd.argoproj.io/hook: PostSync
  argocd.argoproj.io/hook-delete-policy: HookSucceeded
```

Weigh it first: a failing check then fails the sync, and this test talks to a
database that other things are writing to. A flaky check would block deploys
for reasons unrelated to the deploy.
