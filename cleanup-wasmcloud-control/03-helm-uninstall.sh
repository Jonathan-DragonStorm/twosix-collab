#!/usr/bin/env bash
#
# 03-helm-uninstall.sh  (teardown step 3 — formerly README step 5)
#
# Finds and `helm uninstall`s every Helm release in the cluster that is a
# Cosmonic Control or wasmCloud release, across all namespaces. This covers:
#   * cosmonic-control-hostgroup
#   * cosmonic-control
#   * http-trigger
#   * runtime-operator            (the wasmCloud operator chart, e.g. 0.4.0+)
#   * any chart whose name contains "wasmcloud" or "cosmonic"
#
# A release matches if EITHER its chart name OR its release name matches the
# regex below — the wasmCloud operator ships as chart "runtime-operator" but is
# commonly installed under the release name "wasmcloud", so matching only the
# chart name would miss it. Matching is version-independent. `helm list -a` is
# used so releases in any status (failed/pending/etc.) are also caught.
#
# UNINSTALL ORDER MATTERS. The host pod carries a finalizer that the operator
# (the cosmonic-control or runtime-operator chart) must be running to clear. If
# the operator is removed first, the HostGroup release hangs on its finalizer.
# So releases are uninstalled in this order:
#   1. cosmonic-control-hostgroup       (host pods — finalizers cleared by operator)
#   2. http-trigger                     (triggers/workloads — removed before operator)
#   3. anything else matched
#   4. cosmonic-control / runtime-operator  (the operator itself) — always LAST
#
# Usage:
#   ./03-helm-uninstall.sh             # prompts to confirm
#   ./03-helm-uninstall.sh --yes       # skip the confirmation prompt
#   ./03-helm-uninstall.sh --dry-run   # print what would be uninstalled only
#
set -euo pipefail

# Matched against both the chart name and the release name.
# `helm list` reports chart as "<name>-<version>".
CHART_REGEX='(cosmonic-control(-hostgroup)?|http-trigger|runtime-operator|wadm|wasmcloud|cosmonic)'

ASSUME_YES=false
DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) ASSUME_YES=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

confirm() {
  $ASSUME_YES && return 0
  read -r -p "$1 [y/N] " reply
  [[ "$reply" == "y" || "$reply" == "Y" ]]
}

command -v helm >/dev/null 2>&1 || { echo "helm not found on PATH." >&2; exit 1; }

# Emit "chart<TAB>name<TAB>namespace" for every matching release (matching on
# chart OR release name). Prefer JSON via jq; fall back to helm's table output
# when jq is unavailable.
list_matches() {
  if command -v jq >/dev/null 2>&1; then
    helm list -A -a -o json 2>/dev/null \
      | jq -r --arg re "$CHART_REGEX" \
          '.[] | select((.chart | test($re)) or (.name | test($re))) | "\(.chart)\t\(.name)\t\(.namespace)"'
  else
    # Default `helm list` columns: NAME NAMESPACE REVISION UPDATED(x4) STATUS CHART APPVERSION
    # grep the whole line first so a match on the release name (col 1) also counts.
    helm list -A -a 2>/dev/null \
      | awk 'NR>1' \
      | grep -E "$CHART_REGEX" \
      | awk '{print $9"\t"$1"\t"$2}'
  fi
}

# priority_of <chart> -> lower numbers are uninstalled first.
priority_of() {
  case "$1" in
    *hostgroup*)          echo 0 ;;  # host pods — operator must still be up
    *http-trigger*)       echo 1 ;;  # triggers/workloads — remove before operator
    cosmonic-control-*)   echo 3 ;;  # Cosmonic Control operator — uninstall LAST
    runtime-operator*)    echo 3 ;;  # wasmCloud operator — uninstall LAST
    *)                    echo 2 ;;
  esac
}

RAW="$(list_matches || true)"   # lines: chart<TAB>name<TAB>namespace

if [[ -z "$RAW" ]]; then
  echo "No Cosmonic Control or wasmCloud Helm releases found — nothing to uninstall."
  exit 0
fi

# Prefix each release with its priority and sort, so the uninstall order is
# hostgroups -> http-triggers -> others -> operator. Kept as newline-separated
# "priority<TAB>name<TAB>namespace<TAB>chart" text for bash 3.2 portability.
SORTED="$(printf '%s\n' "$RAW" | while IFS=$'\t' read -r chart name ns; do
  [[ -z "$name" ]] && continue
  printf '%s\t%s\t%s\t%s\n' "$(priority_of "$chart")" "$name" "$ns" "$chart"
done | sort -n -k1,1)"

echo "The following Helm releases will be uninstalled (in this order):"
printf '%s\n' "$SORTED" | while IFS=$'\t' read -r _ name ns chart; do
  [[ -z "$name" ]] && continue
  printf '  - %s (chart: %s, namespace: %s)\n' "$name" "$chart" "$ns"
done
echo

if $DRY_RUN; then
  echo "(dry-run: not uninstalling)"
  exit 0
fi

if ! confirm "Proceed?"; then
  echo "Aborted."
  exit 1
fi

printf '%s\n' "$SORTED" | while IFS=$'\t' read -r _ name ns chart; do
  [[ -z "$name" ]] && continue
  echo ">> helm uninstall $name -n $ns   (chart: $chart)"
  helm uninstall "$name" -n "$ns" || echo "   (failed; continuing)"
done

echo
echo "Done."
