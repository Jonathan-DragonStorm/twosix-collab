// Package persistlogic is persister's write logic, merged directly into the
// ingester component (single-hop test: gateway -> ingester only, no separate
// persister component/h3:pipeline/persist interface) to isolate whether the
// double custom-interface hop was the cause of the wasmcloud:nats/kv linking
// failure, independent of the already-confirmed h3:pipeline/persist fix.
package persistlogic

import (
	"encoding/json"
	"fmt"

	witTypes "go.bytecodealliance.org/pkg/wit/types"
	"go.wasmcloud.dev/component/nats"

	"h3ingester/h3_pipeline_types"
	"h3ingester/h3fmt"
	"h3ingester/shardutil"
)

const bucketName = "h3-points"

func PersistBatch(points []h3_pipeline_types.DataPoint) witTypes.Result[uint32, string] {
	bucket, err := nats.OpenBucket(bucketName)
	if err != nil {
		return witTypes.Err[uint32, string](fmt.Sprintf("open %s: %v", bucketName, err))
	}
	defer bucket.Close()

	var count uint32
	for _, p := range points {
		if err := h3fmt.Validate(p.H3Index); err != nil {
			return witTypes.Err[uint32, string](fmt.Sprintf("invalid h3 index %q: %v", p.H3Index, err))
		}
		key := p.Timestamp + "." + shardutil.Shard(p.H3Index) + "." + p.H3Index
		value, err := json.Marshal(p)
		if err != nil {
			return witTypes.Err[uint32, string](fmt.Sprintf("marshal point: %v", err))
		}
		if _, err := bucket.Put(key, value); err != nil {
			return witTypes.Err[uint32, string](fmt.Sprintf("put %s: %v", key, err))
		}
		count++
	}
	return witTypes.Ok[uint32, string](count)
}

// DeleteByKey purges a single point, recomputing the deterministic shard
// from h3Index the same way PersistBatch and the reader do.
func DeleteByKey(h3Index string, timestamp string) witTypes.Result[witTypes.Unit, string] {
	bucket, err := nats.OpenBucket(bucketName)
	if err != nil {
		return witTypes.Err[witTypes.Unit, string](fmt.Sprintf("open %s: %v", bucketName, err))
	}
	defer bucket.Close()

	key := timestamp + "." + shardutil.Shard(h3Index) + "." + h3Index
	if err := bucket.Purge(key); err != nil {
		return witTypes.Err[witTypes.Unit, string](fmt.Sprintf("purge %s: %v", key, err))
	}
	return witTypes.Ok[witTypes.Unit, string](witTypes.Unit{})
}

// DeleteByTime purges every point at one timestamp, fanning out across every
// shard exactly like GetByTime (kv.keys is capped at 1000 results per call,
// host-imposed).
func DeleteByTime(timestamp string) witTypes.Result[uint32, string] {
	bucket, err := nats.OpenBucket(bucketName)
	if err != nil {
		return witTypes.Err[uint32, string](fmt.Sprintf("open %s: %v", bucketName, err))
	}
	defer bucket.Close()

	var count uint32
	for shard := 0; shard < shardutil.NumShards; shard++ {
		hex := "0123456789abcdef"
		shardHex := string([]byte{hex[(shard>>4)&0xf], hex[shard&0xf]})
		filter := timestamp + "." + shardHex + ".>"
		page, err := bucket.Keys(filter)
		if err != nil {
			return witTypes.Err[uint32, string](fmt.Sprintf("keys %s: %v", filter, err))
		}
		if page.Truncated {
			return witTypes.Err[uint32, string](fmt.Sprintf("shard %s truncated at 1000 keys -- raise shardutil.NumShards", shardHex))
		}
		for _, key := range page.Keys {
			if err := bucket.Purge(key); err != nil {
				return witTypes.Err[uint32, string](fmt.Sprintf("purge %s: %v", key, err))
			}
			count++
		}
	}
	return witTypes.Ok[uint32, string](count)
}

// DeleteAll purges every point in the bucket, regardless of timestamp --
// same shard fan-out as DeleteByTime, but wildcarding the five leading
// time tokens (YYYY.MM.DD.HH.mm) instead of holding them fixed.
func DeleteAll() witTypes.Result[uint32, string] {
	bucket, err := nats.OpenBucket(bucketName)
	if err != nil {
		return witTypes.Err[uint32, string](fmt.Sprintf("open %s: %v", bucketName, err))
	}
	defer bucket.Close()

	var count uint32
	for shard := 0; shard < shardutil.NumShards; shard++ {
		hex := "0123456789abcdef"
		shardHex := string([]byte{hex[(shard>>4)&0xf], hex[shard&0xf]})
		filter := "*.*.*.*.*." + shardHex + ".>"
		page, err := bucket.Keys(filter)
		if err != nil {
			return witTypes.Err[uint32, string](fmt.Sprintf("keys %s: %v", filter, err))
		}
		if page.Truncated {
			return witTypes.Err[uint32, string](fmt.Sprintf("shard %s truncated at 1000 keys -- raise shardutil.NumShards", shardHex))
		}
		for _, key := range page.Keys {
			if err := bucket.Purge(key); err != nil {
				return witTypes.Err[uint32, string](fmt.Sprintf("purge %s: %v", key, err))
			}
			count++
		}
	}
	return witTypes.Ok[uint32, string](count)
}
