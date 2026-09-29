package main

import (
	"encoding/json"
	"net/http"

	"go.bytecodealliance.org/pkg/wasihttp"
	witTypes "go.bytecodealliance.org/pkg/wit/types"

	"wit_component/downstream"
	"wit_component/tst_menu_types"
)

// item is the JSON shape of a tst:menu/types.menu-item.
type item struct {
	Name        string   `json:"name"`
	Meal        string   `json:"meal"`
	Description *string  `json:"description"`
	Ingredients []string `json:"ingredients"`
	Trace       []string `json:"trace"`
}

// sample stands in for the parent company's daily base menu when the request
// has no body.
var sample = []item{
	{Name: "pancakes", Meal: "breakfast"},
	{Name: "club sandwich", Meal: "lunch"},
	{Name: "roast chicken", Meal: "dinner"},
}

func init() {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /", func(w http.ResponseWriter, r *http.Request) { ingest(w, sample) })
	mux.HandleFunc("POST /", func(w http.ResponseWriter, r *http.Request) {
		var items []item
		if err := json.NewDecoder(r.Body).Decode(&items); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "decode body: " + err.Error()})
			return
		}
		ingest(w, items)
	})
	wasihttp.Handle(mux)
}

// ingest stamps each item and hands it to whichever component the Workload
// named `downstream`. The ingester has no idea which component that is.
func ingest(w http.ResponseWriter, items []item) {
	in := make([]tst_menu_types.MenuItem, len(items))
	for i, it := range items {
		in[i] = toWit(it)
		in[i].Trace = append(in[i].Trace, "menu-ingester")
	}

	result := downstream.Process(in)
	if result.IsErr() {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": result.Err()})
		return
	}
	out := make([]item, 0, len(result.Ok()))
	for _, m := range result.Ok() {
		out = append(out, fromWit(m))
	}
	writeJSON(w, http.StatusOK, out)
}

func toWit(it item) tst_menu_types.MenuItem {
	desc := witTypes.None[string]()
	if it.Description != nil {
		desc = witTypes.Some(*it.Description)
	}
	return tst_menu_types.MenuItem{
		Name:        it.Name,
		Meal:        it.Meal,
		Description: desc,
		Ingredients: it.Ingredients,
		Trace:       it.Trace,
	}
}

func fromWit(m tst_menu_types.MenuItem) item {
	it := item{Name: m.Name, Meal: m.Meal, Ingredients: m.Ingredients, Trace: m.Trace}
	if m.Description.IsSome() {
		d := m.Description.Some()
		it.Description = &d
	}
	return it
}

func writeJSON(w http.ResponseWriter, status int, data any) {
	body, err := json.Marshal(data)
	if err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		return
	}
	w.Header().Set("content-type", "application/json")
	w.WriteHeader(status)
	w.Write(body)
}
