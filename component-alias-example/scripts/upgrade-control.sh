#!/usr/bin/env bash
# In-place upgrade of Cosmonic Control and its hostgroups to the release that
# routes (implements ..) named imports between guest components
# (wasmCloud 2.10, Cosmonic Control 0.12.2).
#
# Reuses each release's current user-supplied values. Helm never upgrades
# CRDs, so the new ones are applied first.
set -euo pipefail

VERSION="${VERSION:-0.12.2}"
NAMESPACE="${NAMESPACE:-twosix-dev}"
CONTROL_RELEASE="${CONTROL_RELEASE:-cosmonic-control}"
HOSTGROUP_RELEASES="${HOSTGROUP_RELEASES:-hostgroup-a hostgroup-h3}"
CHARTS=oci://ghcr.io/cosmonic
BACKUP_DIR="${BACKUP_DIR:-$(mktemp -d)}"

echo "Saving current values to $BACKUP_DIR"
for r in $CONTROL_RELEASE $HOSTGROUP_RELEASES; do
  helm get values "$r" -n "$NAMESPACE" -o yaml > "$BACKUP_DIR/$r.yaml"
done

echo "Applying $VERSION CRDs"
helm show crds "$CHARTS/cosmonic-control" --version "$VERSION" \
  | kubectl apply --server-side --force-conflicts -f -

echo "Upgrading $CONTROL_RELEASE"
helm upgrade "$CONTROL_RELEASE" "$CHARTS/cosmonic-control" --version "$VERSION" \
  -n "$NAMESPACE" -f "$BACKUP_DIR/$CONTROL_RELEASE.yaml" --wait --timeout 10m

for r in $HOSTGROUP_RELEASES; do
  echo "Upgrading $r"
  helm upgrade "$r" "$CHARTS/cosmonic-control-hostgroup" --version "$VERSION" \
    -n "$NAMESPACE" -f "$BACKUP_DIR/$r.yaml" --wait --timeout 10m
done

helm list -n "$NAMESPACE"
kubectl -n "$NAMESPACE" get deploy -o wide
