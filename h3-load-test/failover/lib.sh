#!/usr/bin/env bash
# Shared helpers for the failover scripts. Source, don't execute.

NAMESPACE="${NAMESPACE:-twosix-dev}"
HOSTGROUP_RELEASE="${HOSTGROUP_RELEASE:-hostgroup-h3}"
HOSTGROUP="${HOSTGROUP:-h3}"
HOSTGROUP_CHART="${HOSTGROUP_CHART:-oci://ghcr.io/cosmonic/cosmonic-control-hostgroup}"
# WorkloadDeployments under test: these are scaled with the hosts and probed.
WORKLOADS="${WORKLOADS:-h3-ingest h3-distribute}"
CONTROL_RELEASE="${CONTROL_RELEASE:-cosmonic-control}"
CONTROL_CHART="${CONTROL_CHART:-oci://ghcr.io/cosmonic/cosmonic-control}"
# Lease the operator replicas compete for (controller-runtime leader election).
OPERATOR_LEASE="${OPERATOR_LEASE:-d34db3ef.cosmonic.io}"

FAILOVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

k() { kubectl -n "$NAMESPACE" "$@"; }

# current_hosts -- replicaCount of the hostgroup Deployment.
current_hosts() { k get deploy "$HOSTGROUP_RELEASE" -o jsonpath='{.spec.replicas}'; }

# current_replicas WD -- spec.replicas of a WorkloadDeployment.
current_replicas() { k get workloaddeployment "$1" -o jsonpath='{.spec.replicas}'; }

# ready_hosts -- number of Ready Host CRs in the hostgroup.
ready_hosts() {
  k get hosts -l hostgroup="$HOSTGROUP" -o json |
    jq '[.items[] | select(.metadata.deletionTimestamp == null)
         | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length'
}

# total_hosts -- number of Host CRs in the hostgroup, ready or not.
total_hosts() { k get hosts -l hostgroup="$HOSTGROUP" -o json | jq '.items | length'; }

# ready_replicas WD -- status.replicas.ready of a WorkloadDeployment.
ready_replicas() { k get workloaddeployment "$1" -o jsonpath='{.status.replicas.ready}'; }

# wait_healthy HOSTS REPLICAS [TIMEOUT_S] -- block until exactly HOSTS hosts are
# registered and Ready, and every workload under test has REPLICAS ready.
wait_healthy() {
  local hosts=$1 replicas=$2 timeout=${3:-420} start=$SECONDS wd ok
  while (( SECONDS - start < timeout )); do
    ok=1
    [[ "$(ready_hosts)" == "$hosts" && "$(total_hosts)" == "$hosts" ]] || ok=0
    for wd in $WORKLOADS; do
      [[ "$(ready_replicas "$wd")" == "$replicas" && "$(placed_ready "$wd")" == "$replicas" ]] || ok=0
    done
    if (( ok )); then
      log "healthy: $hosts host(s), $replicas replica(s) of: $WORKLOADS ($(( SECONDS - start ))s)"
      return 0
    fi
    sleep 3
  done
  die "not healthy after ${timeout}s (hosts ready=$(ready_hosts)/$(total_hosts), want $hosts)"
}

# show_placement -- which host and pod each workload replica is on.
show_placement() {
  (cd "$FAILOVER_DIR" && python3 -c '
import sys, failover_probe as f
for w, h, p in f.placement(sys.argv[1:]):
    print(f"  {w:45s} host={h}  pod={p}")
' $WORKLOADS) >&2
}

# placed_ready WD -- number of live Workload replicas of WD that are on a host
# and Ready. (Workloads are named <WD>-<replicaset hash>-<hash>.)
placed_ready() {
  k get workloads -o json | jq --arg wd "$1" '[.items[]
    | select(.metadata.deletionTimestamp == null)
    | select(.metadata.name | test("^" + $wd + "-[0-9a-z]+-[0-9a-z]+$"))
    | select(.status.hostId != null)
    | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length'
}

# colocated_replica HOSTS -- print one workload replica that shares a host with
# a sibling while some other host has room (fewer distinct hosts than
# min(replicas, HOSTS)); print nothing when every workload is spread.
colocated_replica() {
  (cd "$FAILOVER_DIR" && python3 -c '
import sys, collections, failover_probe as f
nhosts = int(sys.argv[1])
by = collections.defaultdict(lambda: collections.defaultdict(list))
for w, h, _ in f.placement(sys.argv[2:]):
    by[w.rsplit("-", 2)[0]][h].append(w)
for wd, hosts in sorted(by.items()):
    replicas = sum(len(ws) for ws in hosts.values())
    if len(hosts) < min(replicas, nhosts):
        busiest = max(hosts.values(), key=len)
        print(sorted(busiest)[-1])
        break
' "$1" $WORKLOADS)
}

# spread_ok HOSTS -- true when no workload has replicas sharing a host that
# could be spread onto another one.
spread_ok() { [[ -z "$(colocated_replica "$1")" ]]; }

# rebalance HOSTS REPLICAS -- the operator places replicas on whatever hosts
# exist at the time and never moves them, so after a host failure (or scaling
# replicas before new hosts register) replicas pile onto the survivors.
# Delete one colocated replica at a time; its WorkloadReplicaSet recreates it
# and the scheduler re-places it -- not reliably on the emptier host, hence the
# retry loop. Its sibling keeps serving, so this does not interrupt traffic.
rebalance() {
  local hosts=$1 replicas=$2 w wd i start
  for i in $(seq 1 10); do
    w=$(colocated_replica "$hosts")
    [[ -z "$w" ]] && return 0
    wd=${w%-*-*}
    log "rebalancing: re-placing colocated replica $w"
    k delete workload "$w" --wait=true >/dev/null
    # The WorkloadDeployment's ready count lags; wait on the Workload objects
    # themselves so the sibling is never removed before its replacement serves.
    start=$SECONDS
    until [[ "$(placed_ready "$wd")" == "$replicas" ]]; do
      (( SECONDS - start < 180 )) || die "replacement for $w not Ready after 180s"
      sleep 2
    done
  done
  log "warning: replicas still colocated after 10 re-placements"
  return 1
}

# ---- control plane (Envoy, Nexus, operator)

current_envoy() { k get deploy envoy -o jsonpath='{.spec.replicas}'; }
current_nexus() { k get statefulset nexus -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 1; }
current_operator() { k get deploy operator -o jsonpath='{.spec.replicas}'; }

# deployed_chart_version RELEASE -- e.g. 0.14.0
deployed_chart_version() {
  helm -n "$NAMESPACE" list -f "^$1\$" -o json | jq -r '.[0].chart' | sed 's/.*-//'
}

# ensure_operator_plugin -- install the operator-replicas post-renderer (the
# 0.14 chart hard-codes the operator Deployment to replicas: 1).
ensure_operator_plugin() {
  helm plugin list 2>/dev/null | grep -q '^operator-replicas' && return 0
  log "installing helm post-renderer plugin operator-replicas"
  helm plugin install "$FAILOVER_DIR/helm-plugins/operator-replicas" --verify=false >/dev/null
}

# operator_leader -- pod name holding the operator's leader-election lease.
operator_leader() { k get lease "$OPERATOR_LEASE" -o jsonpath='{.spec.holderIdentity}' | cut -d_ -f1; }

# nexus_meta_leader_ok N -- with N > 1, every nexus pod has logged a JetStream
# metadata leader since it started; trivially true for a single node.
nexus_meta_leader_ok() {
  (( $1 > 1 )) || return 0
  local i
  for (( i = 0; i < $1; i++ )); do
    k logs "nexus-$i" 2>/dev/null | grep -qE 'new metadata leader|Self is new JetStream cluster metadata leader' || return 1
  done
}

# wait_control ENVOY NEXUS OPERATOR [TIMEOUT_S] -- block until each control
# plane component has that many Ready pods, the nexus cluster has a JetStream
# metadata leader, and a live operator pod holds the leader lease.
wait_control() {
  local envoy=$1 nexus=$2 operator=$3 timeout=${4:-420} start=$SECONDS leader
  while (( SECONDS - start < timeout )); do
    leader=$(operator_leader)
    if [[ "$(k get deploy envoy -o jsonpath='{.status.readyReplicas}')" == "$envoy" &&
          "$(k get statefulset nexus -o jsonpath='{.status.readyReplicas}')" == "$nexus" &&
          "$(k get deploy operator -o jsonpath='{.status.readyReplicas}')" == "$operator" &&
          "$(k get pods -l cosmonic.io/name=envoy --no-headers 2>/dev/null | wc -l | tr -d ' ')" == "$envoy" &&
          "$(k get pods -l cosmonic.io/name=operator --no-headers 2>/dev/null | wc -l | tr -d ' ')" == "$operator" ]] &&
       [[ -n "$leader" ]] && k get pod "$leader" >/dev/null 2>&1 && nexus_meta_leader_ok "$nexus"; then
      log "control plane healthy: envoy=$envoy nexus=$nexus operator=$operator (leader $leader) ($(( SECONDS - start ))s)"
      return 0
    fi
    sleep 3
  done
  die "control plane not healthy after ${timeout}s (want envoy=$envoy nexus=$nexus operator=$operator)"
}

# scale_control ENVOY NEXUS OPERATOR -- one Helm upgrade of the control-plane
# release. Nexus always runs as a persistent StatefulSet (required for
# nexus.replicas > 1); the operator count goes through the post-renderer.
scale_control() {
  local envoy=$1 nexus=$2 operator=$3 old_nexus version i
  (( nexus % 2 == 1 )) || die "nexus replicas must be odd (1, 3, 5) for a JetStream quorum"
  old_nexus=$(current_nexus)
  if [[ "$(current_envoy)" == "$envoy" && "$old_nexus" == "$nexus" && "$(current_operator)" == "$operator" ]] &&
     k get statefulset nexus >/dev/null 2>&1; then
    log "control plane already at envoy=$envoy nexus=$nexus operator=$operator"
  else
    ensure_operator_plugin
    version=$(deployed_chart_version "$CONTROL_RELEASE")
    log "scaling control plane to envoy=$envoy nexus=$nexus operator=$operator (chart $version)"
    # --force-conflicts: a manual `kubectl scale` of the operator leaves kubectl
    # owning .spec.replicas, which otherwise fails every server-side-apply upgrade.
    helm upgrade "$CONTROL_RELEASE" "$CONTROL_CHART" --version "$version" -n "$NAMESPACE" --reuse-values \
      --set envoy.replicas="$envoy" --set nexus.replicas="$nexus" --set nexus.persistence.enabled=true \
      --post-renderer operator-replicas --post-renderer-args "$operator" \
      --force-conflicts --wait --timeout 10m >/dev/null
    if [[ "$old_nexus" != "$nexus" ]]; then
      # The cluster routes live in the nexus ConfigMap, which does not roll the
      # StatefulSet: restart so every node runs the new cluster config.
      log "restarting nexus so all $nexus node(s) pick up the cluster config"
      k rollout restart statefulset/nexus >/dev/null
      k rollout status statefulset/nexus --timeout=300s >/dev/null
      # Scale-down leaves the removed nodes' PVCs behind with stale cluster
      # state; drop them so a later scale-up starts clean.
      for (( i = nexus; i < 9; i++ )); do
        k get pvc "data-nexus-$i" >/dev/null 2>&1 && k delete pvc "data-nexus-$i" --wait=false >/dev/null && log "deleted pvc/data-nexus-$i"
      done
    fi
  fi
  wait_control "$envoy" "$nexus" "$operator"
}

# wait_endpoints [TIMEOUT_S] -- both probed endpoints answer 200.
wait_endpoints() {
  local timeout=${1:-120} start=$SECONDS h code ok
  while (( SECONDS - start < timeout )); do
    ok=1
    for h in "${INGEST_HOST:-h3-ingest.localhost.cosmonic.sh}" "${DISTRIBUTE_HOST:-h3-distribute.localhost.cosmonic.sh}"; do
      code=$(curl -s -o /dev/null -w '%{http_code}' -m 3 -H "Host: $h" "${BASE_URL:-http://127.0.0.1}/openapi.json" || true)
      [[ "$code" == 200 ]] || ok=0
    done
    (( ok )) && return 0
    sleep 2
  done
  die "endpoints not answering 200 after ${timeout}s"
}
