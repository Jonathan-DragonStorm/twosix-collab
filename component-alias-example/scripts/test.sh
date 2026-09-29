#!/usr/bin/env bash
# Asserts that the same component artifacts are wired into two different
# pipelines purely by Workload component names.
set -euo pipefail

NAMESPACE="${NAMESPACE:-twosix-dev}"
INGRESS_IP="${INGRESS_IP:-127.0.0.1}"
fail=0

# check <workload host prefix> <expected trace JSON> <expect description?>
check() {
  local host="$1.localhost.cosmonic.sh" want="$2" want_desc="$3" body
  body=$(curl -sf --max-time 15 --resolve "$host:80:$INGRESS_IP" "http://$host/")
  local got; got=$(jq -c '.[0].trace' <<<"$body")
  local desc; desc=$(jq -r 'all(.[]; .description != null)' <<<"$body")
  if [[ "$got" == "$want" && "$desc" == "$want_desc" ]]; then
    echo "PASS $1: trace=$got described=$desc"
  else
    echo "FAIL $1: trace=$got (want $want) described=$desc (want $want_desc)"
    fail=1
  fi
}

check base-menu '["menu-ingester","meal-gen","menu-persister","menu-distributor"]' true
check breakfast-menu '["menu-ingester","menu-persister","menu-distributor"]' false

# A POSTed item that already has a description keeps it through meal-gen.
host=base-menu.localhost.cosmonic.sh
got=$(curl -sf --max-time 15 --resolve "$host:80:$INGRESS_IP" -X POST "http://$host/" \
  -d '[{"name":"waffles","meal":"breakfast","description":"from parent co","ingredients":["flour"],"trace":[]}]' \
  | jq -r '.[0].description')
if [[ "$got" == "from parent co" ]]; then echo "PASS POST keeps description"; else echo "FAIL POST description=$got"; fail=1; fi

# The two Workloads run the very same artifacts under different role names:
# no per-topology build.
REGISTRY="${REGISTRY:-registry.localhost.cosmonic.sh}"
REGISTRY_CA="${REGISTRY_CA:-$(dirname "$0")/../.bin/registry-ca.crt}"
echo "Workload wiring (component name -> image@digest):"
for wd in $(kubectl -n "$NAMESPACE" get workloaddeployments -o name | grep menu-receiver); do
  echo "  ${wd#*/}"
  kubectl -n "$NAMESPACE" get "$wd" -o json | jq -r '.spec.template.spec.components[] | "\(.name) \(.image)"' |
  while read -r name image; do
    repo=${image#*/}; repo=${repo%:*}; tag=${image##*:}
    digest=$(curl -sI --cacert "$REGISTRY_CA" \
      -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
      "https://$REGISTRY/v2/$repo/manifests/$tag" | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}' | tr -d '\r')
    printf '    %-11s %s@%s\n' "$name" "${repo##*/}:$tag" "${digest:0:19}"
  done
done

exit $fail
