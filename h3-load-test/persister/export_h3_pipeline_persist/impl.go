package export_h3_pipeline_persist

import (
	"encoding/json"
	"fmt"

	witTypes "go.bytecodealliance.org/pkg/wit/types"
	"go.wasmcloud.dev/component/nats"

	"h3persister/h3_pipeline_types"
	"h3persister/h3fmt"
	"h3persister/shardutil"
)

const bucketName = "h3-points"

// PersistBatch writes each point to the h3-points KV bucket, keyed
// "<timestamp>.<shard>.<h3Index>". Shard is a deterministic hash of the H3
// index alone, so any reader can recompute the same key without a lookup.
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
