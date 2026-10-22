#!/usr/bin/env bash
# run_suite.sh -- run every failover scenario under every scale profile and
# write a combined report. See README.md.
#
#   ./run_suite.sh                                   # single, then ha
#   PROFILES=single SCENARIOS="nexus operator" ./run_suite.sh
#   HA_HOSTS=3 HA_REPLICAS=3 HA_ENVOY=3 ./run_suite.sh
#   PROFILE_envoyha="envoy=2" PROFILES="single envoyha" SCENARIOS=envoy ./run_suite.sh
#
# A profile fixes five counts: h3 host pods, replicas of each probed workload,
# Envoy pods, Nexus nodes and operator pods. Everything in place before the run
# is restored on exit (RESTORE=0 leaves the last profile in place).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

PROFILES="${PROFILES:-single ha}"
HA_HOSTS="${HA_HOSTS:-2}"
HA_REPLICAS="${HA_REPLICAS:-$HA_HOSTS}"
HA_ENVOY="${HA_ENVOY:-2}"
HA_NEXUS="${HA_NEXUS:-3}"
HA_OPERATOR="${HA_OPERATOR:-2}"
SCENARIOS="${SCENARIOS:-host envoy nexus operator}"
# Unprobed workload the control-plane scenarios delete a replica of, to time
# how long the control plane takes to act again. Empty disables the canary.
CANARY="${CANARY-h3-distribute-sharded}"
PROBE_ARGS="${PROBE_ARGS:-}"          # extra failover_probe.py flags, e.g. "--baseline 30"
PAUSE="${PAUSE:-10}"                  # seconds of quiet between scenarios
RESTORE="${RESTORE:-1}"
OUT="${OUT:-$FAILOVER_DIR/results/$(date +%Y%m%d-%H%M%S)}"
PROBE_DATE="${PROBE_DATE:-$(date -u +%Y.%m.%d)}"
BASE_URL="${BASE_URL:-http://127.0.0.1}"
INGEST_HOST="${INGEST_HOST:-h3-ingest.localhost.cosmonic.sh}"
DISTRIBUTE_HOST="${DISTRIBUTE_HOST:-h3-distribute.localhost.cosmonic.sh}"
export NAMESPACE BASE_URL INGEST_HOST DISTRIBUTE_HOST

# profile_scale NAME -- prints "HOSTS REPLICAS ENVOY NEXUS OPERATOR".
profile_scale() {
  local spec kv key val hosts=1 replicas="" envoy=1 nexus=1 operator=1
  case $1 in
    single) echo "1 1 1 1 1"; return ;;
    ha) echo "$HA_HOSTS $HA_REPLICAS $HA_ENVOY $HA_NEXUS $HA_OPERATOR"; return ;;
    [0-9]*x[0-9]*) echo "${1%x*} ${1#*x} 1 1 1"; return ;;
  esac
  spec_var="PROFILE_$1"
  spec=${!spec_var:-}
  [[ -n "$spec" ]] || die "unknown profile '$1' (single, ha, HOSTSxREPLICAS, or define PROFILE_$1=\"hosts=2,envoy=2,...\")"
  IFS=, read -ra kv <<<"$spec"
  for pair in "${kv[@]}"; do
    key=${pair%%=*} val=${pair#*=}
    case $key in
      hosts) hosts=$val ;; replicas) replicas=$val ;; envoy) envoy=$val ;;
      nexus) nexus=$val ;; operator) operator=$val ;;
      *) die "PROFILE_$1: unknown key '$key' (hosts, replicas, envoy, nexus, operator)" ;;
    esac
  done
  echo "$hosts ${replicas:-$hosts} $envoy $nexus $operator"
}

# scenario_args NAME -- failover_probe.py flags selecting what to kill.
scenario_args() {
  local first_wd=${WORKLOADS%% *} canary=""
  [[ -n "$CANARY" ]] && canary="--canary $CANARY"
  case $1 in
    host) echo "--kill-workload-host $first_wd --watch-prefix $HOSTGROUP_RELEASE" ;;
    envoy) echo "--kill-selector cosmonic.io/name=envoy --watch-prefix envoy- $canary" ;;
    nexus) echo "--kill-selector cosmonic.io/name=nexus --watch-prefix nexus- $HOSTGROUP_RELEASE $canary" ;;
    operator) echo "--kill-lease $OPERATOR_LEASE --watch-prefix operator- $canary" ;;
    *) die "unknown scenario '$1' (host, envoy, nexus, operator)" ;;
  esac
}

delete_probe_points() {
  curl -s -o /dev/null -X DELETE -H "Host: $INGEST_HOST" "$BASE_URL/points?timestamp=$1" || true
}

# ---- preflight
for bin in kubectl helm jq python3 curl; do command -v $bin >/dev/null || die "$bin not found"; done
for p in $PROFILES; do
  read -r h r e n o <<<"$(profile_scale "$p")"
  (( n % 2 == 1 )) || die "profile $p: nexus must be odd (1, 3, 5)"
done
for s in $SCENARIOS; do scenario_args "$s" >/dev/null; done
[[ -z "$CANARY" ]] || k get workloaddeployment "$CANARY" >/dev/null || die "canary workloaddeployment/$CANARY not found (set CANARY= to disable)"
wait_endpoints 30
mkdir -p "$OUT"
exec > >(tee -a "$OUT/suite.log") 2>&1

orig="--hosts $(current_hosts) --replicas $(current_replicas "${WORKLOADS%% *}") --envoy $(current_envoy) --nexus $(current_nexus) --operator $(current_operator)"
restore() {
  if [[ "$RESTORE" == 1 ]]; then
    log "restoring original scale: $orig"
    # shellcheck disable=SC2086
    "$FAILOVER_DIR/scale.sh" $orig || log "restore failed -- rerun ./scale.sh $orig"
  fi
}
trap restore EXIT

# Record what was tested so the report is self-describing.
profiles_json=$(for p in $PROFILES; do
  read -r h r e n o <<<"$(profile_scale "$p")"
  jq -n --arg p "$p" --argjson h "$h" --argjson r "$r" --argjson e "$e" --argjson n "$n" --argjson o "$o" \
    '{($p): {hosts: $h, replicas: $r, envoy: $e, nexus: $n, operator: $o}}'
done | jq -s 'add')
jq -n \
  --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg namespace "$NAMESPACE" \
  --arg context "$(kubectl config current-context)" \
  --arg k8s "$(kubectl version -o json | jq -r .serverVersion.gitVersion)" \
  --argjson charts "$(helm -n "$NAMESPACE" list -o json | jq 'map({(.name): .chart}) | add')" \
  --arg host_version "$(k get hosts -l hostgroup="$HOSTGROUP" -o jsonpath='{.items[0].status.version}')" \
  --argjson profiles "$profiles_json" \
  --arg scenarios "$SCENARIOS" --arg workloads "$WORKLOADS" --arg canary "$CANARY" --arg probe_args "$PROBE_ARGS" \
  '{started: $started, namespace: $namespace, context: $context, kubernetes: $k8s, charts: $charts,
    host_version: $host_version, profiles: $profiles, scenarios: ($scenarios | split(" ")),
    workloads: ($workloads | split(" ")), canary: $canary, probe_args: $probe_args}' > "$OUT/environment.json"
log "results -> $OUT"

# ---- run
idx=0
for profile in $PROFILES; do
  read -r hosts replicas envoy nexus operator <<<"$(profile_scale "$profile")"
  log "=== profile $profile: hosts=$hosts replicas=$replicas envoy=$envoy nexus=$nexus operator=$operator ==="
  "$FAILOVER_DIR/scale.sh" --envoy "$envoy" --nexus "$nexus" --operator "$operator" --hosts "$hosts" --replicas "$replicas"
  for scenario in $SCENARIOS; do
    (( idx < 20 )) || die "too many profile x scenario runs for the probe timestamp scheme (max 20)"
    ts="$PROBE_DATE.23.$(printf %02d $(( 40 + idx )))"
    idx=$(( idx + 1 ))
    delete_probe_points "$ts"
    # A previous host kill leaves the surviving replicas on one host; spread
    # them again so every scenario starts from the same placement.
    rebalance "$hosts" "$replicas" || true
    log "--- $profile/$scenario (probe timestamp $ts)"
    # shellcheck disable=SC2046,SC2086
    python3 "$FAILOVER_DIR/failover_probe.py" --profile "$profile" --scenario "$scenario" \
      $(scenario_args "$scenario") --workloads $WORKLOADS --timestamp "$ts" --out "$OUT" $PROBE_ARGS
    wait_control "$envoy" "$nexus" "$operator"
    wait_healthy "$hosts" "$replicas"
    [[ -z "$CANARY" ]] || until [[ "$(placed_ready "$CANARY")" == "$(current_replicas "$CANARY")" ]]; do sleep 2; done
    wait_endpoints
    delete_probe_points "$ts"
    sleep "$PAUSE"
  done
done

python3 "$FAILOVER_DIR/report.py" "$OUT"
log "report: $OUT/report.md"
