#!/usr/bin/env bash
#
# 05-delete-rbac.sh  (teardown step 5 — formerly README step 4)
#
# Deletes RBAC that was installed by wasmCloud or Cosmonic Control, whether
# applied manually or by a Helm chart:
#   * cluster-scoped:  ClusterRoles and ClusterRoleBindings
#   * namespaced:      Roles and RoleBindings (in every namespace)
#
# `helm uninstall` (03-helm-uninstall.sh) normally removes the namespaced
# Roles/RoleBindings it created, but this script also sweeps them up in case
# they were applied by hand or orphaned by a failed/partial uninstall.
#
# Objects are selected if EITHER of these is true:
#   * a Helm/Kubernetes label marks them as part of cosmonic-control / wasmcloud
#   * their name matches a known wasmCloud / Cosmonic Control prefix
# Every match is printed for review before anything is deleted.
#
# Usage:
#   ./05-delete-rbac.sh             # prompts to confirm
#   ./05-delete-rbac.sh --yes       # skip the confirmation prompt
#   ./05-delete-rbac.sh --dry-run   # print what would be deleted only
#
set -euo pipefail

# Label selectors that identify chart-installed objects.
LABEL_SELECTORS=(
  "app.kubernetes.io/part-of=cosmonic-control"
  "app.kubernetes.io/part-of=wasmcloud"
  "app.kubernetes.io/name=cosmonic-control"
  "app.kubernetes.io/name=cosmonic-control-hostgroup"
)
# Name patterns that identify manually-applied or Helm objects.
NAME_REGEX='^(cosmonic|wasmcloud|runtime-operator|cosmonic-control|hostgroup|nexus)([-.]|$)'

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

# collect_cluster_matches <kind> -> newline-separated names of matching
# cluster-scoped objects.
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

# collect_ns_matches <kind> -> newline-separated "namespace<TAB>name" of
# matching namespaced objects across all namespaces.
collect_ns_matches() {
  local kind="$1" sel
  local jp='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}'
  {
    for sel in "${LABEL_SELECTORS[@]}"; do
      kubectl get "$kind" -A -l "$sel" -o jsonpath="$jp" 2>/dev/null || true
    done
    kubectl get "$kind" -A -o jsonpath="$jp" 2>/dev/null \
      | awk -F'\t' -v re="$NAME_REGEX" 'NF==2 && $2 ~ re { print }' || true
  } | sed '/^[[:space:]]*$/d' | sort -u
}

print_list() {     # newline-separated names
  if [[ -z "$1" ]]; then echo "  - (none)"; else printf '%s\n' "$1" | sed 's/^/  - /'; fi
}
print_ns_list() {  # newline-separated "ns<TAB>name"
  if [[ -z "$1" ]]; then echo "  - (none)"; return; fi
  printf '%s\n' "$1" | while IFS=$'\t' read -r ns name; do
    [[ -z "$name" ]] && continue
    printf '  - %s (namespace: %s)\n' "$name" "$ns"
  done
}

CROLES="$(collect_cluster_matches clusterrole || true)"
CRBINDINGS="$(collect_cluster_matches clusterrolebinding || true)"
ROLES="$(collect_ns_matches role || true)"
RBINDINGS="$(collect_ns_matches rolebinding || true)"

if [[ -z "$CROLES$CRBINDINGS$ROLES$RBINDINGS" ]]; then
  echo "No matching RBAC (cluster or namespaced) found — nothing to delete."
  exit 0
fi

echo "ClusterRoles to delete:"
print_list "$CROLES"
echo
echo "ClusterRoleBindings to delete:"
print_list "$CRBINDINGS"
echo
echo "Roles to delete (namespaced):"
print_ns_list "$ROLES"
echo
echo "RoleBindings to delete (namespaced):"
print_ns_list "$RBINDINGS"
echo

if $DRY_RUN; then
  echo "(dry-run: not deleting)"
  exit 0
fi

if ! confirm "Proceed? Review the lists above first."; then
  echo "Aborted."
  exit 1
fi

# Delete bindings before roles; namespaced objects per-namespace.
if [[ -n "$RBINDINGS" ]]; then
  printf '%s\n' "$RBINDINGS" | while IFS=$'\t' read -r ns name; do
    [[ -z "$name" ]] && continue
    kubectl delete rolebinding -n "$ns" "$name" --ignore-not-found
  done
fi
if [[ -n "$ROLES" ]]; then
  printf '%s\n' "$ROLES" | while IFS=$'\t' read -r ns name; do
    [[ -z "$name" ]] && continue
    kubectl delete role -n "$ns" "$name" --ignore-not-found
  done
fi
if [[ -n "$CRBINDINGS" ]]; then
  printf '%s\n' "$CRBINDINGS" | while read -r name; do
    [[ -z "$name" ]] && continue
    kubectl delete clusterrolebinding "$name" --ignore-not-found
  done
fi
if [[ -n "$CROLES" ]]; then
  printf '%s\n' "$CROLES" | while read -r name; do
    [[ -z "$name" ]] && continue
    kubectl delete clusterrole "$name" --ignore-not-found
  done
fi

echo
echo "Done."
