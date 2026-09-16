package export_h3_pipeline_query

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"sync"
	"time"

	witTypes "go.bytecodealliance.org/pkg/wit/types"
	"go.wasmcloud.dev/component/nats"

	"h3reader/h3_pipeline_query"
	"h3reader/h3_pipeline_types"
	"h3reader/shardutil"
)

const bucketName = "h3-points"

const (
	// keysConcurrency is how many shard key listings are in flight at once.
	keysConcurrency = 16
	// getConcurrency is how many gets are in flight at once. Every KV call
	// is an async import, so goroutines waiting on them overlap on the host.
	getConcurrency = 32
	// streamBufferBytes batches writes to the get-by-time stream; every
	// stream write is a round trip to the host.
	streamBufferBytes = 64 << 10
)

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
//
// The shard listings and the gets each run concurrently. The keys are listed
// before returning so listing errors are still reported as an error result.
// The points are then streamed as a JSON document from a background
// goroutine as they are read, rather than returned as one list<data-point>
// the host has to copy into the caller record by record.
func GetByTime(timestamp string) witTypes.Result[*witTypes.StreamReader[uint8], string] {
	start := time.Now()
	bucket, err := nats.OpenBucket(bucketName)
	if err != nil {
		return witTypes.Err[*witTypes.StreamReader[uint8], string](fmt.Sprintf("open %s: %v", bucketName, err))
	}

	keys, err := listKeys(bucket, timestamp)
	if err != nil {
		bucket.Close()
		return witTypes.Err[*witTypes.StreamReader[uint8], string](err.Error())
	}

	tx, rx := h3_pipeline_query.MakeStreamU8()
	go func() {
		defer bucket.Close()
		defer tx.Drop()
		writePoints(streamWriter{tx}, bucket, keys, start)
	}()
	return witTypes.Ok[*witTypes.StreamReader[uint8], string](rx)
}

// listKeys lists every shard for timestamp, up to keysConcurrency at a time.
func listKeys(bucket *nats.Bucket, timestamp string) ([]string, error) {
	pages := make([][]string, shardutil.NumShards)
	errs := make([]error, shardutil.NumShards)
	sem := make(chan struct{}, keysConcurrency)
	var wg sync.WaitGroup
	for shard := 0; shard < shardutil.NumShards; shard++ {
		wg.Add(1)
		sem <- struct{}{}
		go func() {
			defer func() { <-sem; wg.Done() }()
			filter := fmt.Sprintf("%s.%02x.>", timestamp, shard)
			page, err := bucket.Keys(filter)
			switch {
			case err != nil:
				errs[shard] = fmt.Errorf("keys %s: %v", filter, err)
			case page.Truncated:
				errs[shard] = fmt.Errorf("shard %02x truncated at 1000 keys -- raise shardutil.NumShards", shard)
			default:
				pages[shard] = page.Keys
			}
		}()
	}
	wg.Wait()

	var keys []string
	for shard, page := range pages {
		if errs[shard] != nil {
			return nil, errs[shard]
		}
		keys = append(keys, page...)
	}
	return keys, nil
}

// writePoints writes {"points":[...],"count":N,"elapsedMs":MS} to out,
// fetching up to getConcurrency points at a time and writing each as it
// arrives, so points are not in key order. Each stored value is already a
// JSON-encoded DataPoint and is copied through as-is. A failed get, an
// invalid value, or a failed write stops everything, which leaves the
// document incomplete (see get-by-time in the WIT).
func writePoints(out io.Writer, bucket *nats.Bucket, keys []string, start time.Time) {
	stop := make(chan struct{})
	var stopOnce sync.Once
	abort := func() { stopOnce.Do(func() { close(stop) }) }

	jobs := make(chan string)
	go func() {
		defer close(jobs)
		for _, key := range keys {
			select {
			case jobs <- key:
			case <-stop:
				return
			}
		}
	}()

	values := make(chan []byte, getConcurrency)
	var workers sync.WaitGroup
	for i := 0; i < getConcurrency; i++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for key := range jobs {
				entry, err := bucket.Get(key)
				if err != nil || !json.Valid(entry.Value) {
					abort()
					return
				}
				select {
				case values <- entry.Value:
				case <-stop:
					return
				}
			}
		}()
	}
	go func() {
		workers.Wait()
		close(values)
	}()

	w := bufio.NewWriterSize(out, streamBufferBytes)
	w.WriteString(`{"points":[`)
	count := 0
	for value := range values {
		select {
		case <-stop:
			continue // drain until the workers exit
		default:
		}
		if count > 0 {
			w.WriteByte(',')
		}
		if _, err := w.Write(value); err != nil {
			abort() // the reader went away
		}
		count++
	}
	select {
	case <-stop:
		return
	default:
	}
	fmt.Fprintf(w, `],"count":%d,"elapsedMs":%d}`, count, time.Since(start).Milliseconds())
	w.Flush()
}

// streamWriter adapts a WIT byte stream to io.Writer.
type streamWriter struct {
	tx *witTypes.StreamWriter[uint8]
}

func (s streamWriter) Write(p []byte) (int, error) {
	n := int(s.tx.WriteAll(p))
	if n < len(p) {
		return n, io.ErrClosedPipe
	}
	return n, nil
}
