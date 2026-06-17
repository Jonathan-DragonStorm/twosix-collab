#!/usr/bin/env bash
#
# 06-verify-clean.sh  (teardown step 6 — verification)
#
# Read-only. Confirms the cluster is clean of wasmCloud and Cosmonic Control by
# checking that NONE of the following remain:
#   * CRDs in the runtime.wasmcloud.dev or control.cosmonic.io API groups
#     (and any leftover custom resources, if a CRD somehow still exists)
#   * ClusterRoles / ClusterRoleBindings matching wasmCloud / Cosmonic Control
#   * Roles / RoleBindings (namespaced) matching wasmCloud / Cosmonic Control
#   * Helm releases for any Cosmonic Control / wasmCloud chart
#
# Exit code is 0 when the cluster is clean, 1 when any residue is found, so it
# can gate automation. Run it after steps 1-5.
#
# Usage:
#   ./06-verify-clean.sh
#
set -euo pipefail

# Note: do NOT name this GROUPS — that is a special bash variable (the user's
# group IDs) and assigning to it silently fails.
API_GROUPS=("runtime.wasmcloud.dev" "control.cosmonic.io")
GROUP_REGEX='\.(runtime\.wasmcloud\.dev|control\.cosmonic\.io)$'
CHART_REGEX='(cosmonic-control(-hostgroup)?|http-trigger|runtime-operator|wadm|wasmcloud|cosmonic)'
LABEL_SELECTORS=(
  "app.kubernetes.io/part-of=cosmonic-control"
  "app.kubernetes.io/part-of=wasmcloud"
  "app.kubernetes.io/name=cosmonic-control"
  "app.kubernetes.io/name=cosmonic-control-hostgroup"
)
NAME_REGEX='^(cosmonic|wasmcloud|runtime-operator|cosmonic-control|hostgroup|nexus)([-.]|$)'

case "${1:-}" in
  -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

DIRTY=0

# nlines <string> -> number of non-empty lines.
nlines() {
  if [[ -z "$1" ]]; then echo 0; else printf '%s\n' "$1" | grep -c . || true; fi
}

# report <label> <newline-separated-list>
report() {
  local label="$1" list="$2" count
  count="$(nlines "$list")"
  if [[ "$count" -eq 0 ]]; then
    printf '  [ OK ] %s: none\n' "$label"
  else
    DIRTY=1
    printf '  [FAIL] %s: %s found\n' "$label" "$count"
    printf '%s\n' "$list" | sed 's/^/           - /'
  fi
}

collect_cluster_matches() {
  local kind="$1" sel
  {
    for sel in "${LABEL_SELECTORS[@]}"; do
      kubectl get "$kind" -l "$sel" -o name 2>/dev/null || true
    done
    kubectl get "$kind" -o name 2>/dev/null \
      | sed "s#^${kind}/##; s#^${kind}\.[^/]*/##" \
      | grep -E "$NAME_REGEX" || true
  } | sed "s#^${kind}/##; s#^${kind}\.[^/]*/##" | sort -u
}

collect_ns_matches() {  # prints "name (namespace: ns)" per match
  local kind="$1" sel
  local jp='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}'
  {
    for sel in "${LABEL_SELECTORS[@]}"; do
      kubectl get "$kind" -A -l "$sel" -o jsonpath="$jp" 2>/dev/null || true
    done
    kubectl get "$kind" -A -o jsonpath="$jp" 2>/dev/null \
      | awk -F'\t' -v re="$NAME_REGEX" 'NF==2 && $2 ~ re { print }' || true
  } | sed '/^[[:space:]]*$/d' | sort -u \
    | awk -F'\t' '{ printf "%s (namespace: %s)\n", $2, $1 }'
}

echo "Verifying cluster is clean of wasmCloud and Cosmonic Control..."
echo

# 1. CRDs
CRDS="$(kubectl get crds -o name 2>/dev/null \
  | sed 's#^[^/]*/##' \
  | grep -E "$GROUP_REGEX" || true)"
report "CRDs (runtime.wasmcloud.dev / control.cosmonic.io)" "$CRDS"

# 1b. Leftover custom resources — only meaningful if a CRD still exists.
if [[ -n "$CRDS" ]]; then
  for res in workloaddeployments httptriggers; do
    for g in "${API_GROUPS[@]}"; do
      fq="$(kubectl api-resources --api-group="$g" --no-headers -o name 2>/dev/null \
            | grep -E "^${res}\." | head -n1 || true)"
      [[ -z "$fq" ]] && continue
      INST="$(kubectl get "$fq" -A -o name 2>/dev/null || true)"
      report "Custom resources ($fq)" "$INST"
    done
  done
fi

# 2. Cluster RBAC
report "ClusterRoles"        "$(collect_cluster_matches clusterrole || true)"
report "ClusterRoleBindings" "$(collect_cluster_matches clusterrolebinding || true)"

# 3. Namespaced RBAC
report "Roles (namespaced)"        "$(collect_ns_matches role || true)"
report "RoleBindings (namespaced)" "$(collect_ns_matches rolebinding || true)"

# 4. Helm releases (match on chart OR release name; -a catches any status)
if command -v helm >/dev/null 2>&1; then
  if command -v jq >/dev/null 2>&1; then
    RELEASES="$(helm list -A -a -o json 2>/dev/null \
      | jq -r --arg re "$CHART_REGEX" \
          '.[] | select((.chart | test($re)) or (.name | test($re))) | "\(.name) (ns: \(.namespace), chart: \(.chart))"' || true)"
  else
    RELEASES="$(helm list -A -a 2>/dev/null | awk 'NR>1' | grep -E "$CHART_REGEX" | awk '{print $1" (ns: "$2", chart: "$9")"}' || true)"
  fi
  report "Helm releases" "$RELEASES"
else
  echo "  [WARN] helm not found on PATH — skipped Helm release check."
fi

echo
if [[ "$DIRTY" -eq 0 ]]; then
  echo "RESULT: CLEAN — no wasmCloud or Cosmonic Control resources remain."
  exit 0
else
  echo "RESULT: NOT CLEAN — residue found above. Re-run the relevant cleanup step(s)."
  exit 1
fi
