#!/usr/bin/env bash
#
# 04-delete-crds.sh  (teardown step 4 — formerly README step 3)
#
# Deletes every CustomResourceDefinition in the "runtime.wasmcloud.dev" and
# "control.cosmonic.io" API groups. Intended to be run by a Cluster Admin as
# the final teardown of the wasmCloud / Cosmonic Control API surface.
#
# WARNING: deleting a CRD cascades — Kubernetes garbage-collects every custom
# resource of that kind in every namespace. Run 02-delete-workloads.sh and
# 03-helm-uninstall.sh first so this step only removes empty definitions.
#
# FINALIZERS / HANGING DELETES: a `kubectl delete crd` can hang forever when
# custom resources of that kind still carry finalizers (e.g. Host objects) but
# the controller that would clear them has already been uninstalled. The CRD
# waits on its own cleanup finalizer until every instance is gone, and the
# instances never finish terminating. Run with --force to strip the finalizers
# off those stuck custom resources first (and off the CRD itself as a last
# resort), which lets the deletes complete. Only safe once the operator is gone
# — which it is at this step — because the finalizer logic cannot run anyway.
#
# Usage:
#   ./04-delete-crds.sh             # prompts to confirm
#   ./04-delete-crds.sh --yes       # skip the confirmation prompt
#   ./04-delete-crds.sh --dry-run   # print what would be deleted only
#   ./04-delete-crds.sh --force     # also strip finalizers from stuck CRs/CRDs
#
set -euo pipefail

# CRD object names are "<plural>.<group>", so match on the group suffix.
GROUP_REGEX='\.(runtime\.wasmcloud\.dev|control\.cosmonic\.io)$'

ASSUME_YES=false
DRY_RUN=false
FORCE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) ASSUME_YES=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --force) FORCE=true; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

confirm() {
  $ASSUME_YES && return 0
  read -r -p "$1 [y/N] " reply
  [[ "$reply" == "y" || "$reply" == "Y" ]]
}

# strip_cr_finalizers <crd> — clear finalizers on every custom resource of this
# CRD so terminating instances can be garbage-collected. Handles both namespaced
# and cluster-scoped CRDs (namespace is empty for the latter).
strip_cr_finalizers() {
  local crd="$1" pairs
  # Capture first (with || true) so a failing `get` — e.g. once the CRD is
  # mid-deletion and the resource type is gone — does not trip set -e/pipefail.
  pairs="$(kubectl get "$crd" -A \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}' \
    2>/dev/null || true)"
  [[ -z "$pairs" ]] && return 0
  printf '%s\n' "$pairs" | while IFS=$'\t' read -r ns name; do
    [[ -z "$name" ]] && continue
    if [[ -n "$ns" ]]; then
      echo "   - clearing finalizers: $crd $name (namespace: $ns)"
      kubectl patch "$crd" "$name" -n "$ns" --type=merge \
        -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
    else
      echo "   - clearing finalizers: $crd $name"
      kubectl patch "$crd" "$name" --type=merge \
        -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
    fi
  done
  return 0
}

# strip_crd_finalizers <crd> — last resort: clear the CRD object's own
# finalizers if it is still stuck Terminating after its instances are gone.
strip_crd_finalizers() {
  local crd="$1"
  if kubectl get crd "$crd" >/dev/null 2>&1; then
    echo "   - clearing finalizers on CRD object: $crd"
    kubectl patch crd "$crd" --type=merge \
      -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
  fi
}

# Newline-separated list of CRD names (kept as a string for bash 3.2 portability).
# `kubectl get crds -o name` prints "customresourcedefinition.apiextensions.k8s.io/<name>";
# strip everything up to the first slash (portable across GNU and BSD sed).
CRDS="$(kubectl get crds -o name 2>/dev/null \
  | sed 's#^[^/]*/##' \
  | grep -E "$GROUP_REGEX" || true)"

if [[ -z "$CRDS" ]]; then
  echo "No CRDs found in runtime.wasmcloud.dev or control.cosmonic.io — nothing to delete."
  exit 0
fi

echo "The following CRDs (and ALL their custom resources) will be deleted:"
printf '%s\n' "$CRDS" | sed 's/^/  - /'
$FORCE && echo "(--force: finalizers will be stripped from stuck custom resources)"
echo

if $DRY_RUN; then
  echo "(dry-run: not deleting)"
  exit 0
fi

if ! confirm "Proceed? This is irreversible."; then
  echo "Aborted."
  exit 1
fi

printf '%s\n' "$CRDS" | while read -r crd; do
  [[ -z "$crd" ]] && continue
  echo ">> $crd"
  if $FORCE; then
    # Clear CR finalizers first so the CRD's cascade delete can complete, and
    # start the CRD delete in the background so it does not block on the wait.
    strip_cr_finalizers "$crd"
    kubectl delete crd "$crd" --ignore-not-found --wait=false
    # Re-strip in case new instances surfaced, then force-clear the CRD object.
    strip_cr_finalizers "$crd"
    strip_crd_finalizers "$crd"
  else
    kubectl delete crd "$crd" --ignore-not-found
  fi
done

echo
echo "Done."
if ! $FORCE; then
  echo "If a delete hung on a finalizer, re-run with --force to clear it."
fi
