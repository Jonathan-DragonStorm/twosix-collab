# Cosmonic Control 0.10.0 — Air-Gapped Transfer Bundle

Everything needed to install **Cosmonic Control 0.10.0** on a disconnected
Kubernetes cluster: both Helm charts, all 12 runtime container images, the
offline documentation image, and `oras` + `helm` binaries so the receiving host
needs no downloads of its own.

Built from <https://cosmonic.com/docs/operations/air-gapped-installation/>.
Read **[Deviations from the vendor docs](#deviations-from-the-vendor-docs)** before
installing — the published instructions have three errors that will fail on a
genuinely disconnected cluster, and this bundle works around all three.

| | |
|---|---|
| Chart version | `0.10.0` |
| Platform | **`linux/amd64` only** |
| Payload | `cosmonic-control-0.10.0-airgap.tar.gz`, split into 50 MB parts |
| Receiving host | RHEL 9 |

> **Architecture:** images were mirrored for `linux/amd64` only. On an arm64
> cluster every pod will fail with `exec format error`. See
> [Rebuilding this bundle](#rebuilding-this-bundle) to remirror for `linux/arm64`.

---

## Receiving side

### Prerequisites

On the RHEL 9 host that will run the install:

- `kubectl`, configured against the target cluster
- Network reach to the cluster API and to your internal container registry
- Push access to that registry
- `tar`, `sha256sum`, `sed` (all in a base RHEL 9 install)

`oras` (v1.2.3) and `helm` (v3.16.3) ship inside the bundle at `tools/` as
static `linux/amd64` binaries — you do not need to install them.

### 1. Reassemble and verify

Copy the whole `v0.10.0/` directory across, then:

```bash
cd v0.10.0
cat cosmonic-control-0.10.0-airgap.tar.gz.part_* > cosmonic-control-0.10.0-airgap.tar.gz
sha256sum -c cosmonic-control-0.10.0-airgap.tar.gz.sha256
```

If the checksum fails, find the bad chunk instead of recopying everything:

```bash
sha256sum -c parts.sha256
```

### 2. Extract

```bash
tar -xzf cosmonic-control-0.10.0-airgap.tar.gz
cd cosmonic-control-0.10.0-airgap
```

```
cosmonic-control-0.10.0-airgap/
├── README.md
├── manifest.tsv                     # layout tag -> source ref -> target path
├── oci-layout/                      # OCI layout: 2 charts + 13 images
├── charts/                          # plain .tgz charts (fallback install)
├── manifests/
│   ├── air-gapped-values.yaml
│   └── cosmonic-docs.yaml
├── scripts/
│   ├── 01-load-registry.sh
│   ├── 02-install.sh
│   └── traefik-postrender.sh
└── tools/
    ├── helm                         # v3.16.3, linux/amd64, static
    ├── oras                         # v1.2.3,  linux/amd64, static
    └── SHA256SUMS
```

### 3. Push to the internal registry

```bash
export REGISTRY=registry.internal.corp:5000

# only if your registry requires auth
./tools/oras login "$REGISTRY" -u <username> -p <password>

./scripts/01-load-registry.sh
```

For an HTTP-only or self-signed registry:

```bash
ORAS_EXTRA="--to-plain-http" ./scripts/01-load-registry.sh   # plain HTTP
ORAS_EXTRA="--to-insecure"   ./scripts/01-load-registry.sh   # self-signed TLS
```

This pushes 15 artifacts. Verify:

```bash
./tools/oras repo ls "$REGISTRY"
```

### 4. Install

```bash
export REGISTRY=registry.internal.corp:5000
export REG_USER=<username> REG_PASS=<password>

./scripts/02-install.sh
```

Useful overrides:

| Variable | Default | Purpose |
|---|---|---|
| `NAMESPACE` | `cosmonic-system` | Target namespace |
| `ENVOY_SVC_TYPE` | `LoadBalancer` | Use `NodePort` if the cluster has no load balancer |
| `SKIP_SECRET` | `0` | Set to `1` for an anonymous-pull registry |
| `INSTALL_DOCS` | `0` | Set to `1` to also deploy the offline docs site |

### 5. Verify

```bash
kubectl rollout status deploy -l app.kubernetes.io/instance=cosmonic-control -n cosmonic-system
kubectl rollout status deploy -l app.kubernetes.io/instance=hostgroup -n cosmonic-system
kubectl get pods -n cosmonic-system
```

Offline docs, if installed with `INSTALL_DOCS=1`:

```bash
kubectl port-forward -n cosmonic-system svc/cosmonic-docs 8080:80
# browse http://localhost:8080
```

---

## Deviations from the vendor docs

The published air-gapped guide does not work as written. Three problems, all
already handled by the scripts in this bundle:

### 1. Traefik's images bypass every registry override

`templates/traefik/deployment.yaml` hardcodes two references:

```yaml
image: busybox:1.37.0             # initContainer "volume-permissions"
image: docker.io/traefik:v3.6.6   # traefik container
```

Neither honours `global.image.registry`, so on a disconnected cluster both are
pulled from Docker Hub and the ingress pod never starts. `02-install.sh` passes
`scripts/traefik-postrender.sh` as a Helm post-renderer, which rewrites both to
`${REGISTRY}/…`. Both images are mirrored in this bundle.

Separately, the traefik Deployment has **no `imagePullSecrets` field** — it
authenticates through its ServiceAccount. `02-install.sh` therefore patches the
pull secret onto the `traefik` ServiceAccount and restarts the deployment.

Two alternatives, if you would rather not use a post-renderer:

- Configure a registry mirror on the nodes so `docker.io` resolves internally
  (`/etc/containers/registries.conf` for CRI-O, `containerd`'s
  `config_path` hosts directory for containerd).
- Skip Traefik entirely: `--set ingress.enabled=false`, or
  `--set ingress.provider=istio` to front Cosmonic with an existing Istio
  IngressGateway.

### 2. The hostgroup `--set` in the docs produces a broken image reference

The docs say:

```bash
--set image.repository=${REGISTRY}/cosmonic/control-host   # WRONG
```

The chart has a separate `image.registry` (defaulting to `ghcr.io`) that is
prepended, so this renders `ghcr.io/${REGISTRY}/cosmonic/control-host:0.10.0`.
The correct form, used by `02-install.sh`:

```bash
--set image.registry=${REGISTRY} \
--set image.repository=cosmonic/control-host \
--set "image.pullSecrets[0].name=registry-credentials"
```

### 3. The docs image tag `0.10.0` does not exist

`ghcr.io/cosmonic/docs:0.10.0` returns `MANIFEST_UNKNOWN`. The published tags
are `0.5.1`, `0.6.0`, `0.7.0` and `latest`; `0.7.0` and `latest` are the same
digest (`sha256:60c65589…`). This bundle mirrors **`cosmonic/docs:0.7.0`** and
`manifests/cosmonic-docs.yaml` references that tag.

### 4. The docs' image-discovery loop mangles `busybox`

The published loop is:

```bash
for src in ${images}; do oras copy "${src}" "${REGISTRY}/${src#*/}"; done
```

`busybox:1.37.0` has no registry prefix, so `${src#*/}` leaves it unchanged —
it happens to work, but only by luck. This bundle uses an explicit
`manifest.tsv` mapping instead of string surgery, so every source ref and every
target path is pinned and auditable.

---

## Bundle contents

Mirrored for `linux/amd64`. Target paths are relative to `${REGISTRY}`.

### Helm charts

| Source | Target |
|---|---|
| `ghcr.io/cosmonic/cosmonic-control:0.10.0` | `cosmonic/cosmonic-control:0.10.0` |
| `ghcr.io/cosmonic/cosmonic-control-hostgroup:0.10.0` | `cosmonic/cosmonic-control-hostgroup:0.10.0` |

### Container images

| Source | Target |
|---|---|
| `ghcr.io/cosmonic/runtime-operator:0.10.0` | `cosmonic/runtime-operator:0.10.0` |
| `ghcr.io/cosmonic/nexus:0.10.0` | `cosmonic/nexus:0.10.0` |
| `ghcr.io/cosmonic/control-host:0.10.0` | `cosmonic/control-host:0.10.0` |
| `ghcr.io/cosmonic/control/envoy:v1.39.0` | `cosmonic/control/envoy:v1.39.0` |
| `ghcr.io/cosmonic/control/cosmonic-perses:v0.54.0` | `cosmonic/control/cosmonic-perses:v0.54.0` |
| `ghcr.io/cosmonic/control/kiwigrid-k8s-sidecar:2.10.1` | `cosmonic/control/kiwigrid-k8s-sidecar:2.10.1` |
| `ghcr.io/cosmonic/control/prometheus:v3.14.0` | `cosmonic/control/prometheus:v3.14.0` |
| `ghcr.io/cosmonic/control/loki:3.7.6` | `cosmonic/control/loki:3.7.6` |
| `ghcr.io/cosmonic/control/tempo:3.0.3` | `cosmonic/control/tempo:3.0.3` |
| `ghcr.io/cosmonic/control/otel-collector-contrib:0.159.0` | `cosmonic/control/otel-collector-contrib:0.159.0` |
| `docker.io/traefik:v3.6.6` | `traefik:v3.6.6` |
| `busybox:1.37.0` | `busybox:1.37.0` |
| `ghcr.io/cosmonic/docs:0.7.0` | `cosmonic/docs:0.7.0` |

---

## Manual equivalents

If you would rather not run the scripts.

**Push one artifact:**

```bash
./tools/oras copy --from-oci-layout \
  ./oci-layout:img_nexus_0.10.0 \
  "${REGISTRY}/cosmonic/nexus:0.10.0"
```

Layout tags are in column 2 of `manifest.tsv`.

**Install without the post-renderer** (Traefik disabled, so the two Docker Hub
images are never referenced):

```bash
sed "s|REGISTRY_PLACEHOLDER|${REGISTRY}|g" manifests/air-gapped-values.yaml > values.yaml

./tools/helm install cosmonic-control "oci://${REGISTRY}/cosmonic/cosmonic-control" \
  --version 0.10.0 --namespace cosmonic-system --create-namespace \
  --set envoy.service.type=LoadBalancer \
  --set ingress.enabled=false \
  -f values.yaml
```

**Install straight from the bundled chart tarball**, skipping the chart push —
images still come from `${REGISTRY}`:

```bash
REGISTRY=$REGISTRY ./tools/helm install cosmonic-control ./charts/cosmonic-control-0.10.0.tgz \
  --namespace cosmonic-system --create-namespace \
  -f values.yaml --post-renderer ./scripts/traefik-postrender.sh
```

**Uninstall:**

```bash
./tools/helm uninstall hostgroup cosmonic-control -n cosmonic-system
kubectl delete -f manifests/cosmonic-docs.yaml --ignore-not-found
```

---

## Rebuilding this bundle

Run on a connected host with `helm`, `oras` and `jq`.

```bash
CHART_VERSION=0.10.0

# 1. Discover the image set from the rendered charts
{ helm template oci://ghcr.io/cosmonic/cosmonic-control --version $CHART_VERSION
  helm template oci://ghcr.io/cosmonic/cosmonic-control-hostgroup --version $CHART_VERSION
} | grep -oE 'image:[[:space:]]*"?[^"[:space:]]+' \
  | sed -E 's/image:[[:space:]]*"?//' | sort -u

# 2. Mirror each entry of manifest.tsv into a shared OCI layout.
#    Drop --platform, or change it, to mirror other architectures.
tail -n +2 manifest.tsv | while IFS=$'\t' read -r kind tag src target; do
  if [ "$kind" = chart ]; then
    oras copy --to-oci-layout "$src" "oci-layout:${tag}"
  else
    oras copy --platform linux/amd64 --to-oci-layout "$src" "oci-layout:${tag}"
  fi
done

# 3. Pack and split for transfer
tar -czf cosmonic-control-0.10.0-airgap.tar.gz cosmonic-control-0.10.0-airgap
sha256sum cosmonic-control-0.10.0-airgap.tar.gz > cosmonic-control-0.10.0-airgap.tar.gz.sha256
split -b 50M cosmonic-control-0.10.0-airgap.tar.gz cosmonic-control-0.10.0-airgap.tar.gz.part_
sha256sum cosmonic-control-0.10.0-airgap.tar.gz.part_* > parts.sha256
```

Omitting `--platform` mirrors the full multi-arch manifest list (roughly double
the size for amd64 + arm64, considerably more for images that publish s390x,
ppc64le and riscv64).
