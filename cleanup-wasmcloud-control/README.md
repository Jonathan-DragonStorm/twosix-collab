# Cleanup: wasmCloud + Cosmonic Control

For a Kubernetes cluster that had both wasmCloud and Cosmonic Control installed
at some point, these scripts clean up everything that could have been installed
either manually or via Helm. They assume the installed versions are wasmCloud > 2.0.3, Cosmonic Control chart > 0.5.0, and the Cosmonic Control HostGroup
chart > 0.5.0.

All custom resources and CRDs the scripts target live in one of two API groups:

- `runtime.wasmcloud.dev` (e.g. `WorkloadDeployment`)
- `control.cosmonic.io` (e.g. `HTTPTrigger`)

The scripts are numbered in the order you should run them for a clean teardown.

## Prerequisites

| Tool      | Used by                            |
| --------- | ---------------------------------- |
| `kubectl` | All scripts                        |
| `helm`    | `03-helm-uninstall.sh`, `06-verify-clean.sh` |
| `jq`      | `03-helm-uninstall.sh`, `06-verify-clean.sh` (optional — falls back to text parsing) |

The scripts auto-discover which CRDs and releases are actually installed, so
they are safe to run on a cluster where only some of these components were ever
present — anything not found is reported and skipped.

## Scripts

Each delete/uninstall script prompts for confirmation and supports `--dry-run`
(preview only) and `--yes` (skip the prompt).

| Run order | Script | What it does | Who runs it |
| --------- | ------ | ------------ | ----------- |
| 1 | [`01-list-workloads.sh`](01-list-workloads.sh) | Read-only. Lists every `WorkloadDeployment` and the owning `HTTPTrigger` (where one created it), plus any standalone `HTTPTrigger`s. | Anyone — verification |
| 2 | [`02-delete-workloads.sh`](02-delete-workloads.sh) | Deletes all `HTTPTrigger`s and `WorkloadDeployment`s — the same set script 1 lists. | Operator |
| 3 | [`03-helm-uninstall.sh`](03-helm-uninstall.sh) | `helm uninstall`s every Cosmonic Control / wasmCloud Helm release in any namespace (matched on chart **or** release name, any version), **HostGroup charts first and the operator chart last**. | Operator |
| 4 | [`04-delete-crds.sh`](04-delete-crds.sh) | Deletes all CRDs in the `runtime.wasmcloud.dev` and `control.cosmonic.io` API groups. | Cluster Admin |
| 5 | [`05-delete-rbac.sh`](05-delete-rbac.sh) | Deletes `ClusterRole`s/`ClusterRoleBinding`s **and** namespaced `Role`s/`RoleBinding`s installed by wasmCloud or Cosmonic Control (manually or via Helm). | Cluster Admin |
| 6 | [`06-verify-clean.sh`](06-verify-clean.sh) | Read-only. Confirms no CRDs, RBAC (cluster or namespaced), or Helm releases remain; exits non-zero if any do. | Anyone — verification |

> These map to the original goals 1–5 as: list → 1, delete-workloads → 2,
> helm-uninstall → 5, delete-crds → 3, delete-rbac → 4. Step 6 is an added
> end-to-end verification. The Helm uninstall is sequenced **between** deleting
> the workloads and deleting the CRDs so the operator is removed cleanly before
> its API surface is torn down.

### 1. `01-list-workloads.sh` — verify what is deployed

Read-only inventory. Run this first to see what wasmCloud / Cosmonic Control
resources still exist before you delete anything.

```bash
./01-list-workloads.sh            # all namespaces
./01-list-workloads.sh -n tenant-a
```

It prints each `WorkloadDeployment` with the `HTTPTrigger` that owns it (via
owner references), then lists all `HTTPTrigger`s.

### 2. `02-delete-workloads.sh` — delete the workloads

Destructive companion to script 1, operating on the same resources.
`HTTPTrigger`s are deleted first (so the operator stops re-creating
`WorkloadDeployment`s and owner-reference garbage collection cleans most of
them up), then any orphaned `WorkloadDeployment`s are removed.

```bash
./02-delete-workloads.sh --dry-run   # preview
./02-delete-workloads.sh             # delete (prompts to confirm)
./02-delete-workloads.sh -n tenant-a --yes
```

### 3. `03-helm-uninstall.sh` — uninstall the Helm charts

Finds and uninstalls every Helm release that is `cosmonic-control`,
`cosmonic-control-hostgroup`, `http-trigger`, `runtime-operator` (the wasmCloud
operator chart — e.g. `runtime-operator-0.4.0`), or anything matching
`wasmcloud` / `cosmonic` / `wadm`, across all namespaces.

A release matches if **either its chart name or its release name** matches —
the wasmCloud operator ships as chart `runtime-operator` but is commonly
installed under the release name `wasmcloud`, so matching the chart name alone
would miss it. Matching is **version-independent** (0.4.0, 0.5.0, and newer all
match), and `helm list -a` is used so releases in any status are caught.

**Order matters here.** The host pod carries a finalizer that the
`runtime-operator` (shipped in the `cosmonic-control` chart) must be running to
clear. If the operator were removed first, the HostGroup release would hang on
that finalizer. The script therefore always uninstalls in this order:

1. `cosmonic-control-hostgroup` (host pods)
2. `http-trigger`
3. any other matched chart
4. `cosmonic-control` (the operator) — last

```bash
./03-helm-uninstall.sh --dry-run     # shows the planned uninstall order
./03-helm-uninstall.sh
```

### 4. `04-delete-crds.sh` — delete the CRDs (Cluster Admin)

Deletes every CRD in the two API groups. **Deleting a CRD cascades** — it
removes every custom resource of that kind in every namespace — so run steps 2
and 3 first.

```bash
./04-delete-crds.sh --dry-run
./04-delete-crds.sh            # prompts to confirm
```

**Hanging on a finalizer?** A `kubectl delete crd` can hang indefinitely when
custom resources still carry finalizers (e.g. `Host` objects hold
`runtime.wasmcloud.dev/host-finalizer`) but the operator that would clear them
has already been uninstalled in step 3. The CRD waits on its own cleanup
finalizer until every instance is gone, and the instances never finish
terminating. Re-run with `--force` to strip the finalizers off the stuck custom
resources (and, as a last resort, off the CRD object itself) so the deletes
complete:

```bash
./04-delete-crds.sh --force            # prompts to confirm
./04-delete-crds.sh --force --yes      # non-interactive
```

This is safe at this point precisely because the operator is gone — its
finalizer logic cannot run anyway, so skipping it loses nothing. If a previous
`kubectl delete crd` is still hanging in another terminal, `--force` clearing
the custom-resource finalizers will also let that pending delete finish.

### 5. `05-delete-rbac.sh` — delete RBAC (Cluster Admin)

Deletes RBAC that belongs to wasmCloud / Cosmonic Control, both:

- cluster-scoped: `ClusterRole`s and `ClusterRoleBinding`s, and
- namespaced: `Role`s and `RoleBinding`s in every namespace.

`helm uninstall` (step 3) normally removes the namespaced Roles/RoleBindings it
created, but this script also sweeps them up in case they were applied by hand
or orphaned by a failed/partial uninstall. Objects are matched by
Helm/Kubernetes labels (`app.kubernetes.io/part-of`, `app.kubernetes.io/name`)
**or** by a known name prefix, so it catches both Helm-managed and hand-applied
RBAC. Every match is printed for review before deletion.

```bash
./05-delete-rbac.sh --dry-run   # review the match list first
./05-delete-rbac.sh
```

### 6. `06-verify-clean.sh` — confirm the cluster is clean

Read-only final check. Verifies that none of the following remain, and **exits
non-zero if any do** (so it can gate automation):

- CRDs in the `runtime.wasmcloud.dev` / `control.cosmonic.io` API groups (and
  any leftover custom resources)
- `ClusterRole`s / `ClusterRoleBinding`s matching wasmCloud / Cosmonic Control
- `Role`s / `RoleBinding`s (namespaced) matching wasmCloud / Cosmonic Control
- Helm releases for any Cosmonic Control / wasmCloud chart

```bash
./06-verify-clean.sh
# ... RESULT: CLEAN — no wasmCloud or Cosmonic Control resources remain.
```

## Full teardown

The scripts are independent, but for a clean, complete teardown run them in
numeric order:

```bash
./01-list-workloads.sh        # inventory (verify)
./02-delete-workloads.sh      # delete HTTPTriggers + WorkloadDeployments
./03-helm-uninstall.sh        # helm uninstall hostgroups first, then the operator
./04-delete-crds.sh           # delete the CRDs (admin; add --force if a delete hangs on a finalizer)
./05-delete-rbac.sh           # delete leftover RBAC, cluster + namespaced (admin)
./06-verify-clean.sh          # confirm the cluster is clean (exits non-zero if not)
```

The Helm uninstall runs before the CRD/RBAC steps so the operator processes
host-pod finalizers and is removed cleanly, and the CRDs are then deleted with
no controller left to re-create custom resources. Step 6 confirms the result.
