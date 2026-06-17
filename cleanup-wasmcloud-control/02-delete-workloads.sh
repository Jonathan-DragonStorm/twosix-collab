#!/usr/bin/env bash
#
# 02-delete-workloads.sh  (README step 2)
#
# Deletes every HTTPTrigger and WorkloadDeployment in the cluster. This is the
# destructive companion to 01-list-workloads.sh and operates on exactly the
# same set of resources.
#
# HTTPTriggers are deleted first: an HTTPTrigger owns its WorkloadDeployment,
# so removing the trigger both stops the operator from re-creating the
# WorkloadDeployment and (via owner references) garbage-collects it. Any
# orphaned WorkloadDeployments left behind are then deleted directly.
#
# Usage:
#   ./02-delete-workloads.sh             # all namespaces, prompts to confirm
#   ./02-delete-workloads.sh -n NS       # a single namespace
#   ./02-delete-workloads.sh --yes       # skip the confirmation prompt
#   ./02-delete-workloads.sh --dry-run   # print what would be deleted only
#
set -euo pipefail

# Note: do NOT name this GROUPS — that is a special bash variable (the user's
# group IDs) and assigning to it silently fails.
API_GROUPS=("runtime.wasmcloud.dev" "control.cosmonic.io")

NS_ARGS=(--all-namespaces)
ASSUME_YES=false
DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) NS_ARGS=(-n "$2"); shift 2 ;;
    -y|--yes) ASSUME_YES=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

resolve_resource() {
  local want="$1" g
  for g in "${API_GROUPS[@]}"; do
    kubectl api-resources --api-group="$g" --no-headers -o name 2>/dev/null \
      | grep -E "^${want}\." && return 0
  done
  return 0
}

confirm() {
  $ASSUME_YES && return 0
  read -r -p "$1 [y/N] " reply
  [[ "$reply" == "y" || "$reply" == "Y" ]]
}

# delete_all <resource> — delete every instance of a namespaced resource.
delete_all() {
  local res="$1"
  [[ -z "$res" ]] && return 0
  echo
  echo ">> $res"
  kubectl get "$res" "${NS_ARGS[@]}" 2>/dev/null || { echo "   (none)"; return 0; }
  if $DRY_RUN; then
    echo "   (dry-run: not deleting)"
    return 0
  fi
  kubectl delete "$res" "${NS_ARGS[@]}" --all --ignore-not-found
}

TRIGGER_RES="$(resolve_resource httptriggers | head -n1)"
WLD_RES="$(resolve_resource workloaddeployments | head -n1)"

if [[ -z "$TRIGGER_RES" && -z "$WLD_RES" ]]; then
  echo "No HTTPTrigger or WorkloadDeployment CRDs are installed — nothing to delete."
  exit 0
fi

echo "About to delete ALL of the following across ${NS_ARGS[*]}:"
[[ -n "$TRIGGER_RES" ]] && echo "  - $TRIGGER_RES"
[[ -n "$WLD_RES" ]]     && echo "  - $WLD_RES"
echo
if ! $DRY_RUN && ! confirm "Proceed?"; then
  echo "Aborted."
  exit 1
fi

# Triggers first so the operator stops reconciling, then orphan workloads.
delete_all "$TRIGGER_RES"
delete_all "$WLD_RES"

echo
echo "Done."
