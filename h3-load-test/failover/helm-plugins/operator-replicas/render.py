#!/usr/bin/env python3
"""Helm post-renderer: set spec.replicas on the cosmonic-control operator Deployment.

The 0.14 chart hard-codes the operator to `replicas: 1` (the binary always runs
with -leader-elect, so extra replicas are hot standbys). Usage:

    helm upgrade cosmonic-control ... --post-renderer operator-replicas --post-renderer-args 2

Reads the rendered manifests on stdin and writes them to stdout, changing only
the `replicas:` line of the Deployment whose name is `operator`.
"""
import re
import sys

replicas = int(sys.argv[1]) if len(sys.argv) > 1 else 1
out = []
for doc in re.split(r"(?m)^---\s*$", sys.stdin.read()):
    if re.search(r"(?m)^kind:\s*Deployment\s*$", doc) and re.search(r"(?m)^  name:\s*operator\s*$", doc):
        doc, n = re.subn(r"(?m)^  replicas:\s*\d+\s*$", f"  replicas: {replicas}", doc, count=1)
        if n != 1:
            sys.exit("operator-replicas: operator Deployment has no top-level replicas field to patch")
    out.append(doc)
sys.stdout.write("---".join(out))
