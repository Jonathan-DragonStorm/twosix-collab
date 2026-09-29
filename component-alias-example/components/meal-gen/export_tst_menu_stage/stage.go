// Package export_tst_menu_stage implements meal-gen's `tst:menu/stage` export.
//
// meal-gen fills in the details the parent company's base menu leaves out,
// then hands the items to whatever component the Workload named `enriched`.
package export_tst_menu_stage

import (
	witTypes "go.bytecodealliance.org/pkg/wit/types"

	"wit_component/enriched"
	"wit_component/tst_menu_types"
)

func Process(items []tst_menu_types.MenuItem) witTypes.Result[[]tst_menu_types.MenuItem, string] {
	for i := range items {
		item := &items[i]
		// A real meal-gen would query the recipe/details system here.
		if item.Description.IsNone() {
			item.Description = witTypes.Some("house " + item.Meal + " " + item.Name)
		}
		if len(item.Ingredients) == 0 {
			item.Ingredients = []string{item.Name, "salt", "love"}
		}
		item.Trace = append(item.Trace, "meal-gen")
	}
	return enriched.Process(items)
}
