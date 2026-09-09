package export_h3_pipeline_ingest

import (
	witTypes "go.bytecodealliance.org/pkg/wit/types"

	"h3ingester/h3_pipeline_types"
	"h3ingester/persistlogic"
)

// IngestBatch is the wRPC entry point called by the gateway component (WIT
// import/export resolution within the same workload -- no manifest link).
// Single-hop: writes directly via persistlogic rather than forwarding to a
// separate persister component/h3:pipeline/persist interface.
func IngestBatch(points []h3_pipeline_types.DataPoint) witTypes.Result[uint32, string] {
	return persistlogic.PersistBatch(points)
}

func DeleteByKey(h3Index string, timestamp string) witTypes.Result[witTypes.Unit, string] {
	return persistlogic.DeleteByKey(h3Index, timestamp)
}

func DeleteByTime(timestamp string) witTypes.Result[uint32, string] {
	return persistlogic.DeleteByTime(timestamp)
}

func DeleteAll() witTypes.Result[uint32, string] {
	return persistlogic.DeleteAll()
}
