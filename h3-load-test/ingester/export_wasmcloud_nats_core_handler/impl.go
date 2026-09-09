package export_wasmcloud_nats_core_handler

import (
	"encoding/json"

	witTypes "go.bytecodealliance.org/pkg/wit/types"

	"h3ingester/h3_pipeline_types"
	"h3ingester/persistlogic"
	"h3ingester/wasmcloud_nats_types"
)

type pointJSON struct {
	H3Index   string  `json:"h3Index"`
	Timestamp string  `json:"timestamp"`
	Value     float64 `json:"value"`
}

// HandleMessage is the direct NATS-topic ingestion path (host-pushed, per
// the manifest's core-subscriptions config) -- the second of the two ways
// the ingester can receive objects, alongside the gateway's wRPC call.
func HandleMessage(msg wasmcloud_nats_types.NatsMessage) witTypes.Result[witTypes.Unit, string] {
	var p pointJSON
	if err := json.Unmarshal(msg.Body, &p); err != nil {
		return witTypes.Err[witTypes.Unit, string]("invalid JSON body: " + err.Error())
	}
	point := h3_pipeline_types.DataPoint{H3Index: p.H3Index, Timestamp: p.Timestamp, Value: p.Value}
	result := persistlogic.PersistBatch([]h3_pipeline_types.DataPoint{point})
	if result.IsErr() {
		return witTypes.Err[witTypes.Unit, string](result.Err())
	}
	return witTypes.Ok[witTypes.Unit, string](witTypes.Unit{})
}
