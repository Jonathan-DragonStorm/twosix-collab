// Package shardutil computes the deterministic KV key shard for an H3 index,
// used identically by every writer and reader in the H3 load-test harness so
// a by-key lookup never needs to discover its shard via a wildcard scan.
//
// wasmcloud:nats's kv.keys(filter) is capped at 1000 results per call
// (host-imposed, confirmed against the actual WIT source), so a single
// "<time>.*" listing of ~40k H3 cells would be truncated. Sharding partitions
// the keyspace into N buckets via a hash of the full H3 index string (not a
// substring -- for a fixed H3 resolution, the leading/trailing hex
// characters of every index are constant, so slicing a prefix would put
// every cell in the same shard).
package shardutil

import "hash/fnv"

// NumShards is the shard count. ~625 keys/shard average at 40k cells --
// comfortable margin under the 1000-key cap even with hash skew.
const NumShards = 64

// Shard returns the 2-hex-char shard token for h3Index.
func Shard(h3Index string) string {
	h := fnv.New32a()
	h.Write([]byte(h3Index))
	n := h.Sum32() % NumShards
	const hex = "0123456789abcdef"
	return string([]byte{hex[(n>>4)&0xf], hex[n&0xf]})
}
