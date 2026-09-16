# H3 load-test scripts

Scripts for driving and timing bulk writes/reads against the H3 NATS KV
load-test harness (`h3-ingest`, `h3-distribute`, and the native comparison
distributor).

- `lib.sh` — shared helpers (H3 index generator matching the bit layout used
  throughout this project, timing/stats functions). Source, don't run.
- `load-ingest.sh [TOTAL_POINTS] [BATCH_SIZE] [TIMESTAMP]` — bulk write via
  batched `POST /ingest`. Defaults: 40000 points, batch size 500, current
  UTC minute.
- `load-query.sh TIMESTAMP [BY_KEY_SAMPLE_SIZE]` — bulk read via
  `GET /points?timestamp=...` (the wildcard/all-cells-at-time-T query) plus
  a sampled by-key latency distribution, against both the component-based
  distributor and, if `NATIVE_URL` is set, the native comparison
  distributor, so the two are directly comparable.
- `load-cleanup.sh TIMESTAMP | --all` — wraps the delete endpoints to clear
  test data between runs.
- `bulk_load.py [-c CONCURRENCY] [-n REQUESTS] [--expect POINTS] TIMESTAMP...`
  — concurrent bulk-scan load: runs `REQUESTS` `GET /points?timestamp=...`
  calls round-robin over the timestamps with `CONCURRENCY` in flight, checks
  every response is a 200 with a complete point set, and prints successes,
  points/bytes returned, latency, and throughput. Python 3 standard library
  only. Use this rather than backgrounding `curl` from bash for concurrent
  runs.

## Example

```bash
# Optional: tunnel to the native comparison distributor for a side-by-side
kubectl -n twosix-dev port-forward svc/h3-native-distributor 18080:8080 &

./load-ingest.sh 40000 500 2026.09.09.12.00
NATIVE_URL=http://127.0.0.1:18080 ./load-query.sh 2026.09.09.12.00 500
./load-cleanup.sh 2026.09.09.12.00
```

Concurrent bulk scans, e.g. five timestamps each ingested at the generator's
maximum of 41,846 points, 64 requests with 32 in flight:

```bash
for m in 00 01 02 03 04; do ./load-ingest.sh 41846 500 2026.09.13.00.$m; done
./bulk_load.py -c 32 -n 64 --expect 41846 \
  2026.09.13.00.00 2026.09.13.00.01 2026.09.13.00.02 2026.09.13.00.03 2026.09.13.00.04
```

Throughput under concurrency depends on the HTTPTrigger's `poolSize` ×
`maxConcurrency` (warm instances × calls each may serve at once), set in
`../manifests/`. Past that many requests in flight, calls queue. A bulk scan
can also run past Envoy's default 15s upstream timeout, which the manifests
raise via `spec.timeout`.

## Environment

All requests go through `127.0.0.1` with an explicit `Host` header
(`INGEST_HOST`/`DISTRIBUTE_HOST`, overridable), since this dev environment
has no `/etc/hosts` write access. If your environment can resolve the real
hostnames, this still works unchanged.
