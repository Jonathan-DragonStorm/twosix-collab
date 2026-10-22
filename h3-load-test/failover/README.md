# h3 failover testing

Repeatable failover tests for the h3 pipeline on Cosmonic Control. Each
scenario drives continuous traffic at the `h3-ingest` and `h3-distribute`
endpoints, force-kills one pod, and measures how long each endpoint takes to
return to healthy operation and whether any acknowledged writes were lost.
The suite runs every scenario under one or more **scale profiles**:

- the data plane: h3 host pods × replicas of each workload;
- the Cosmonic Control plane: Envoy, Nexus and operator pods.

It then writes a combined report, so the all-single-instance worst case and a
scaled-up configuration can be compared side by side.

## Quick start

```bash
cd h3-load-test/failover
./run_suite.sh                 # single (everything ×1), then ha (2×2 hosts/replicas, envoy 2, nexus 3, operator 2)
open results/<timestamp>/report.md
```

The run takes about 25 minutes. Everything in place before the run is
restored when it exits, including on failure or Ctrl-C: host pods, workload
replicas, and Envoy, Nexus and operator counts.

## Prerequisites

- `kubectl` pointed at the cluster (`kind-kind`), plus `helm`, `jq`, `python3`
  (standard library only) and `curl`.
- Helm 4 (for the post-renderer plugin; see [Control-plane scaling](#control-plane-scaling)).
- Cosmonic Control 0.14+ with the `hostgroup-h3` Helm release, and the
  `h3-ingest` / `h3-distribute` HTTPTriggers deployed in `twosix-dev` and
  returning 200 on `/openapi.json`. The suite checks this first and stops if
  either endpoint is unhealthy.
- Ingress reachable at `http://127.0.0.1` (Traefik on the kind node's port 80).
  Requests carry an explicit `Host` header, so no `/etc/hosts` entries are
  needed.

## Files

| File | Purpose |
|---|---|
| `run_suite.sh` | Master script: for each profile, scale → run each scenario → wait healthy; then build the report and restore scale. |
| `scale.sh` | `--hosts N --replicas N --envoy N --nexus N --operator N` (any subset; `scale.sh HOSTS [REPLICAS]` also works). Scales the data plane and/or control plane, waits until everything is Ready and the endpoints answer, and prints placement. Usable on its own. |
| `failover_probe.py` | Runs one scenario: seed, baseline traffic, kill, measure, check data. Writes `<profile>-<scenario>.json` and `.csv`. |
| `report.py RESULTS_DIR` | Builds `report.md` from a results directory. Rerun it at any time; it only reads files. |
| `lib.sh` | Shared shell helpers: health waits, placement, `rebalance` (spread colocated replicas across hosts), control-plane scaling. |
| `helm-plugins/operator-replicas/` | Helm post-renderer plugin that sets the operator Deployment's replica count, which the 0.14 chart hard-codes to 1. Installed automatically by `scale.sh`. |
| `results/` | One timestamped directory per suite run (git-ignored). |

## Scenarios

| Name | What is killed | Why |
|---|---|---|
| `host` | The `hostgroup-h3` pod running a replica of `h3-ingest` (found through Workload → Host → pod IP) | The data plane: the wasmCloud host running the components. |
| `envoy` | The Envoy ingress pod | Every HTTPTrigger request passes through it. |
| `nexus` | A Nexus (control-plane NATS) pod, the first one (`nexus-0`) | Carries host ↔ operator traffic. |
| `operator` | The operator pod **holding the leader lease** (`d34db3ef.cosmonic.io`) | Control plane only. With more than one replica, the others are standbys. |

Every kill is `kubectl delete pod --grace-period=0 --force`: no drain, as in a
crash. Kubernetes then recreates the pod from its Deployment or StatefulSet.

The control-plane scenarios (`envoy`, `nexus`, `operator`) also run a
**reconcile canary**. Right after the kill, one replica of an unprobed
workload (`CANARY`, default `h3-distribute-sharded`) is deleted. The report
records how long the control plane takes to place and ready its replacement.
Killing Nexus or the operator usually doesn't touch request traffic, so this
is how their outage shows up. Note that the canary workload's own endpoint
is briefly down while its replica is replaced.

## Profiles

| Name | Host pods | Workload replicas | Envoy | Nexus | Operator |
|---|---|---|---|---|---|
| `single` | 1 | 1 | 1 | 1 | 1 |
| `ha` | `HA_HOSTS` (2) | `HA_REPLICAS` (= hosts) | `HA_ENVOY` (2) | `HA_NEXUS` (3) | `HA_OPERATOR` (2) |
| `NxM` | N | M | 1 | 1 | 1 |
| any name | `PROFILE_<name>="hosts=2,replicas=2,envoy=2,nexus=3,operator=2"`; omitted keys are 1, and `replicas` defaults to `hosts` | | | | |

`single` is the worst case, with nothing to fail over to. Nexus must be odd
(1, 3, 5) for a JetStream quorum.

**Replica placement.** The operator places a replica on a host that exists
when the replica is created, and never moves it afterwards. Two things can
therefore leave several replicas of one workload on the same host, so that
one host kill takes all of them out:

- creating replicas before newly scaled hosts have registered;
- any host failure, because the lost replicas are re-placed onto the
  survivors.

To avoid this, `scale.sh` waits for every host to register before scaling
the workloads. Then both `scale.sh` and `run_suite.sh` (before each
scenario) run `rebalance`: it deletes one colocated replica at a time and
waits for its replacement to be placed and Ready before touching another.
The scheduler doesn't reliably choose the emptier host, so this can take a
few attempts (up to 10). Each replacement is Ready within about a second,
and the sibling keeps serving throughout. Each scenario's placement before the kill is recorded in the
report.

## Control-plane scaling

These are the Cosmonic-supported mechanisms, with the quirks of the 0.14.0
chart worked around:

- **Envoy:** `envoy.replicas` on the `cosmonic-control` release. Every
  replica receives the same routes from the operator. With more than one
  replica the chart also renders a PodDisruptionBudget (`maxUnavailable: 1`).
- **Nexus:** `nexus.replicas` (odd) needs `nexus.persistence.enabled: true`,
  which runs Nexus as a StatefulSet with one PVC per node (`data-nexus-N`).
  `scale.sh` always sets persistence on, so the single profile runs 1 node of
  the same StatefulSet.
  - The first switch from the chart's default Deployment replaces the pod.
    Nexus' JetStream store was empty on this cluster (no workload uses Nexus
    key-value), and the switch caused no failed requests.
  - **Chart bug:** the cluster routes live in the `nexus` ConfigMap, and the
    StatefulSet doesn't roll when they change. After `nexus.replicas` 1 → 3,
    `nexus-0` kept its standalone config and the two new nodes couldn't form a
    quorum ("JetStream has not established contact with a meta leader").
    `scale.sh` therefore runs `kubectl rollout restart statefulset/nexus`
    whenever the count changes, waits for a JetStream metadata leader, and on
    scale-down deletes the removed nodes' PVCs so a later scale-up starts clean.
- **Operator:** the chart hard-codes `replicas: 1` in the operator
  Deployment. Cosmonic say it will become a value in the next release. The
  binary always runs with `-leader-elect`, so extra replicas are hot
  standbys. Two ways to override it:
  - `kubectl scale deploy/operator --replicas=2` works, but **breaks the next
    Helm upgrade** of `cosmonic-control`. Helm 4 uses server-side apply, so the
    upgrade fails with `conflict with "kubectl" with subresource "scale" ...
    .spec.replicas`. That failed upgrade still applies some objects before it
    stops, leaving the release half-applied.
  - **Use the post-renderer instead**, as `scale.sh` does:
    `helm upgrade cosmonic-control ... --post-renderer operator-replicas
    --post-renderer-args 2`. Helm then owns the value. Add `--force-conflicts`
    once if `kubectl scale` was used before. Every later upgrade must pass the
    post-renderer too, or the operator goes back to 1.

## Options

All options are environment variables:

| Variable | Default | |
|---|---|---|
| `PROFILES` | `single ha` | Profiles to run, in order. |
| `HA_HOSTS` / `HA_REPLICAS` | `2` / `HA_HOSTS` | Data-plane size of the `ha` profile. |
| `HA_ENVOY` / `HA_NEXUS` / `HA_OPERATOR` | `2` / `3` / `2` | Control-plane size of the `ha` profile. |
| `PROFILE_<name>` | — | Define a custom profile, e.g. `PROFILE_envoyha="envoy=2"`. |
| `SCENARIOS` | `host envoy nexus operator` | Scenarios to run under each profile. |
| `CANARY` | `h3-distribute-sharded` | Unprobed workload for the reconcile canary (`CANARY=` disables). |
| `WORKLOADS` | `h3-ingest h3-distribute` | WorkloadDeployments to scale and inspect. The first one picks the host to kill. |
| `PROBE_ARGS` | — | Extra `failover_probe.py` flags, e.g. `"--baseline 30 --interval 0.1"`. |
| `PAUSE` | `10` | Quiet seconds between scenarios. |
| `RESTORE` | `1` | `0` leaves the last profile's scale in place. |
| `OUT` | `results/<timestamp>` | Results directory. |
| `NAMESPACE`, `HOSTGROUP_RELEASE`, `BASE_URL`, `INGEST_HOST`, `DISTRIBUTE_HOST` | `twosix-dev`, `hostgroup-h3`, `http://127.0.0.1`, … | Cluster and endpoint coordinates. |

Examples:

```bash
PROFILES=single ./run_suite.sh                        # worst case only
HA_HOSTS=3 HA_REPLICAS=3 ./run_suite.sh               # data plane 3×3 in the ha profile
PROFILES="2x1 2x2" SCENARIOS=host ./run_suite.sh      # more hosts vs more replicas
PROFILE_e2="envoy=2" PROFILE_e3="envoy=3" PROFILES="single e2 e3" SCENARIOS=envoy ./run_suite.sh
PROFILES=single SCENARIOS="nexus operator" ./run_suite.sh
PROBE_ARGS="--stable 25 --settle 60" ./run_suite.sh   # stricter recovery, longer observation

./scale.sh --hosts 2 --replicas 2 --envoy 2 --nexus 3 --operator 2   # scale by hand
./failover_probe.py --profile manual --scenario host --kill-workload-host h3-ingest --out results/manual
./report.py results/manual
```

## What is measured

Each scenario runs for `--baseline` (15s) before the kill and keeps going
until both endpoints have recovered, then for `--settle` (30s) more.

- **Ingest:** a `POST /ingest` with one new, unique point every 200ms.
- **Distribute:** a `GET /points/{h3}/{timestamp}` for a point seeded before
  the run, every 200ms. Each request has a 2s client timeout.
- **Recovered:** the first success after the kill that begins `--stable` (10)
  consecutive successes. *Downtime* = kill → recovered. Failures after that
  point are reported separately as *failures after recovery*, which catches
  flapping and requests routed late to the dead host.
- **Data loss:** ingest is asynchronous (gateway → ingester → core NATS
  `h3.ingest.raw` → KV `h3-points`). After the run, every point the ingest
  endpoint acknowledged with HTTP 200 is read back. A point that is missing
  was accepted and then dropped. Requests that got a non-200 are not counted:
  the client was told the write failed.
- **Control-plane reconcile** (`envoy`, `nexus`, `operator` scenarios): kill
  → the canary workload's deleted replica has been replaced and is Ready.
- **Timeline:** polled every 0.5s, showing where recovery time goes (pod
  scheduling, host registration, workload placement):
  - pod, Host CR and WorkloadDeployment readiness;
  - the operator's leader-lease holder;
  - canary events.

Probe points use a dedicated timestamp per run (`<today>.23.40` onwards) and
are deleted after each scenario.

## Reading the report

`report.md` contains:

1. **Summary**: one row per profile × scenario, with downtime per endpoint,
   failed request counts, failures after recovery, acked points lost, and
   control-plane reconcile time. *Scale* is written `H×R · E N O`: hosts ×
   replicas, then Envoy, Nexus and operator pods.
2. **Comparison by scenario**: the same scenario across profiles.
3. **Availability strips**: one character per second around the kill, for a
   quick visual of each outage.
4. **Scenario details**: failure status codes, slowest failure, operator
   leader before and after, replica placement before and after, and the
   timeline.

Raw per-request samples are in the `.csv` files (`t_rel_s` is seconds
relative to the kill) for plotting or further analysis.

## Known behaviour (Cosmonic Control 0.14.0, run 2026-10-22)

| Pod killed | single (all ×1) | ha (2×2 · E2 N3 O2) |
|---|---|---|
| h3 host | ~35.6s down on both endpoints | 1 failed request per endpoint (requests in flight on the dying host), then none |
| Envoy | ~12.8s down (Traefik 503s) | no downtime |
| Nexus | no request failures; control plane can't act for ~7.5s | no request failures; control plane unaffected (0.8s) |
| Operator (leader) | no request failures; control plane can't act for ~16.6s | **same ~16.6s** |

No acknowledged writes were lost in any scenario.

- **Single host:** the replacement Host registers within about 2s. The
  operator only places workloads about 30s after its first failed placement
  attempt, which looks like a fixed retry interval. No chart value or
  operator flag exposes it.
- **Envoy:** with one replica, downtime is set by Envoy's readiness probe
  (about 11s after the container starts). With two, Traefik sends traffic to
  the surviving pod and no request failed.
- **Nexus is not in the request path:** killing it never failed a request.
  With one node, the operator can't reach hosts until Nexus is back and
  clients reconnect, about 7.5s. With three, clients fail over to another
  node and the control plane keeps working.
- **Operator HA doesn't speed up crash recovery.** A force-killed leader
  never releases its 15s lease (`d34db3ef.cosmonic.io`). The standby has to
  wait for it to expire, and a restarted single operator is Ready (about 12s)
  within the same window, so both take about 16.6s. A standby helps when the
  replacement can't start promptly: a node failure, a pull or scheduling
  problem. It may also help with a graceful stop, if the operator releases
  its lease on shutdown, which hasn't been tested here. The lease timings
  aren't exposed by the chart.
- **No automatic rebalancing:** after a host is lost, its replicas move to
  the surviving hosts and stay there. The replacement host comes back empty,
  so a second host failure is a full outage unless replicas are respread
  (`rebalance` in `lib.sh` does this). When another host is available, a
  deleted replica is re-placed and Ready within seconds, but not necessarily
  on the emptier host.
- Scaling hosts down is quick (seconds): the departing host deregisters and
  its replicas are re-placed straight away, well within the 150s
  `terminationGracePeriodSeconds`.
- Chart and Helm quirks are covered under [Control-plane scaling](#control-plane-scaling):
  the Nexus ConfigMap doesn't roll the StatefulSet, and `kubectl scale`
  breaks Helm upgrades of the operator.

## Limitations

- **Pod loss only.** A Kubernetes node failure adds the node-eviction delay
  (about 40s or more) before pods are rescheduled. On a multi-node kind
  cluster this can be simulated with `docker stop <node>`, which these
  scripts don't do yet.
- **Single-point probes.** These measure availability, not throughput; use
  `../scripts/bulk_load.py` to see how capacity holds up during failover.
- **Messages in flight.** The data-loss check only covers points acknowledged
  over HTTP. A message already published to core NATS when the ingester dies
  may not be redelivered, and that window is too small for 200ms probes to hit
  reliably.
