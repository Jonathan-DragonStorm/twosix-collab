#!/usr/bin/env bash
# Cleanup helper for the load-test scripts -- wraps h3-ingest's delete
# endpoints. Defaults to deleting one timestamp; pass --all to wipe the
# entire h3-points bucket instead.
#
# Usage: ./load-cleanup.sh TIMESTAMP
#        ./load-cleanup.sh --all

# ./load-ingest.sh 40000 500
# ./load-query.sh
# ./load-cleanup.sh --all

set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

if [[ "${1:-}" == "--all" ]]; then
  echo "Deleting ALL points in the h3-points bucket..."
  resp=$(curl_ingest "/points" -X DELETE)
else
  TIMESTAMP="${1:?usage: load-cleanup.sh TIMESTAMP | load-cleanup.sh --all}"
  echo "Deleting all points at timestamp=$TIMESTAMP..."
  resp=$(curl_ingest "/points?timestamp=${TIMESTAMP}" -X DELETE)
fi

echo "$resp"
