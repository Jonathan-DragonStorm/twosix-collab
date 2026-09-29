// Package export_tst_menu_stage implements menu-persister's `tst:menu/stage`
// export.
//
// Stateless for this example: it stamps the item and hands it to whatever
// component the Workload named `distribute`.
package export_tst_menu_stage

import (
	witTypes "go.bytecodealliance.org/pkg/wit/types"

	"wit_component/distribute"
	"wit_component/tst_menu_types"
)

func Process(items []tst_menu_types.MenuItem) witTypes.Result[[]tst_menu_types.MenuItem, string] {
	for i := range items {
		items[i].Trace = append(items[i].Trace, "menu-persister")
	}
	return distribute.Process(items)
}
