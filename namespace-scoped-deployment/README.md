# cosmonic-control 0.5.3 — Two-Stage Namespace-Scoped Installation

This directory contains the cosmonic-control and cosmonic-control-hostgroup Helm
charts (version 0.5.3) along with values files for deploying into an environment
where a third-party provider manages the Kubernetes cluster and only grants
namespace-level permissions to the deploying user.


### NOTE: Within this directory - replace all instances of `<system-name>` with the name of your system.

The installation is split into two stages:

- **Stage 1** — run once per cluster by a user with cluster-admin permissions.
  Installs only the CustomResourceDefinitions.
- **Stage 2** — run once per target namespace by a user with namespace-level
  permissions only. Installs every workload, Role, RoleBinding, ServiceAccount,
  and supporting component.

The charts natively support this split via `rbac.clusterMode: false`. With that
flag set and `metrics.secure: false` (the default), the chart creates **zero**
ClusterRoles or ClusterRoleBindings — all RBAC is namespace-scoped and handled
entirely in Stage 2.

---

## Files in this directory

| File | Purpose |
|------|---------|
| `values-stage1-cluster-admin.yaml` | Reference document for the cluster admin stage (not passed to helm — Stage 1 uses kubectl directly) |
| `values-stage2-<system-name>-dev.yaml` | Stage 2 values for the `<system-name>-dev` namespace |
| `values-stage2-<system-name>-test.yaml` | Stage 2 values for the `<system-name>-test` namespace |
| `values-stage2-hostgroup-dev.yaml` | Hostgroup values for `<system-name>-dev` |
| `values-stage2-hostgroup-test.yaml` | Hostgroup values for `<system-name>-test` |
| `cosmonic-control/` | Unpacked cosmonic-control chart |
| `cosmonic-control-hostgroup/` | Unpacked cosmonic-control-hostgroup chart |
| `cosmonic-control-0.5.3.tgz` | cosmonic-control chart archive |
| `cosmonic-control-hostgroup-0.5.3.tgz` | cosmonic-control-hostgroup chart archive |

---

## Stage 1 — Cluster Admin (once per cluster)

Apply the 7 CRDs bundled in the chart's `crds/` directory. This is the only
step that requires cluster-level permissions.

```bash
kubectl apply -f ./cosmonic-control/crds/
```

Verify all 7 CRDs are registered before proceeding:

```bash
kubectl get crds | grep -E '(wasmcloud\.dev|cosmonic\.io)'
```

Expected output:

```
artifacts.runtime.wasmcloud.dev
hosts.runtime.wasmcloud.dev
httptriggers.control.cosmonic.io
projectenvironments.control.cosmonic.io
workloaddeployments.runtime.wasmcloud.dev
workloadreplicasets.runtime.wasmcloud.dev
workloads.runtime.wasmcloud.dev
```

> **Note on Traefik CRDs:** The stock chart also ships Traefik CRDs in
> `templates/traefik/crds.yaml`. Because those are inside `templates/` (not
> `crds/`), `--skip-crds` does not suppress them. The Stage 2 values files set
> `ingress.enabled: false` to prevent the namespace user from attempting to
> apply those cluster-scoped resources. If Traefik CRDs need to be pre-applied,
> see `values-stage1-cluster-admin.yaml` for the command.

Stage 1 is shared — run it once before deploying to either namespace.

---

## Stage 2 — Namespace User

### Prerequisites

Before running Stage 2:

1. Stage 1 CRDs are applied to the cluster.
2. The target namespace exists (created by the cluster admin if the namespace
   user cannot create namespaces).
3. `cosmonic-prerequisites` is installed in the target namespace (see
   `cosmonic-control-namespace-scoped/prereq-execution-dev.txt` for the command).

### <system-name>-dev

Install cosmonic-control:

```bash

helm install cosmonic-control ./cosmonic-control \
  --namespace <system-name>-dev \
  --skip-crds \
  -f values-stage2-<system-name>-dev.yaml
```

Install the hostgroup:

```bash
helm install cosmonic-control-hostgroup ./cosmonic-control-hostgroup \
  --namespace <system-name>-dev \
  -f values-stage2-hostgroup-dev.yaml
```

### <system-name>-test

Install cosmonic-control:

```bash
helm install cosmonic-control ./cosmonic-control \
  --namespace <system-name>-test \
  --skip-crds \
  -f values-stage2-<system-name>-test.yaml
```

Install the hostgroup:

```bash
helm install cosmonic-control-hostgroup ./cosmonic-control-hostgroup \
  --namespace <system-name>-test \
  -f values-stage2-hostgroup-test.yaml
```

### Verify

```bash
helm status cosmonic-control -n <system-name>-dev
helm status cosmonic-control-hostgroup -n <system-name>-dev

kubectl get pods -n <system-name>-dev
```

### Upgrade

Replace `install` with `upgrade` on subsequent runs:

```bash
helm upgrade cosmonic-control ./cosmonic-control \
  --namespace <system-name>-dev \
  --skip-crds \
  -f values-stage2-<system-name>-dev.yaml
```

---

## Key values and why they are set

| Setting | Value | Reason |
|---------|-------|--------|
| `rbac.clusterMode` | `false` | Switches all operator RBAC from ClusterRole/ClusterRoleBinding to namespaced Role/RoleBinding. This is the primary flag that makes the chart deployable without cluster-admin permissions. |
| `metrics.secure` | `false` | Default, but set explicitly. Secure metrics requires cluster-scoped RBAC for TokenReview/SubjectAccessReview. Leaving it false means no metrics ClusterRole is created. |
| `operator.watchNamespaces` | `[<system-name>-dev]` | Scopes the operator to only reconcile Workload and HTTPTrigger resources in this namespace. The chart creates a namespaced Role for each listed namespace instead of a cluster-wide ClusterRole. |
| `operator.hostNamespaces` | `[<system-name>-dev]` | Scopes host Pod RBAC to this namespace. The chart creates a `host-finalizer` Role here instead of cluster-wide. |
| `ingress.enabled` | `false` | Prevents `templates/traefik/crds.yaml` from being rendered. Those are cluster-scoped CRDs the namespace user cannot apply. Ingress routes are managed separately via the modified templates in `cosmonic-control-namespace-scoped/`. |
| `hostgroup` | `cosmonic-dev` / `cosmonic-test` | Unique per namespace. Prevents workload scheduling from crossing namespace boundaries. |
| `controlNamespace` | matches operator namespace | Tells each hostgroup pod where to find the nexus (NATS) service and the OpenTelemetry collector. |

---

## RBAC resources created by Stage 2

With `rbac.clusterMode: false`, the `cosmonic-control` chart creates the
following namespace-scoped resources (all within the target namespace):

| Name | Kind | Purpose |
|------|------|---------|
| `cosmonic-control-leader-election` | Role + RoleBinding | Leader-election lock for the operator |
| `cosmonic-control-runtime` | Role + RoleBinding | Operator access to runtime resources in the operator namespace |
| `cosmonic-control-tenant` | Role + RoleBinding | Operator access to tenant resources (Workloads, HTTPTriggers) in each `watchNamespace` |
| `cosmonic-control-host-finalizer` | Role + RoleBinding | Operator access to clear finalizers on host Pods in each `hostNamespace` |

No ClusterRoles or ClusterRoleBindings are created.

---

## Relationship to cosmonic-control-namespace-scoped

The values files in this directory target the **stock 0.5.3 charts** using only
values overrides — no chart templates are modified.

The `cosmonic-control-namespace-scoped/` directory (in the parent workspace)
contains a separately modified version of the chart where Traefik template files
are commented out and ingress routes are customised for the provider's Traefik
configuration. Use those templates when the ingress routes need to be active;
use this directory when deploying to a fresh environment from unmodified charts.
