# h3 failover test report

- **Run started:** 2026-10-22T17:35:42Z  
- **Cluster:** `kind-kind` (Kubernetes v1.35.0), namespace `twosix-dev`  
- **Host runtime:** 2.11.0; charts: `cosmonic-control` cosmonic-control-0.14.0, `hostgroup-a` cosmonic-control-hostgroup-0.14.0, `hostgroup-h3` cosmonic-control-hostgroup-0.14.0, `nats` nats-2.14.6  
- **Workloads probed:** h3-ingest, h3-distribute  
- **Profiles** (`H×R · E N O` = h3 host pods × workload replicas · Envoy, Nexus, operator pods):
  - `single`: 1 host pod(s) × 1 replica(s), envoy 1, nexus 1, operator 1
  - `ha`: 2 host pod(s) × 2 replica(s), envoy 2, nexus 3, operator 2
- **Reconcile canary:** `h3-distribute-sharded`

Each scenario sends one request per endpoint every 0.2s, force-deletes one pod (`--grace-period=0 --force`), and counts an endpoint as recovered at the first success that starts a run of 10 consecutive successes. *Downtime* is kill → recovery. *Lost* counts points the ingest endpoint acknowledged (HTTP 200) that never became readable. *Control-plane reconcile* (control-plane scenarios only): right after the kill one replica of the unprobed canary workload is deleted, and this is kill → its replacement placed and Ready, i.e. how long the control plane cannot act.

## Summary

| Profile | Scale | Scenario | Killed pod | Ingest downtime | Distribute downtime | Failed req (ingest / distribute) | Failures after recovery | Acked points lost | Control-plane reconcile |
|---|---|---|---|---|---|---|---|---|---|
| single | 1×1 · E1 N1 O1 | host | `hostgroup-h3-6578bb8b8c-v57dl` | 35.6s | 35.7s | 174 / 175 | 0 | 0 / 238 | — |
| single | 1×1 · E1 N1 O1 | envoy | `envoy-6d556d6d56-gd49l` | 12.8s | 12.8s | 53 / 53 | 0 | 0 / 236 | 0.8s |
| single | 1×1 · E1 N1 O1 | nexus | `nexus-0` | none | none | 0 / 0 | 0 | 0 / 263 | 7.5s |
| single | 1×1 · E1 N1 O1 | operator | `operator-6c77c7fcd5-rhsh7` | none | none | 0 / 0 | 0 | 0 / 308 | 16.6s |
| ha | 2×2 · E2 N3 O2 | host | `hostgroup-h3-6578bb8b8c-rcbnr` | 0.2s | 2.2s | 1 / 1 | 0 | 0 / 243 | — |
| ha | 2×2 · E2 N3 O2 | envoy | `envoy-6d556d6d56-hm5nh` | none | none | 0 / 0 | 0 | 0 / 238 | 2.1s |
| ha | 2×2 · E2 N3 O2 | nexus | `nexus-0` | none | none | 0 / 0 | 0 | 0 / 233 | 0.8s |
| ha | 2×2 · E2 N3 O2 | operator | `operator-6c77c7fcd5-6n9qd` | none | none | 0 / 0 | 0 | 0 / 307 | 16.6s |

## Comparison by scenario

**host**

| Profile | Scale | Ingest downtime | Distribute downtime | Failed requests (total) | Control-plane reconcile |
|---|---|---|---|---|---|
| single | 1×1 · E1 N1 O1 | 35.6s | 35.7s | 349 | — |
| ha | 2×2 · E2 N3 O2 | 0.2s | 2.2s | 2 | — |

**envoy**

| Profile | Scale | Ingest downtime | Distribute downtime | Failed requests (total) | Control-plane reconcile |
|---|---|---|---|---|---|
| single | 1×1 · E1 N1 O1 | 12.8s | 12.8s | 106 | 0.8s |
| ha | 2×2 · E2 N3 O2 | none | none | 0 | 2.1s |

**nexus**

| Profile | Scale | Ingest downtime | Distribute downtime | Failed requests (total) | Control-plane reconcile |
|---|---|---|---|---|---|
| single | 1×1 · E1 N1 O1 | none | none | 0 | 7.5s |
| ha | 2×2 · E2 N3 O2 | none | none | 0 | 0.8s |

**operator**

| Profile | Scale | Ingest downtime | Distribute downtime | Failed requests (total) | Control-plane reconcile |
|---|---|---|---|---|---|
| single | 1×1 · E1 N1 O1 | none | none | 0 | 16.6s |
| ha | 2×2 · E2 N3 O2 | none | none | 0 | 16.6s |


## Availability around the kill

One character per second from -5s to +60s (kill at `|`): `█` all requests ok, `▒` some failed, `░` all failed.

```
single/host ingest          █████|▒░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▒████████████████████████
single/host distribute      █████|░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▒████████████████████████
single/envoy ingest         █████|░ ░░░░░░░░░░▒█████████████████████████████████              
single/envoy distribute     █████|░ ░░░░░░░░░░▒█████████████████████████████████              
single/nexus ingest         █████|███████████████████████████████████████                     
single/nexus distribute     █████|███████████████████████████████████████                     
single/operator ingest      █████|████████████████████████████████████████████████            
single/operator distribute  █████|███████████████████████████████████████████████             
ha/host ingest              █████|▒█████████████████████████████████                          
ha/host distribute          █████|▒ █████████████████████████████████                         
ha/envoy ingest             █████|█████████████████████████████████                           
ha/envoy distribute         █████|█████████████████████████████████                           
ha/nexus ingest             █████|████████████████████████████████                            
ha/nexus distribute         █████|████████████████████████████████                            
ha/operator ingest          █████|███████████████████████████████████████████████             
ha/operator distribute      █████|███████████████████████████████████████████████             
```

## Scenario details

### single / host

Killed `pod/hostgroup-h3-6578bb8b8c-v57dl`.

Operator leader: `operator-6c77c7fcd5-rhsh7` unchanged.

| Endpoint | Baseline ok | First failure | Recovered | Failed requests | After recovery | Failure statuses | Slowest failure |
|---|---|---|---|---|---|---|---|
| ingest | 76/76 | +0.2s | 35.6s | 174 | 0 | 503×174 | 28ms |
| distribute | 76/76 | +0.1s | 35.7s | 175 | 0 | 404×1, 503×174 | 32ms |

Data: 238 points acknowledged, 0 lost.

Placement before kill:

```
h3-distribute-657bb85f7d-64ffcb574f           host=new-donkey-6421  pod=hostgroup-h3-6578bb8b8c-v57dl
h3-ingest-685d688dc4-97f68d67f                host=new-donkey-6421  pod=hostgroup-h3-6578bb8b8c-v57dl
```
Placement after recovery:

```
h3-distribute-657bb85f7d-5fd59cdb78           host=superb-beast-1997  pod=hostgroup-h3-6578bb8b8c-rcbnr
h3-ingest-685d688dc4-68bc5f775                host=superb-beast-1997  pod=hostgroup-h3-6578bb8b8c-rcbnr
```
Timeline:

```
  -0.00s  host/new-donkey-6421 gone
  -0.00s  wd/h3-distribute ready=False replicas=0/1
  -0.00s  wd/h3-ingest ready=False replicas=0/1
  +0.00s  KILL pod/hostgroup-h3-6578bb8b8c-v57dl
  +0.78s  host/superb-beast-1997 ready=False
  +0.78s  pod/hostgroup-h3-6578bb8b8c-rcbnr Pending ready=False
  +0.78s  pod/hostgroup-h3-6578bb8b8c-v57dl gone
  +1.57s  pod/hostgroup-h3-6578bb8b8c-rcbnr Running ready=False
  +2.40s  host/superb-beast-1997 ready=True
 +12.36s  pod/hostgroup-h3-6578bb8b8c-rcbnr Running ready=True
 +35.39s  wd/h3-distribute ready=True replicas=1/1
 +35.39s  wd/h3-ingest ready=True replicas=1/1
```

### single / envoy

Killed `pod/envoy-6d556d6d56-gd49l`.

Operator leader: `operator-6c77c7fcd5-rhsh7` unchanged.

Control-plane reconcile: 0.8s (canary `h3-distribute-sharded-6cb7c8b64c-56f8d7dff5`).

| Endpoint | Baseline ok | First failure | Recovered | Failed requests | After recovery | Failure statuses | Slowest failure |
|---|---|---|---|---|---|---|---|
| ingest | 76/76 | +0.2s | 12.8s | 53 | 0 | 503×52, ERR:timeout×1 | 2002ms |
| distribute | 76/76 | +0.2s | 12.8s | 53 | 0 | 503×52, ERR:timeout×1 | 2002ms |

Data: 236 points acknowledged, 0 lost.

Placement before kill:

```
h3-distribute-657bb85f7d-5fd59cdb78           host=superb-beast-1997  pod=hostgroup-h3-6578bb8b8c-rcbnr
h3-ingest-685d688dc4-68bc5f775                host=superb-beast-1997  pod=hostgroup-h3-6578bb8b8c-rcbnr
```
Placement after recovery:

```
h3-distribute-657bb85f7d-5fd59cdb78           host=superb-beast-1997  pod=hostgroup-h3-6578bb8b8c-rcbnr
h3-ingest-685d688dc4-68bc5f775                host=superb-beast-1997  pod=hostgroup-h3-6578bb8b8c-rcbnr
```
Timeline:

```
  +0.00s  KILL pod/envoy-6d556d6d56-gd49l
  +0.21s  CANARY delete workload/h3-distribute-sharded-6cb7c8b64c-56f8d7dff5
  +0.73s  pod/envoy-6d556d6d56-gd49l gone
  +0.73s  pod/envoy-6d556d6d56-v4vbr Pending ready=False
  +0.82s  CANARY h3-distribute-sharded back to 1 Ready replica(s)
  +2.28s  pod/envoy-6d556d6d56-v4vbr Running ready=False
 +12.86s  pod/envoy-6d556d6d56-v4vbr Running ready=True
```

### single / nexus

Killed `pod/nexus-0`.

Operator leader: `operator-6c77c7fcd5-rhsh7` unchanged.

Control-plane reconcile: 7.5s (canary `h3-distribute-sharded-6cb7c8b64c-67694474bf`).

| Endpoint | Baseline ok | First failure | Recovered | Failed requests | After recovery | Failure statuses | Slowest failure |
|---|---|---|---|---|---|---|---|
| ingest | 75/75 | — | none | 0 | 0 | — | 0ms |
| distribute | 75/75 | — | none | 0 | 0 | — | 0ms |

Data: 263 points acknowledged, 0 lost.

Placement before kill:

```
h3-distribute-657bb85f7d-5fd59cdb78           host=superb-beast-1997  pod=hostgroup-h3-6578bb8b8c-rcbnr
h3-ingest-685d688dc4-68bc5f775                host=superb-beast-1997  pod=hostgroup-h3-6578bb8b8c-rcbnr
```
Placement after recovery:

```
h3-distribute-657bb85f7d-5fd59cdb78           host=superb-beast-1997  pod=hostgroup-h3-6578bb8b8c-rcbnr
h3-ingest-685d688dc4-68bc5f775                host=superb-beast-1997  pod=hostgroup-h3-6578bb8b8c-rcbnr
```
Timeline:

```
  +0.00s  KILL pod/nexus-0
  +0.22s  CANARY delete workload/h3-distribute-sharded-6cb7c8b64c-67694474bf
  +0.40s  pod/nexus-0 Pending ready=False
  +1.94s  pod/nexus-0 Running ready=False
  +2.72s  pod/nexus-0 Running ready=True
  +7.54s  CANARY h3-distribute-sharded back to 1 Ready replica(s)
```

### single / operator

Killed `pod/operator-6c77c7fcd5-rhsh7`.

Operator leader: `operator-6c77c7fcd5-rhsh7` → `operator-6c77c7fcd5-6n9qd`.

Control-plane reconcile: 16.6s (canary `h3-distribute-sharded-6cb7c8b64c-f8fc77b5d`).

| Endpoint | Baseline ok | First failure | Recovered | Failed requests | After recovery | Failure statuses | Slowest failure |
|---|---|---|---|---|---|---|---|
| ingest | 75/75 | — | none | 0 | 0 | — | 0ms |
| distribute | 76/76 | — | none | 0 | 0 | — | 0ms |

Data: 308 points acknowledged, 0 lost.

Placement before kill:

```
h3-distribute-657bb85f7d-5fd59cdb78           host=superb-beast-1997  pod=hostgroup-h3-6578bb8b8c-rcbnr
h3-ingest-685d688dc4-68bc5f775                host=superb-beast-1997  pod=hostgroup-h3-6578bb8b8c-rcbnr
```
Placement after recovery:

```
h3-distribute-657bb85f7d-5fd59cdb78           host=superb-beast-1997  pod=hostgroup-h3-6578bb8b8c-rcbnr
h3-ingest-685d688dc4-68bc5f775                host=superb-beast-1997  pod=hostgroup-h3-6578bb8b8c-rcbnr
```
Timeline:

```
  +0.00s  KILL pod/operator-6c77c7fcd5-rhsh7
  +0.22s  CANARY delete workload/h3-distribute-sharded-6cb7c8b64c-f8fc77b5d
  +0.30s  pod/operator-6c77c7fcd5-6n9qd Pending ready=False
  +0.30s  pod/operator-6c77c7fcd5-rhsh7 gone
  +1.05s  pod/operator-6c77c7fcd5-6n9qd Running ready=False
 +11.96s  pod/operator-6c77c7fcd5-6n9qd Running ready=True
 +15.83s  lease/d34db3ef.cosmonic.io holder=operator-6c77c7fcd5-6n9qd
 +16.55s  CANARY h3-distribute-sharded back to 1 Ready replica(s)
```

### ha / host

Killed `pod/hostgroup-h3-6578bb8b8c-rcbnr`.

Operator leader: `operator-6c77c7fcd5-6n9qd` unchanged.

| Endpoint | Baseline ok | First failure | Recovered | Failed requests | After recovery | Failure statuses | Slowest failure |
|---|---|---|---|---|---|---|---|
| ingest | 76/76 | +0.1s | 0.2s | 1 | 0 | 500×1 | 15ms |
| distribute | 76/76 | +0.2s | 2.2s | 1 | 0 | ERR:timeout×1 | 2002ms |

Data: 243 points acknowledged, 0 lost.

Placement before kill:

```
h3-distribute-657bb85f7d-5fd59cdb78           host=superb-beast-1997  pod=hostgroup-h3-6578bb8b8c-rcbnr
h3-distribute-657bb85f7d-6c6d86f6b8           host=rustic-account-9845  pod=hostgroup-h3-6578bb8b8c-txcf5
h3-ingest-685d688dc4-64468bf86                host=rustic-account-9845  pod=hostgroup-h3-6578bb8b8c-txcf5
h3-ingest-685d688dc4-65f54898d7               host=superb-beast-1997  pod=hostgroup-h3-6578bb8b8c-rcbnr
```
Placement after recovery:

```
h3-distribute-657bb85f7d-6c6d86f6b8           host=rustic-account-9845  pod=hostgroup-h3-6578bb8b8c-txcf5
h3-distribute-657bb85f7d-79457c4c7d           host=rustic-account-9845  pod=hostgroup-h3-6578bb8b8c-txcf5
h3-ingest-685d688dc4-64468bf86                host=rustic-account-9845  pod=hostgroup-h3-6578bb8b8c-txcf5
h3-ingest-685d688dc4-75c46649b4               host=rustic-account-9845  pod=hostgroup-h3-6578bb8b8c-txcf5
```
Timeline:

```
  +0.00s  KILL pod/hostgroup-h3-6578bb8b8c-rcbnr
  +0.31s  host/superb-beast-1997 gone
  +0.31s  pod/hostgroup-h3-6578bb8b8c-dnw2d Pending ready=False
  +0.31s  pod/hostgroup-h3-6578bb8b8c-rcbnr gone
  +0.31s  wd/h3-distribute ready=False replicas=1/2
  +0.31s  wd/h3-ingest ready=False replicas=1/2
  +1.27s  host/stimulating-eye-4789 ready=False
  +2.16s  host/stimulating-eye-4789 ready=True
  +2.16s  pod/hostgroup-h3-6578bb8b8c-dnw2d Running ready=False
  +2.16s  wd/h3-distribute ready=True replicas=2/2
  +2.16s  wd/h3-ingest ready=True replicas=2/2
 +13.15s  pod/hostgroup-h3-6578bb8b8c-dnw2d Running ready=True
```

### ha / envoy

Killed `pod/envoy-6d556d6d56-hm5nh`.

Operator leader: `operator-6c77c7fcd5-6n9qd` unchanged.

Control-plane reconcile: 2.1s (canary `h3-distribute-sharded-6cb7c8b64c-77bfdc6948`).

| Endpoint | Baseline ok | First failure | Recovered | Failed requests | After recovery | Failure statuses | Slowest failure |
|---|---|---|---|---|---|---|---|
| ingest | 76/76 | — | none | 0 | 0 | — | 0ms |
| distribute | 76/76 | — | none | 0 | 0 | — | 0ms |

Data: 238 points acknowledged, 0 lost.

Placement before kill:

```
h3-distribute-657bb85f7d-6c6d86f6b8           host=rustic-account-9845  pod=hostgroup-h3-6578bb8b8c-txcf5
h3-distribute-657bb85f7d-7cffbf9b6b           host=stimulating-eye-4789  pod=hostgroup-h3-6578bb8b8c-dnw2d
h3-ingest-685d688dc4-64468bf86                host=rustic-account-9845  pod=hostgroup-h3-6578bb8b8c-txcf5
h3-ingest-685d688dc4-cc45bcdb8                host=stimulating-eye-4789  pod=hostgroup-h3-6578bb8b8c-dnw2d
```
Placement after recovery:

```
h3-distribute-657bb85f7d-6c6d86f6b8           host=rustic-account-9845  pod=hostgroup-h3-6578bb8b8c-txcf5
h3-distribute-657bb85f7d-7cffbf9b6b           host=stimulating-eye-4789  pod=hostgroup-h3-6578bb8b8c-dnw2d
h3-ingest-685d688dc4-64468bf86                host=rustic-account-9845  pod=hostgroup-h3-6578bb8b8c-txcf5
h3-ingest-685d688dc4-cc45bcdb8                host=stimulating-eye-4789  pod=hostgroup-h3-6578bb8b8c-dnw2d
```
Timeline:

```
  +0.00s  KILL pod/envoy-6d556d6d56-hm5nh
  +0.21s  CANARY delete workload/h3-distribute-sharded-6cb7c8b64c-77bfdc6948
  +0.49s  pod/envoy-6d556d6d56-6hhbk Pending ready=False
  +0.49s  pod/envoy-6d556d6d56-hm5nh gone
  +1.80s  pod/envoy-6d556d6d56-6hhbk Running ready=False
  +2.12s  CANARY h3-distribute-sharded back to 1 Ready replica(s)
 +12.75s  pod/envoy-6d556d6d56-6hhbk Running ready=True
```

### ha / nexus

Killed `pod/nexus-0`.

Operator leader: `operator-6c77c7fcd5-6n9qd` unchanged.

Control-plane reconcile: 0.8s (canary `h3-distribute-sharded-6cb7c8b64c-547769748`).

| Endpoint | Baseline ok | First failure | Recovered | Failed requests | After recovery | Failure statuses | Slowest failure |
|---|---|---|---|---|---|---|---|
| ingest | 76/76 | — | none | 0 | 0 | — | 0ms |
| distribute | 76/76 | — | none | 0 | 0 | — | 0ms |

Data: 233 points acknowledged, 0 lost.

Placement before kill:

```
h3-distribute-657bb85f7d-6c6d86f6b8           host=rustic-account-9845  pod=hostgroup-h3-6578bb8b8c-txcf5
h3-distribute-657bb85f7d-7cffbf9b6b           host=stimulating-eye-4789  pod=hostgroup-h3-6578bb8b8c-dnw2d
h3-ingest-685d688dc4-64468bf86                host=rustic-account-9845  pod=hostgroup-h3-6578bb8b8c-txcf5
h3-ingest-685d688dc4-cc45bcdb8                host=stimulating-eye-4789  pod=hostgroup-h3-6578bb8b8c-dnw2d
```
Placement after recovery:

```
h3-distribute-657bb85f7d-6c6d86f6b8           host=rustic-account-9845  pod=hostgroup-h3-6578bb8b8c-txcf5
h3-distribute-657bb85f7d-7cffbf9b6b           host=stimulating-eye-4789  pod=hostgroup-h3-6578bb8b8c-dnw2d
h3-ingest-685d688dc4-64468bf86                host=rustic-account-9845  pod=hostgroup-h3-6578bb8b8c-txcf5
h3-ingest-685d688dc4-cc45bcdb8                host=stimulating-eye-4789  pod=hostgroup-h3-6578bb8b8c-dnw2d
```
Timeline:

```
  +0.00s  KILL pod/nexus-0
  +0.11s  pod/nexus-0 Pending ready=False
  +0.21s  CANARY delete workload/h3-distribute-sharded-6cb7c8b64c-547769748
  +0.83s  CANARY h3-distribute-sharded back to 1 Ready replica(s)
  +1.63s  pod/nexus-0 Running ready=False
  +7.93s  pod/nexus-0 Running ready=True
```

### ha / operator

Killed `pod/operator-6c77c7fcd5-6n9qd`.

Operator leader: `operator-6c77c7fcd5-6n9qd` → `operator-6c77c7fcd5-l2lzl`.

Control-plane reconcile: 16.6s (canary `h3-distribute-sharded-6cb7c8b64c-77ffc8d899`).

| Endpoint | Baseline ok | First failure | Recovered | Failed requests | After recovery | Failure statuses | Slowest failure |
|---|---|---|---|---|---|---|---|
| ingest | 76/76 | — | none | 0 | 0 | — | 0ms |
| distribute | 76/76 | — | none | 0 | 0 | — | 0ms |

Data: 307 points acknowledged, 0 lost.

Placement before kill:

```
h3-distribute-657bb85f7d-6c6d86f6b8           host=rustic-account-9845  pod=hostgroup-h3-6578bb8b8c-txcf5
h3-distribute-657bb85f7d-7cffbf9b6b           host=stimulating-eye-4789  pod=hostgroup-h3-6578bb8b8c-dnw2d
h3-ingest-685d688dc4-64468bf86                host=rustic-account-9845  pod=hostgroup-h3-6578bb8b8c-txcf5
h3-ingest-685d688dc4-cc45bcdb8                host=stimulating-eye-4789  pod=hostgroup-h3-6578bb8b8c-dnw2d
```
Placement after recovery:

```
h3-distribute-657bb85f7d-6c6d86f6b8           host=rustic-account-9845  pod=hostgroup-h3-6578bb8b8c-txcf5
h3-distribute-657bb85f7d-7cffbf9b6b           host=stimulating-eye-4789  pod=hostgroup-h3-6578bb8b8c-dnw2d
h3-ingest-685d688dc4-64468bf86                host=rustic-account-9845  pod=hostgroup-h3-6578bb8b8c-txcf5
h3-ingest-685d688dc4-cc45bcdb8                host=stimulating-eye-4789  pod=hostgroup-h3-6578bb8b8c-dnw2d
```
Timeline:

```
  +0.00s  KILL pod/operator-6c77c7fcd5-6n9qd
  +0.20s  CANARY delete workload/h3-distribute-sharded-6cb7c8b64c-77ffc8d899
  +0.47s  pod/operator-6c77c7fcd5-6n9qd gone
  +0.47s  pod/operator-6c77c7fcd5-l2lzl Pending ready=False
  +2.02s  pod/operator-6c77c7fcd5-l2lzl Running ready=False
 +13.78s  pod/operator-6c77c7fcd5-l2lzl Running ready=True
 +16.14s  lease/d34db3ef.cosmonic.io holder=operator-6c77c7fcd5-l2lzl
 +16.55s  CANARY h3-distribute-sharded back to 1 Ready replica(s)
```

--------------------------------------------
The suite now scales Envoy, nexus and the operator alongside the hosts, and the full run has finished with every scenario run single-instance and then scaled up. Report: h3-load-test/failover/results/20261022-133541/report.md.

┌─────────────────┬────────────────────────────────────────────┬──────────────────────────────────────────────────────┐
│   Pod killed    │              Single (all ×1)               │   HA (2 hosts × 2 replicas · Envoy 2 · nexus 3 ·     │
│                 │                                            │                     operator 2)                      │
├─────────────────┼────────────────────────────────────────────┼──────────────────────────────────────────────────────┤
│ h3 host         │ 35.6s down                                 │ 1 failed request per endpoint, then none             │
├─────────────────┼────────────────────────────────────────────┼──────────────────────────────────────────────────────┤
│ Envoy           │ 12.8s down                                 │ no downtime                                          │
├─────────────────┼────────────────────────────────────────────┼──────────────────────────────────────────────────────┤
│ Nexus           │ no failed requests; control plane stalled  │ no failed requests; no control-plane stall (0.8s)    │
│                 │ 7.5s                                       │                                                      │
├─────────────────┼────────────────────────────────────────────┼──────────────────────────────────────────────────────┤
│ Operator        │ no failed requests; control plane stalled  │ no failed requests; still 16.6s                      │
│ (leader)        │ 16.6s                                      │                                                      │
└─────────────────┴────────────────────────────────────────────┴──────────────────────────────────────────────────────┘

No acknowledged data was lost in any scenario. "Control plane stalled" means the time until the operator could replace a workload again: right after each kill the suite deletes a replica of h3-distribute-sharded (which isn't probed) and times its replacement. A nexus or operator outage doesn't show up in request traffic, so this is the only way to see it. That workload's own endpoint drops briefly each time.

Scaled Envoy: with 2 replicas, killing one caused no failed requests. The chart adds the PodDisruptionBudget automatically once replicas > 1. The two failures in the HA hoeady in flight on the dying host; an earlier run