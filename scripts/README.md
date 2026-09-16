# scripts

| | |
|---|---|
| `simlab-env.sh` | Prints the deployed platform's token and URLs as shell exports, read from the cluster Secret the services themselves read. `eval "$(scripts/simlab-env.sh)"`, or `--json`. |
| `simlab.py` | Drives a deployed Simlab for experiments. Finds its own credentials via `simlab-env.sh`. |
| `publish-chart.sh` | Packages the platform as one self-contained chart and pushes it to an OCI registry. |

## Experiments

```bash
scripts/simlab.py ls
scripts/simlab.py compare --cloud-caps 0,20,40 --local-cap 20
scripts/simlab.py run --cloud-cap 40 --keep      # leave it in the browser
scripts/simlab.py cleanup --prefix exp-
```

`compare` runs one workload under several cloud caps and prints the result. The
scenario carries a seed, so every run replays identical work and the only thing
that differs is the policy — it says so explicitly, and says so loudly if the
job counts ever diverge, because a comparison across different work is not one.

Everything these create is prefixed per invocation and removed when the command
finishes, including on failure. Anything that could not be removed is named on
stderr and the command says so rather than going quiet. `--keep` opts out, and
prints the `cleanup` line that undoes it.

Simulation runs only: the real decision engine, nothing provisioned. That is
what makes them safe to point at a live deployment.
