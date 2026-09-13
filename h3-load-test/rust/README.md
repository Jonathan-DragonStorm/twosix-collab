# H3 load test — Rust components

Rust implementations of the four deployed Go components, as a drop-in
alternative path for comparing the two languages:

| Crate | Go equivalent | WIT |
|---|---|---|
| `reader` | `../reader` | exports `h3:pipeline/query` |
| `distribute-gateway` | `../distribute-gateway` | exports `wasi:http/handler@0.3.0`, imports `h3:pipeline/query` |
| `ingester` | `../ingester` | exports `h3:pipeline/ingest` and `wasmcloud:nats/core-handler` |
| `ingest-gateway` | `../ingest-gateway` | exports `wasi:http/handler@0.3.0`, imports `h3:pipeline/ingest` |

`h3-common` holds the logic both implementations must agree on (shard hash,
key layout, H3 validation, stored value encoding). The Rust and Go components
read and write the same keys and byte-identical values in the same
`h3-points` bucket, and serve the same HTTP routes and responses, so either
implementation can read data the other wrote.

The behavior mirrors the Go components as of the concurrent reader:
`get-by-time` streams its JSON document and fetches keys and points
concurrently (16 shard listings, 32 gets). The ingester keeps Go's sequential
puts and purges. One difference is idiomatic rather than algorithmic: the
Rust distribute gateway hands the reader's stream to the HTTP response as the
body, while Go's `net/http` adapter copies it through.

## Build

Requires the `wasm32-wasip2` Rust target (`rustup target add wasm32-wasip2`).
WIT dependencies are vendored under each crate's `wit/deps`, so skip fetching:

```bash
for c in reader distribute-gateway ingester ingest-gateway; do
  (cd $c && wash build --skip-fetch)
done
cargo test -p h3-common   # shard/validation/encoding parity with Go
```

Components are written to `target/wasm32-wasip2/release/h3_*.wasm`.

## Deploy

Push each component (the manifests expect these image names) and apply the
triggers in `manifests/`. They use their own names and hosts
(`h3-distribute-rs`, `h3-ingest-rs`) so they can run alongside the Go
triggers, with the same `poolSize`, `maxConcurrency`, and `timeout`:

```bash
REGISTRY=registry.twosix-dev.svc.cluster.local/library
wash oci push $REGISTRY/h3-reader-rs:0.1.0             target/wasm32-wasip2/release/h3_reader.wasm
wash oci push $REGISTRY/h3-distribute-gateway-rs:0.1.0 target/wasm32-wasip2/release/h3_distribute_gateway.wasm
wash oci push $REGISTRY/h3-ingester-rs:0.1.0           target/wasm32-wasip2/release/h3_ingester.wasm
wash oci push $REGISTRY/h3-ingest-gateway-rs:0.1.0     target/wasm32-wasip2/release/h3_ingest_gateway.wasm
kubectl apply -f manifests/
```

The load-test scripts take the hosts from the environment:

```bash
cd ../scripts
INGEST_HOST=h3-ingest-rs.localhost.cosmonic.sh ./load-ingest.sh 41846 500 2026.09.13.00.00
DISTRIBUTE_HOST=h3-distribute-rs.localhost.cosmonic.sh ./bulk_load.py -c 16 -n 32 --expect 41846 2026.09.13.00.00
```

Both ingesters subscribe to `h3.ingest.raw` (the only subject the hostgroup
grants), so with both deployed a published point is written twice to the
same key with the same value.
