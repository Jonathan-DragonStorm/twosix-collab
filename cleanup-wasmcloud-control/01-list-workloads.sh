#!/usr/bin/env bash
#
# 01-list-workloads.sh  (README step 1)
#
# Read-only. Lists every WorkloadDeployment in the cluster and, where a
# WorkloadDeployment was created by an HTTPTrigger, the owning HTTPTrigger.
# Also lists any HTTPTriggers that have no WorkloadDeployment yet.
#
# Use this to manually verify what is still running on wasmCloud / Cosmonic
# Control before you delete anything with 02-delete-workloads.sh.
#
# Usage:
#   ./01-list-workloads.sh            # all namespaces
#   ./01-list-workloads.sh -n NS      # a single namespace
#
set -euo pipefail

# CRDs live in one of these two API groups.
# Note: do NOT name this GROUPS — that is a special bash variable (the user's
# group IDs) and assigning to it silently fails.
API_GROUPS=("runtime.wasmcloud.dev" "control.cosmonic.io")

NS_ARGS=(--all-namespaces)
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) NS_ARGS=(-n "$2"); shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# resolve_resource <plural> -> prints "plural.group" for the first API group
# that actually serves it, or nothing if the CRD is not installed.
resolve_resource() {
  local want="$1" g
  for g in "${API_GROUPS[@]}"; do
    kubectl api-resources --api-group="$g" --no-headers -o name 2>/dev/null \
      | grep -E "^${want}\." && return 0
  done
  return 0
}

WLD_RES="$(resolve_resource workloaddeployments | head -n1)"
TRIGGER_RES="$(resolve_resource httptriggers | head -n1)"

if [[ -z "$WLD_RES" && -z "$TRIGGER_RES" ]]; then
  echo "No WorkloadDeployment or HTTPTrigger CRDs are installed in this cluster."
  echo "Nothing to list — wasmCloud / Cosmonic Control CRDs are already gone."
  exit 0
fi

echo "=========================================================================="
echo " WorkloadDeployments"
echo "=========================================================================="
if [[ -n "$WLD_RES" ]]; then
  echo "Resource: $WLD_RES"
  echo
  # Default printer columns (NAME / REPLICAS / READY etc.).
  kubectl get "$WLD_RES" "${NS_ARGS[@]}" 2>/dev/null || true
  echo
  echo "-- Ownership (which HTTPTrigger, if any, created each WorkloadDeployment) --"
  kubectl get "$WLD_RES" "${NS_ARGS[@]}" \
    -o custom-columns=\
'NAMESPACE:.metadata.namespace,'\
'WORKLOADDEPLOYMENT:.metadata.name,'\
'OWNER_KIND:.metadata.ownerReferences[0].kind,'\
'OWNER_NAME:.metadata.ownerReferences[0].name' \
    2>/dev/null || true
else
  echo "WorkloadDeployment CRD is not installed."
fi

echo
echo "=========================================================================="
echo " HTTPTriggers"
echo "=========================================================================="
if [[ -n "$TRIGGER_RES" ]]; then
  echo "Resource: $TRIGGER_RES"
  echo
  kubectl get "$TRIGGER_RES" "${NS_ARGS[@]}" 2>/dev/null || true
else
  echo "HTTPTrigger CRD is not installed."
fi
