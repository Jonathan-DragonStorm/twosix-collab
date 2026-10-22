#!/usr/bin/env bash
# scale.sh -- scale the h3 data plane and the Cosmonic Control plane, then wait
# until everything is Ready and print where each workload replica landed.
#
#   ./scale.sh --hosts 2 --replicas 2 --envoy 2 --nexus 3 --operator 2
#   ./scale.sh --envoy 1 --nexus 1 --operator 1     # control plane only
#   ./scale.sh 2 2                                   # HOSTS [REPLICAS] (data plane only)
#
# Only the dimensions given are changed. Data plane: hostgroup-h3 pods through
# Helm (replicaCount) and each workload in $WORKLOADS through the
# WorkloadDeployment scale subresource, followed by a rebalance so replicas sit
# on distinct hosts. Control plane: one Helm upgrade of cosmonic-control
# (envoy.replicas, nexus.replicas with persistence, operator replicas via the
# operator-replicas post-renderer) -- see README.md for why each is done that way.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

hosts="" replicas="" envoy="" nexus="" operator=""
while (( $# )); do
  case $1 in
    --hosts) hosts=$2; shift 2 ;;
    --replicas) replicas=$2; shift 2 ;;
    --envoy) envoy=$2; shift 2 ;;
    --nexus) nexus=$2; shift 2 ;;
    --operator) operator=$2; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    [0-9]*) if [[ -z "$hosts" ]]; then hosts=$1; else replicas=$1; fi; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ -n "$hosts$replicas$envoy$nexus$operator" ]] || die "nothing to scale (see --help)"
for v in "$hosts" "$replicas" "$envoy" "$nexus" "$operator"; do
  [[ -z "$v" ]] || (( v >= 1 )) || die "counts must be >= 1"
done

# ---- control plane
if [[ -n "$envoy$nexus$operator" ]]; then
  scale_control "${envoy:-$(current_envoy)}" "${nexus:-$(current_nexus)}" "${operator:-$(current_operator)}"
fi

# ---- data plane
if [[ -n "$hosts$replicas" ]]; then
  hosts=${hosts:-$(current_hosts)}
  replicas=${replicas:-$hosts}
  (( replicas <= hosts )) || log "warning: $replicas replicas on $hosts host(s) -- some replicas will share a host"

  if [[ "$(current_hosts)" != "$hosts" ]]; then
    version=$(deployed_chart_version "$HOSTGROUP_RELEASE")
    log "scaling $HOSTGROUP_RELEASE to $hosts host pod(s) (chart $version)"
    helm upgrade "$HOSTGROUP_RELEASE" "$HOSTGROUP_CHART" --version "$version" -n "$NAMESPACE" \
      --reuse-values --set replicaCount="$hosts" --wait --timeout 10m >/dev/null
  else
    log "$HOSTGROUP_RELEASE already at $hosts host pod(s)"
  fi

  # Helm --wait only covers pod readiness; wait for every host to register with
  # the operator too, or new replicas are placed on the hosts that already have.
  start=$SECONDS
  until [[ "$(ready_hosts)" == "$hosts" && "$(total_hosts)" == "$hosts" ]]; do
    (( SECONDS - start < 420 )) || die "hosts not registered after 420s ($(ready_hosts)/$(total_hosts) ready, want $hosts)"
    sleep 3
  done

  for wd in $WORKLOADS; do
    if [[ "$(current_replicas "$wd")" != "$replicas" ]]; then
      log "scaling workloaddeployment/$wd to $replicas replica(s)"
      k scale workloaddeployment "$wd" --replicas="$replicas" >/dev/null
    fi
  done

  wait_healthy "$hosts" "$replicas"
  rebalance "$hosts" "$replicas" || true
  log "placement:"
  show_placement
fi

wait_endpoints
log "endpoints answering 200"
