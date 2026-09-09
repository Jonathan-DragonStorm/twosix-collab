package export_h3_pipeline_query

import (
	"encoding/json"
	"fmt"

	witTypes "go.bytecodealliance.org/pkg/wit/types"
	"go.wasmcloud.dev/component/nats"

	"h3reader/h3_pipeline_types"
	"h3reader/shardutil"
)

const bucketName = "h3-points"

// GetByKey recomputes the deterministic shard from h3Index -- the same pure
// function the persister used to write the key -- so this is a single direct
// KV get, never a wildcard-discovery scan.
func GetByKey(h3Index string, timestamp string) witTypes.Result[h3_pipeline_types.DataPoint, string] {
	bucket, err := nats.OpenBucket(bucketName)
	if err != nil {
		return witTypes.Err[h3_pipeline_types.DataPoint, string](fmt.Sprintf("open %s: %v", bucketName, err))
	}
	defer bucket.Close()

	key := timestamp + "." + shardutil.Shard(h3Index) + "." + h3Index
	entry, err := bucket.Get(key)
	if err != nil {
		return witTypes.Err[h3_pipeline_types.DataPoint, string](fmt.Sprintf("get %s: %v", key, err))
	}
	var p h3_pipeline_types.DataPoint
	if err := json.Unmarshal(entry.Value, &p); err != nil {
		return witTypes.Err[h3_pipeline_types.DataPoint, string](fmt.Sprintf("decode %s: %v", key, err))
	}
	return witTypes.Ok[h3_pipeline_types.DataPoint, string](p)
}

// GetByTime answers "all H3 cells at time T" by fanning out across every
// shard (kv.keys is capped at 1000 results per call, host-imposed -- a
// single "<time>.*" listing of ~40k cells would be truncated), then issuing
// one get per returned key (kv has no batch-get). This N-list-plus-M-get
// cost, versus a single native NATS Watch(), is exactly what this load-test
// harness exists to measure.
func GetByTime(timestamp string) witTypes.Result[[]h3_pipeline_types.DataPoint, string] {
	bucket, err := nats.OpenBucket(bucketName)
	if err != nil {
		return witTypes.Err[[]h3_pipeline_types.DataPoint, string](fmt.Sprintf("open %s: %v", bucketName, err))
	}
	defer bucket.Close()

	// A nil (vs empty non-nil) slice crossing the wRPC boundary via the
	// generated marshaling code trapped with "unreachable instruction
	// executed" when zero points matched -- initialize non-nil.
	points := make([]h3_pipeline_types.DataPoint, 0)
	for shard := 0; shard < shardutil.NumShards; shard++ {
		hex := "0123456789abcdef"
		shardHex := string([]byte{hex[(shard>>4)&0xf], hex[shard&0xf]})
		filter := timestamp + "." + shardHex + ".>"
		page, err := bucket.Keys(filter)
		if err != nil {
			return witTypes.Err[[]h3_pipeline_types.DataPoint, string](fmt.Sprintf("keys %s: %v", filter, err))
		}
		if page.Truncated {
			return witTypes.Err[[]h3_pipeline_types.DataPoint, string](fmt.Sprintf("shard %s truncated at 1000 keys -- raise shardutil.NumShards", shardHex))
		}
		for _, key := range page.Keys {
			entry, err := bucket.Get(key)
			if err != nil {
				return witTypes.Err[[]h3_pipeline_types.DataPoint, string](fmt.Sprintf("get %s: %v", key, err))
			}
			var p h3_pipeline_types.DataPoint
			if err := json.Unmarshal(entry.Value, &p); err != nil {
				return witTypes.Err[[]h3_pipeline_types.DataPoint, string](fmt.Sprintf("decode %s: %v", key, err))
			}
			points = append(points, p)
		}
	}
	return witTypes.Ok[[]h3_pipeline_types.DataPoint, string](points)
}
