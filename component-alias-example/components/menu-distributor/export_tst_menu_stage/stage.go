// Package export_tst_menu_stage implements menu-distributor's
// `tst:menu/stage` export, the last stage in the pipeline.
package export_tst_menu_stage

import (
	witTypes "go.bytecodealliance.org/pkg/wit/types"

	"wit_component/tst_menu_types"
)

func Process(items []tst_menu_types.MenuItem) witTypes.Result[[]tst_menu_types.MenuItem, string] {
	for i := range items {
		items[i].Trace = append(items[i].Trace, "menu-distributor")
	}
	return witTypes.Ok[[]tst_menu_types.MenuItem, string](items)
}
